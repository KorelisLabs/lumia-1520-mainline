/*
 * pcm-tone -- the C3a digital stimulus, and nothing else it could ever be.
 *
 * WHY THIS IS A SEPARATE BINARY AND NOT A FLAG ON pcm-run-measured
 *
 * pcm-run-measured fills its buffer with (i * 37) & 0x7fff and prints
 * "signal=ramp". That is a FULL-SCALE sawtooth with no declared frequency. It
 * was the right stimulus for a data-plane result, where the question was
 * whether the DSP consumed periods and nothing was connected to the output.
 *
 * C3a enables a power amplifier. Section 23 of the C3 map freezes the
 * stimulus at 1 kHz, -40 dBFS, and says "never" against full scale. A flag on
 * the existing tool would put a full-scale ramp one wrong default away from a
 * live PA, so this is a new program whose guarantee is NEGATIVE and structural:
 *
 *   IT CANNOT EMIT FULL SCALE. It cannot emit a ramp. It cannot emit anything
 *   above -20 dBFS, because the ceiling is compiled in and checked before the
 *   device is even opened.
 *
 * That is the same reasoning that froze pcm-prepare-only: when the value of a
 * tool is what it is unable to do, the guarantee belongs in a separate
 * artefact rather than in a code path.
 *
 * THE SEGMENT PLAN, AND WHY IT IS ONE UNINTERRUPTED STREAM
 *
 *   0 - 250 ms   1 kHz tone
 *   250 - 500    digital silence
 *   500 - 750    1 kHz tone
 *   750 - 1000   digital silence
 *
 * The milestone is a waveform at the pin that follows the DIGITAL CONTENT.
 * Proving that by starting and stopping the PCM would confound the content
 * with the stream: an output that appeared and disappeared with the stream
 * could be explained by the stream machinery, the SLIMbus port, the DSP or
 * the codec's own clock gating, and none of those is D/A conversion.
 *
 * Here the stream, the routing, the PA and every register stay UNCHANGED for
 * the whole second. The only thing that changes is the sample values. An
 * output that tracks tone -> silence -> tone -> silence under those conditions
 * has nothing left to be except conversion.
 *
 * EXACT, NOT APPROXIMATE
 *
 * At 48 kHz a 1 kHz period is exactly 48 frames, and a 250 ms segment is
 * exactly 12000 frames -- 250 whole cycles. So every burst begins and ends at
 * a zero crossing on a rising edge, and the segment boundaries introduce no
 * step discontinuity of their own. Anything the scope shows at a boundary is
 * the analog stage, not the stimulus. The sine is taken from a 48-entry table
 * computed once, so the waveform is bit-identical from burst to burst and
 * from run to run.
 *
 * NO AUTOMATIC ESCALATION, EVER
 *
 * Section 23 allows -30 and then -20 dBFS if -40 is below the measurement
 * floor, and requires each step to be DECLARED before it is used. This tool
 * therefore never changes its own amplitude: one invocation emits one
 * amplitude, prints it before playing, and anything above -40 dBFS additionally
 * requires --armed-escalation on the command line. A louder run is a separate,
 * deliberate act by the operator, which is what "declared" means.
 *
 * Bounded by construction: a fixed frame count, a deadline, and a stop on any
 * write error or state change.
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <sound/asound.h>

/*
 * THE FROZEN PLAN. These are not defaults to be overridden; they are the
 * contract from section 23 of the mapping, and the only one exposed on the
 * command line is the amplitude, because that is the only one the mapping
 * allows to vary.
 */
#define TONE_RATE	48000
#define TONE_CHANNELS	1
#define TONE_HZ		1000
#define SEG_MS		250
#define N_SEGMENTS	4		/* tone, silence, tone, silence */
#define PERIOD_FRAMES	960		/* 20 ms, the geometry D1 ran at */
#define N_PERIODS	4

/*
 * THE CEILING. -20 dBFS, compiled in.
 *
 * Not a parameter, not a config file, not an environment variable. The
 * artefact audit asserts this constant is present and that no code path can
 * produce a larger amplitude than it implies.
 */
#define DBFS_CEILING	(-20.0)
#define DBFS_DEFAULT	(-40.0)
#define DBFS_ESCALATION	(-40.0)		/* louder than this needs arming */

#define FULL_SCALE	32767.0

/*
 * Pi, written out rather than taken from M_PI.
 *
 * M_PI is an X/Open extension, not ISO C, and both glibc under
 * _POSIX_C_SOURCE and musl -- which is what this is cross-compiled against
 * for postmarketOS -- hide it unless the right feature macro happens to be
 * set. Depending on that would make the stimulus generator's portability a
 * matter of which header the build picked up.
 */
#define TONE_PI		3.14159265358979323846

#define NEVER_START_THRESHOLD	0x7fffffffUL

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
	double dbfs = DBFS_DEFAULT;
	int armed = 0, dry_run = 0;
	struct snd_pcm_hw_params hw;
	struct snd_pcm_sw_params sw;
	struct snd_pcm_status st;
	struct snd_xferi xf;
	short table[TONE_RATE / TONE_HZ];
	short *buf = NULL;
	unsigned int i, frame_bytes, period_frames, buffer_frames;
	unsigned int seg_frames, total_frames, peak;
	unsigned long frames_written = 0, writes = 0, xruns = 0;
	int fd, rc, start_rc = -1, final_rc = 0, started = 0;
	double t0;

	for (i = 1; i < (unsigned int)argc; i++) {
		if (!strcmp(argv[i], "-D") && i + 1 < (unsigned int)argc)
			dev = argv[++i];
		else if (!strcmp(argv[i], "--dbfs") && i + 1 < (unsigned int)argc)
			dbfs = strtod(argv[++i], NULL);
		else if (!strcmp(argv[i], "--armed-escalation"))
			armed = 1;
		else if (!strcmp(argv[i], "--dry-run"))
			dry_run = 1;
		else {
			fprintf(stderr,
				"usage: %s [-D dev] [--dbfs -40] [--armed-escalation] [--dry-run]\n"
				"  1 kHz, 48 kHz S16_LE mono, 250 ms tone / silence / tone / silence.\n"
				"  Amplitudes above %.0f dBFS need --armed-escalation.\n"
				"  The compiled ceiling is %.0f dBFS and cannot be raised at runtime.\n",
				argv[0], DBFS_ESCALATION, DBFS_CEILING);
			return 2;
		}
	}

	/*
	 * THE CEILING IS CHECKED BEFORE THE DEVICE IS OPENED.
	 *
	 * Refusing early matters: a refusal after the PCM is configured would
	 * leave a prepared stream behind on a codec whose PA may be live.
	 */
	if (!(dbfs <= DBFS_CEILING)) {
		fprintf(stderr,
			"pcm-tone: REFUSING %.1f dBFS -- the compiled ceiling is %.1f dBFS\n",
			dbfs, DBFS_CEILING);
		return 2;
	}
	if (dbfs > DBFS_ESCALATION && !armed) {
		fprintf(stderr,
			"pcm-tone: REFUSING %.1f dBFS -- louder than %.1f dBFS is an escalation and needs --armed-escalation\n"
			"          Section 23: each amplitude step is declared before it is used, never chosen at the scope.\n",
			dbfs, DBFS_ESCALATION);
		return 2;
	}
	if (!(dbfs >= -90.0)) {
		fprintf(stderr,
			"pcm-tone: REFUSING %.1f dBFS -- below the 16-bit floor, this would be silence mislabelled as a tone\n",
			dbfs);
		return 2;
	}

	seg_frames = TONE_RATE / 1000 * SEG_MS;
	total_frames = seg_frames * N_SEGMENTS;
	peak = (unsigned int)lround(FULL_SCALE * pow(10.0, dbfs / 20.0));

	/*
	 * One exact period of the sine, computed once. 48 entries at 48 kHz
	 * and 1 kHz, so a burst of 12000 frames is exactly 250 whole cycles
	 * and both of its edges land on a rising zero crossing.
	 */
	for (i = 0; i < sizeof(table) / sizeof(table[0]); i++)
		table[i] = (short)lround((double)peak *
					 sin(2.0 * TONE_PI * (double)i /
					     (double)(sizeof(table) / sizeof(table[0]))));

	printf("tool=pcm-tone\n");
	printf("device=%s\n", dev);
	printf("signal=sine\n");
	printf("tone_hz=%d\n", TONE_HZ);
	printf("requested_rate=%d\n", TONE_RATE);
	printf("requested_channels=%d\n", TONE_CHANNELS);
	printf("requested_format=S16_LE\n");
	printf("declared_dbfs=%.1f\n", dbfs);
	printf("ceiling_dbfs=%.1f\n", DBFS_CEILING);
	printf("escalation_armed=%d\n", armed);
	printf("peak_sample=%u\n", peak);
	printf("full_scale=%d\n", (int)FULL_SCALE);
	printf("segment_ms=%d\n", SEG_MS);
	printf("segment_frames=%u\n", seg_frames);
	printf("segments=%d\n", N_SEGMENTS);
	printf("segment_plan=tone,silence,tone,silence\n");
	printf("cycles_per_segment=%u\n",
	       seg_frames / (unsigned int)(sizeof(table) / sizeof(table[0])));
	printf("total_frames=%u\n", total_frames);
	printf("total_ms=%u\n", total_frames / (TONE_RATE / 1000));

	if (dry_run) {
		/*
		 * The stimulus is fully described above without touching the
		 * sound card, so the amplitude and the plan can be recorded in
		 * the evidence -- and checked by the gate -- BEFORE the PA is
		 * enabled. Section 23 requires the step to be declared in the
		 * evidence before it is used; this is how.
		 */
		printf("dry_run=1\n");
		printf("table_first4=%d,%d,%d,%d\n",
		       table[0], table[1], table[2], table[3]);
		printf("table_quarter=%d\n",
		       table[(sizeof(table) / sizeof(table[0])) / 4]);
		return 0;
	}

	fd = open(dev, O_RDWR);
	printf("open_rc=%d\n", fd < 0 ? -errno : 0);
	if (fd < 0)
		return 1;

	hw_any(&hw);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_ACCESS,
		 SNDRV_PCM_ACCESS_RW_INTERLEAVED);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
	iv_set(&hw, SNDRV_PCM_HW_PARAM_RATE, TONE_RATE);
	iv_set(&hw, SNDRV_PCM_HW_PARAM_CHANNELS, TONE_CHANNELS);
	iv_set(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, PERIOD_FRAMES);
	iv_set(&hw, SNDRV_PCM_HW_PARAM_PERIODS, N_PERIODS);

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
	printf("actual_buffer_frames=%u\n", buffer_frames);
	printf("frame_bytes=%u\n", frame_bytes);

	/*
	 * THE NEGOTIATED RATE IS A CORRECTNESS CONDITION, NOT AN OBSERVATION.
	 *
	 * The whole claim is "a waveform at the frequency of the digital
	 * stimulus". If the stream came back at 44.1 kHz the pin would show
	 * roughly 919 Hz, the gate would compare it against 1000, and the run
	 * would fail for a reason that has nothing to do with the codec. Worse,
	 * a reading close enough to 1 kHz could be accepted as a pass for the
	 * wrong reason. So a mismatch refuses here, before anything plays.
	 */
	if (iv_get(&hw, SNDRV_PCM_HW_PARAM_RATE) != TONE_RATE ||
	    iv_get(&hw, SNDRV_PCM_HW_PARAM_CHANNELS) != TONE_CHANNELS ||
	    frame_bytes != 2 * TONE_CHANNELS) {
		printf("error=geometry_not_as_requested\n");
		close(fd);
		return 1;
	}
	if (!period_frames || !buffer_frames) {
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

	rc = ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, 0);
	printf("prepare_rc=%d\n", rc == 0 ? 0 : -errno);
	if (rc < 0) {
		close(fd);
		return 1;
	}

	buf = malloc((size_t)period_frames * frame_bytes);
	if (!buf) {
		printf("error=oom\n");
		close(fd);
		return 1;
	}

	/*
	 * Fill by ABSOLUTE frame index, so a segment boundary that falls in
	 * the middle of a period is handled by construction rather than by
	 * arranging for it never to happen. 12000 is not a multiple of 960,
	 * and quietly rounding the segment to a period boundary would make the
	 * burst 240 ms while the evidence said 250.
	 */
	t0 = now_s();
	while (frames_written < total_frames && (now_s() - t0) < 10.0) {
		unsigned int n = period_frames;
		unsigned int j;

		if (total_frames - frames_written < n)
			n = total_frames - frames_written;

		for (j = 0; j < n; j++) {
			unsigned long idx = frames_written + j;
			unsigned int seg = (unsigned int)(idx / seg_frames);
			unsigned long into = idx - (unsigned long)seg * seg_frames;

			/* even segments are tone, odd segments are silence */
			buf[j] = (seg % 2) ? 0
					   : table[into % (sizeof(table) /
							   sizeof(table[0]))];
		}

		memset(&xf, 0, sizeof(xf));
		xf.buf = buf;
		xf.frames = n;
		rc = ioctl(fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xf);
		if (rc < 0) {
			if (errno == EPIPE) {
				xruns++;
				printf("xrun_at_frame=%lu\n", frames_written);
			}
			final_rc = -errno;
			break;
		}
		frames_written += n;
		writes++;

		/*
		 * START ONCE THE BUFFER IS PRIMED, and only once. The stream
		 * must not begin as a side effect of a write, or the moment of
		 * RUN would not be attributable -- the same discipline
		 * pcm-run-measured uses.
		 */
		if (!started && frames_written >= buffer_frames) {
			start_rc = ioctl(fd, SNDRV_PCM_IOCTL_START, 0);
			start_rc = start_rc == 0 ? 0 : -errno;
			printf("start_requested=1\n");
			printf("start_rc=%d\n", start_rc);
			if (start_rc == 0)
				started = 1;
			else
				break;
		}
	}

	if (!started) {
		/* Short plan, or a failure before the buffer filled. */
		start_rc = ioctl(fd, SNDRV_PCM_IOCTL_START, 0);
		start_rc = start_rc == 0 ? 0 : -errno;
		printf("start_requested=1\n");
		printf("start_rc=%d\n", start_rc);
		if (start_rc == 0)
			started = 1;
	}

	/* Let what has been written drain, bounded. */
	if (started) {
		rc = ioctl(fd, SNDRV_PCM_IOCTL_DRAIN, 0);
		printf("drain_rc=%d\n", rc == 0 ? 0 : -errno);
	}

	memset(&st, 0, sizeof(st));
	if (ioctl(fd, SNDRV_PCM_IOCTL_STATUS, &st) == 0)
		printf("final_state=%d\n", st.state);

	printf("frames_written=%lu\n", frames_written);
	printf("writes=%lu\n", writes);
	printf("xruns=%lu\n", xruns);
	printf("elapsed_s=%.3f\n", now_s() - t0);
	printf("final_rc=%d\n", final_rc);
	printf("complete=%d\n", frames_written == total_frames ? 1 : 0);

	free(buf);
	close(fd);
	return (frames_written == total_frames && final_rc == 0) ? 0 : 1;
}
