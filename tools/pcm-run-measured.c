/*
 * pcm-run-measured -- drive a PCM through RUN and measure what the DSP consumes.
 *
 * WHY THIS IS A SEPARATE BINARY
 *
 * pcm-prepare-only is frozen, and its value is precisely that it CANNOT start a
 * stream: that guarantee underwrites the control-plane milestone, where a
 * kprobe had to observe q6asm_run_nowait exactly zero times. This tool does the
 * opposite on purpose, so it is a new program rather than a flag on that one.
 * Nothing here should ever be merged back into the oracle.
 *
 * WHAT IT MEASURES, AND WHAT THAT IS WORTH
 *
 * On this platform q6asm_dai_pointer() returns pcm_irq_pos, which is
 * incremented in exactly one place -- the ASM_CLIENT_EVENT_DATA_WRITE_DONE
 * handler. So hw_ptr is not a timer estimate: every frame of advance is the
 * ADSP saying it consumed a period.
 *
 * The numbers printed here are therefore a real consumption rate. They are
 * still only the userspace-visible half: the authoritative rate for the gate
 * comes from kernel timestamps on snd_pcm_period_elapsed, because polling from
 * userspace adds scheduling jitter to both ends of the interval.
 *
 * It does NOT prove the bytes written here reached the codec. The driver issues
 * q6asm_write_async() from the event handler whether or not userspace supplied
 * anything, and there is no receiver-side counter or loopback on this hardware.
 *
 * The buffer is filled with a counting ramp rather than silence, so "we wrote
 * real data" is true and any future readback path has something to recognise.
 *
 * Bounded by construction: the loop stops on a deadline, on a state change, or
 * on a write error. A helper that can spin forever against a wedged DSP is not
 * an instrument.
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <sound/asound.h>

#define DEFAULT_RATE	48000
#define DEFAULT_CH	1
#define DEFAULT_PERIOD	960		/* 20 ms at 48 kHz */
#define DEFAULT_PERIODS	4
#define DEFAULT_SECS	3
#define MAX_FRAMES	16384

/*
 * Explicit START only. The stream must never begin as a side effect of a
 * write, or the moment of RUN would not be observable.
 */
#define NEVER_START_THRESHOLD	0x7fffffffUL

static const char *state_name(int s)
{
	switch (s) {
	case SNDRV_PCM_STATE_OPEN:		return "OPEN";
	case SNDRV_PCM_STATE_SETUP:		return "SETUP";
	case SNDRV_PCM_STATE_PREPARED:		return "PREPARED";
	case SNDRV_PCM_STATE_RUNNING:		return "RUNNING";
	case SNDRV_PCM_STATE_XRUN:		return "XRUN";
	case SNDRV_PCM_STATE_DRAINING:		return "DRAINING";
	case SNDRV_PCM_STATE_PAUSED:		return "PAUSED";
	case SNDRV_PCM_STATE_SUSPENDED:		return "SUSPENDED";
	case SNDRV_PCM_STATE_DISCONNECTED:	return "DISCONNECTED";
	default:				return "UNKNOWN";
	}
}

static void mask_set(struct snd_pcm_hw_params *p, int n, unsigned int bit)
{
	p->masks[n - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[bit >> 5] |=
		(1U << (bit & 31));
}

static void iv_set(struct snd_pcm_hw_params *p, int n, unsigned int v)
{
	struct snd_interval *i =
		&p->intervals[n - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];

	i->min = i->max = v;
	i->integer = 1;
	i->openmin = i->openmax = 0;
}

static unsigned int iv_get(struct snd_pcm_hw_params *p, int n)
{
	return p->intervals[n - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min;
}

static void hw_any(struct snd_pcm_hw_params *p)
{
	int n;

	memset(p, 0, sizeof(*p));
	for (n = SNDRV_PCM_HW_PARAM_FIRST_MASK;
	     n <= SNDRV_PCM_HW_PARAM_LAST_MASK; n++)
		memset(&p->masks[n - SNDRV_PCM_HW_PARAM_FIRST_MASK], 0xff,
		       sizeof(struct snd_mask));
	for (n = SNDRV_PCM_HW_PARAM_FIRST_INTERVAL;
	     n <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL; n++) {
		struct snd_interval *i =
			&p->intervals[n - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];

		i->min = 0;
		i->max = UINT_MAX;
	}
	p->rmask = ~0U;
	p->cmask = 0;
	p->info = ~0U;
}

static double now_s(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	const char *dev = "/dev/snd/pcmC0D0p";
	unsigned int rate = DEFAULT_RATE, channels = DEFAULT_CH;
	unsigned int period = DEFAULT_PERIOD, periods = DEFAULT_PERIODS;
	double secs = DEFAULT_SECS;
	struct snd_pcm_hw_params hw;
	struct snd_pcm_sw_params sw;
	struct snd_pcm_status st;
	struct snd_xferi xf;
	short *buf = NULL;
	unsigned int i, frame_bytes, period_frames, buffer_frames;
	unsigned long frames_written = 0, writes = 0, hw_first = 0, hw_last = 0;
	unsigned long xruns = 0, polls = 0;
	int fd, rc, start_rc = -1, final_rc = 0, started = 0, saw_running = 0;
	double t0, t_start = 0, t_end = 0;

	for (i = 1; i < (unsigned int)argc; i++) {
		if (!strcmp(argv[i], "-D") && i + 1 < (unsigned int)argc)
			dev = argv[++i];
		else if (!strcmp(argv[i], "-r") && i + 1 < (unsigned int)argc)
			rate = (unsigned int)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "-c") && i + 1 < (unsigned int)argc)
			channels = (unsigned int)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "-p") && i + 1 < (unsigned int)argc)
			period = (unsigned int)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "-n") && i + 1 < (unsigned int)argc)
			periods = (unsigned int)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "-t") && i + 1 < (unsigned int)argc)
			secs = strtod(argv[++i], NULL);
		else {
			fprintf(stderr,
				"usage: %s [-D dev] [-r rate] [-c ch] [-p period] [-n periods] [-t secs]\n",
				argv[0]);
			return 2;
		}
	}

	if (period == 0 || period > MAX_FRAMES || periods < 2 || secs <= 0 ||
	    secs > 60) {
		fprintf(stderr, "refusing implausible parameters\n");
		return 2;
	}

	printf("tool=pcm-run-measured\n");
	printf("device=%s\n", dev);
	printf("requested_rate=%u\n", rate);
	printf("requested_channels=%u\n", channels);
	printf("requested_format=S16_LE\n");
	printf("requested_period_frames=%u\n", period);
	printf("requested_periods=%u\n", periods);
	printf("requested_seconds=%.3f\n", secs);

	fd = open(dev, O_RDWR);
	printf("open_rc=%d\n", fd < 0 ? -errno : 0);
	if (fd < 0)
		return 1;

	hw_any(&hw);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_ACCESS,
		 SNDRV_PCM_ACCESS_RW_INTERLEAVED);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
	iv_set(&hw, SNDRV_PCM_HW_PARAM_RATE, rate);
	iv_set(&hw, SNDRV_PCM_HW_PARAM_CHANNELS, channels);
	iv_set(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, period);
	iv_set(&hw, SNDRV_PCM_HW_PARAM_PERIODS, periods);

	rc = ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw);
	printf("hw_params_rc=%d\n", rc == 0 ? 0 : -errno);
	if (rc < 0) {
		close(fd);
		return 1;
	}

	period_frames = iv_get(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE);
	buffer_frames = iv_get(&hw, SNDRV_PCM_HW_PARAM_BUFFER_SIZE);
	frame_bytes = iv_get(&hw, SNDRV_PCM_HW_PARAM_FRAME_BITS) / 8;
	printf("actual_rate=%u\n", iv_get(&hw, SNDRV_PCM_HW_PARAM_RATE));
	printf("actual_channels=%u\n", iv_get(&hw, SNDRV_PCM_HW_PARAM_CHANNELS));
	printf("actual_period_frames=%u\n", period_frames);
	printf("actual_periods=%u\n", iv_get(&hw, SNDRV_PCM_HW_PARAM_PERIODS));
	printf("actual_buffer_frames=%u\n", buffer_frames);
	printf("frame_bytes=%u\n", frame_bytes);

	if (!period_frames || !buffer_frames || !frame_bytes) {
		printf("error=degenerate_geometry\n");
		close(fd);
		return 1;
	}

	memset(&sw, 0, sizeof(sw));
	sw.tstamp_mode = SNDRV_PCM_TSTAMP_NONE;
	sw.period_step = 1;
	sw.avail_min = period_frames;
	sw.start_threshold = NEVER_START_THRESHOLD;
	sw.stop_threshold = ULONG_MAX;
	sw.boundary = buffer_frames;
	while (sw.boundary && sw.boundary * 2 <= LONG_MAX - sw.boundary)
		sw.boundary *= 2;
	rc = ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw);
	printf("sw_params_rc=%d\n", rc == 0 ? 0 : -errno);
	printf("start_threshold=%lu\n", (unsigned long)sw.start_threshold);

	rc = ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, 0);
	printf("prepare_rc=%d\n", rc == 0 ? 0 : -errno);
	if (rc < 0) {
		close(fd);
		return 1;
	}

	/* A counting ramp: non-zero, and recognisable if ever read back. */
	buf = malloc((size_t)period_frames * frame_bytes);
	if (!buf) {
		printf("error=oom\n");
		close(fd);
		return 1;
	}
	for (i = 0; i < period_frames * channels; i++)
		buf[i] = (short)((i * 37) & 0x7fff);
	printf("signal=ramp\n");

	/* Prefill the whole buffer before starting, so RUN has data waiting. */
	for (i = 0; i < periods; i++) {
		memset(&xf, 0, sizeof(xf));
		xf.buf = buf;
		xf.frames = period_frames;
		rc = ioctl(fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xf);
		if (rc < 0)
			break;
		frames_written += period_frames;
		writes++;
	}
	printf("prefill_writes=%lu\n", writes);
	printf("prefill_frames=%lu\n", frames_written);

	start_rc = ioctl(fd, SNDRV_PCM_IOCTL_START, 0);
	start_rc = start_rc == 0 ? 0 : -errno;
	printf("start_requested=1\n");
	printf("start_rc=%d\n", start_rc);
	if (start_rc == 0)
		started = 1;

	t0 = now_s();
	while (started && (now_s() - t0) < secs) {
		memset(&xf, 0, sizeof(xf));
		xf.buf = buf;
		xf.frames = period_frames;
		rc = ioctl(fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xf);
		if (rc < 0) {
			if (errno == EPIPE) {
				xruns++;
				printf("xrun_at=%.3f\n", now_s() - t0);
			}
			final_rc = -errno;
			break;
		}
		frames_written += period_frames;
		writes++;

		memset(&st, 0, sizeof(st));
		if (ioctl(fd, SNDRV_PCM_IOCTL_STATUS, &st) == 0) {
			polls++;
			if (st.state == SNDRV_PCM_STATE_RUNNING && !saw_running) {
				saw_running = 1;
				hw_first = (unsigned long)st.hw_ptr;
				t_start = now_s();
			}
			if (saw_running) {
				hw_last = (unsigned long)st.hw_ptr;
				t_end = now_s();
			}
			if (st.state == SNDRV_PCM_STATE_XRUN) {
				xruns++;
				printf("state_went_xrun_at=%.3f\n", now_s() - t0);
				break;
			}
		}
	}

	printf("loop_writes=%lu\n", writes);
	printf("frames_written=%lu\n", frames_written);
	printf("status_polls=%lu\n", polls);
	printf("saw_running=%d\n", saw_running);
	printf("hw_ptr_first=%lu\n", hw_first);
	printf("hw_ptr_last=%lu\n", hw_last);
	printf("hw_ptr_advance=%lu\n",
	       hw_last >= hw_first ? hw_last - hw_first : 0UL);
	printf("measure_seconds=%.4f\n", t_end > t_start ? t_end - t_start : 0.0);
	if (t_end > t_start && hw_last >= hw_first)
		printf("userspace_rate_fps=%.1f\n",
		       (double)(hw_last - hw_first) / (t_end - t_start));
	else
		printf("userspace_rate_fps=0.0\n");
	printf("xruns=%lu\n", xruns);

	memset(&st, 0, sizeof(st));
	if (ioctl(fd, SNDRV_PCM_IOCTL_STATUS, &st) == 0) {
		printf("state_final=%s\n", state_name(st.state));
		printf("state_num_final=%d\n", (int)st.state);
	}

	rc = ioctl(fd, SNDRV_PCM_IOCTL_DROP, 0);
	printf("drop_rc=%d\n", rc == 0 ? 0 : -errno);
	free(buf);
	close(fd);
	printf("close_rc=0\n");
	printf("final_rc=%d\n", final_rc);

	return final_rc ? 1 : 0;
}
