/*
 * pcm-capture -- record a fixed number of seconds from an ALSA capture PCM
 * into a WAV file, with nothing else it could do.
 *
 * The capture twin of pcm-tone (r197, docs/audio/wcd9320-mic-mapping.md):
 * raw ALSA ioctls, no alsa-lib, a static musl binary built in pmbootstrap's
 * armv7 buildroot (tools/build-pcm-capture.sh). It opens the PCM, sets
 * 48 kHz / S16_LE / mono (or --channels), starts it explicitly, reads, and
 * writes a canonical 44-byte-header WAV. It never opens a playback device:
 * the device path must end in 'c'.
 *
 * It prints key=value lines -- the negotiated geometry, the frames read, the
 * xruns, and the peak and mean-square of the samples -- so the runner can
 * record them; the analysis proper happens on the PC.
 *
 * r201: -p and -n choose the period (frames) and the number of periods; the
 * defaults are r197's 960 x 4 (80 ms). q6asm-dai allows 320..4096 bytes per
 * period and 2..8 periods, so mono S16 tops out at 2048 x 8 (341 ms). Each
 * overrun prints its CLOCK_BOOTTIME (= /proc/uptime, = dmesg's clock).
 *
 * Usage: pcm-capture -D /dev/snd/pcmC0D1c -s 5 -o /tmp/cap.wav [-c 1] [-p 960] [-n 4]
 * Exit: 0 when every requested frame was read, non-zero otherwise.
 */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <sound/asound.h>

#define CAP_RATE	48000
#define CAP_MAX_S	30
#define PERIOD_FRAMES	960
#define N_PERIODS	4
/* r201: q6asm-dai's capture limits */
#define CAP_MIN_PERIOD_BYTES	320
#define CAP_MAX_PERIOD_BYTES	4096
#define CAP_MIN_PERIODS		2
#define CAP_MAX_PERIODS		8

static void mask_set(struct snd_pcm_hw_params *p, int n, unsigned int bit)
{
	struct snd_mask *m = &p->masks[n - SNDRV_PCM_HW_PARAM_FIRST_MASK];

	memset(m, 0, sizeof(*m));
	m->bits[bit >> 5] = 1U << (bit & 31);
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

static void put_le32(unsigned char *b, uint32_t v)
{
	b[0] = v; b[1] = v >> 8; b[2] = v >> 16; b[3] = v >> 24;
}

static void put_le16(unsigned char *b, uint16_t v)
{
	b[0] = v; b[1] = v >> 8;
}

static int wav_header(FILE *f, unsigned int ch, uint32_t data_bytes)
{
	unsigned char h[44];

	memcpy(h, "RIFF", 4);
	put_le32(h + 4, 36 + data_bytes);
	memcpy(h + 8, "WAVEfmt ", 8);
	put_le32(h + 16, 16);
	put_le16(h + 20, 1);			/* PCM */
	put_le16(h + 22, ch);
	put_le32(h + 24, CAP_RATE);
	put_le32(h + 28, CAP_RATE * 2 * ch);
	put_le16(h + 32, 2 * ch);
	put_le16(h + 34, 16);
	memcpy(h + 36, "data", 4);
	put_le32(h + 40, data_bytes);
	if (fseek(f, 0, SEEK_SET))
		return -1;
	return fwrite(h, 1, sizeof(h), f) == sizeof(h) ? 0 : -1;
}

int main(int argc, char **argv)
{
	const char *dev = NULL, *out = NULL;
	unsigned int seconds = 0, channels = 1, period_frames, frame_bytes;
	unsigned int want_period = PERIOD_FRAMES, want_periods = N_PERIODS;
	struct timespec ts;
	unsigned long want, got = 0, xruns = 0, i, n;
	struct snd_pcm_hw_params hw;
	struct snd_pcm_sw_params sw;
	struct snd_xferi xf;
	long long sumsq = 0;
	int peak = 0, fd, rc, opt, ret = 1;
	size_t dl;
	short *buf;
	FILE *f;

	while ((opt = getopt(argc, argv, "D:s:o:c:p:n:")) != -1) {
		switch (opt) {
		case 'D': dev = optarg; break;
		case 's': seconds = (unsigned int)strtoul(optarg, NULL, 10); break;
		case 'o': out = optarg; break;
		case 'c': channels = (unsigned int)strtoul(optarg, NULL, 10); break;
		case 'p': want_period = (unsigned int)strtoul(optarg, NULL, 10); break;
		case 'n': want_periods = (unsigned int)strtoul(optarg, NULL, 10); break;
		default:
			fprintf(stderr, "usage: %s -D /dev/snd/pcmCxDyc -s N -o out.wav [-c 1|2] [-p frames] [-n periods]\n", argv[0]);
			return 2;
		}
	}
	dl = dev ? strlen(dev) : 0;
	if (!dl || dev[dl - 1] != 'c' || !out || seconds < 1 ||
	    seconds > CAP_MAX_S || channels < 1 || channels > 2 ||
	    want_period * 2 * channels < CAP_MIN_PERIOD_BYTES ||
	    want_period * 2 * channels > CAP_MAX_PERIOD_BYTES ||
	    want_periods < CAP_MIN_PERIODS || want_periods > CAP_MAX_PERIODS) {
		printf("error=bad_arguments (capture device ending in 'c', 1..%d s, 1..2 ch, %d..%d bytes per period, %d..%d periods)\n",
		       CAP_MAX_S, CAP_MIN_PERIOD_BYTES, CAP_MAX_PERIOD_BYTES,
		       CAP_MIN_PERIODS, CAP_MAX_PERIODS);
		return 2;
	}
	want = (unsigned long)seconds * CAP_RATE;
	printf("tool=pcm-capture\ndevice=%s\nseconds=%u\nchannels=%u\nrate=%u\nformat=S16_LE\n",
	       dev, seconds, channels, CAP_RATE);

	f = fopen(out, "w+b");
	if (!f) {
		printf("error=cannot_open_output errno=%d\n", errno);
		return 1;
	}
	if (wav_header(f, channels, 0)) {
		printf("error=cannot_write_header\n");
		fclose(f);
		return 1;
	}

	fd = open(dev, O_RDWR);
	printf("open_rc=%d\n", fd < 0 ? -errno : 0);
	if (fd < 0) {
		fclose(f);
		return 1;
	}
	hw_any(&hw);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
	iv_set(&hw, SNDRV_PCM_HW_PARAM_RATE, CAP_RATE);
	iv_set(&hw, SNDRV_PCM_HW_PARAM_CHANNELS, channels);
	iv_set(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, want_period);
	iv_set(&hw, SNDRV_PCM_HW_PARAM_PERIODS, want_periods);
	rc = ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw);
	printf("hw_params_rc=%d\n", rc == 0 ? 0 : -errno);
	if (rc < 0)
		goto out_fd;
	period_frames = iv_get(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE);
	frame_bytes = iv_get(&hw, SNDRV_PCM_HW_PARAM_FRAME_BITS) / 8;
	printf("actual_rate=%u\nactual_channels=%u\nactual_period_frames=%u\nactual_buffer_frames=%u\nframe_bytes=%u\n",
	       iv_get(&hw, SNDRV_PCM_HW_PARAM_RATE),
	       iv_get(&hw, SNDRV_PCM_HW_PARAM_CHANNELS), period_frames,
	       iv_get(&hw, SNDRV_PCM_HW_PARAM_BUFFER_SIZE), frame_bytes);
	if (iv_get(&hw, SNDRV_PCM_HW_PARAM_RATE) != CAP_RATE ||
	    iv_get(&hw, SNDRV_PCM_HW_PARAM_CHANNELS) != channels ||
	    frame_bytes != 2 * channels || !period_frames) {
		printf("error=geometry_not_as_requested\n");
		goto out_fd;
	}

	memset(&sw, 0, sizeof(sw));
	sw.tstamp_mode = SNDRV_PCM_TSTAMP_NONE;
	sw.period_step = 1;
	sw.avail_min = period_frames;
	sw.start_threshold = 1;
	sw.stop_threshold = iv_get(&hw, SNDRV_PCM_HW_PARAM_BUFFER_SIZE);
	sw.boundary = iv_get(&hw, SNDRV_PCM_HW_PARAM_BUFFER_SIZE);
	while (sw.boundary && sw.boundary * 2 <= LONG_MAX - sw.boundary)
		sw.boundary *= 2;
	rc = ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw);
	printf("sw_params_rc=%d\n", rc == 0 ? 0 : -errno);
	rc = ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, 0);
	printf("prepare_rc=%d\n", rc == 0 ? 0 : -errno);
	if (rc < 0)
		goto out_fd;
	rc = ioctl(fd, SNDRV_PCM_IOCTL_START, 0);
	printf("start_rc=%d\n", rc == 0 ? 0 : -errno);
	if (rc < 0)
		goto out_fd;

	buf = malloc((size_t)period_frames * frame_bytes);
	if (!buf) {
		printf("error=oom\n");
		goto out_fd;
	}
	while (got < want) {
		n = want - got < period_frames ? want - got : period_frames;
		xf.result = 0;
		xf.buf = buf;
		xf.frames = n;
		rc = ioctl(fd, SNDRV_PCM_IOCTL_READI_FRAMES, &xf);
		if (rc < 0) {
			if (errno == EPIPE) {		/* overrun: count it, recover */
				xruns++;
				clock_gettime(CLOCK_BOOTTIME, &ts);
				printf("xrun_%lu_uptime=%ld.%03ld\nxrun_%lu_at_frame=%lu\n",
				       xruns, (long)ts.tv_sec, ts.tv_nsec / 1000000L, xruns, got);
				if (ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, 0) < 0 ||
				    ioctl(fd, SNDRV_PCM_IOCTL_START, 0) < 0)
					break;
				continue;
			}
			printf("read_errno=%d\n", errno);
			break;
		}
		for (i = 0; i < (unsigned long)xf.result * channels; i++) {
			int s = buf[i];

			if (s < 0)
				s = -s;
			if (s > peak)
				peak = s;
			sumsq += (long long)buf[i] * buf[i];
		}
		if (fwrite(buf, frame_bytes, xf.result, f) != (size_t)xf.result) {
			printf("error=short_write\n");
			break;
		}
		got += xf.result;
	}
	free(buf);
	ioctl(fd, SNDRV_PCM_IOCTL_DROP, 0);

	if (wav_header(f, channels, (uint32_t)(got * frame_bytes)) == 0 && got == want)
		ret = 0;
	printf("frames_read=%lu\nframes_wanted=%lu\nxruns=%lu\npeak=%d\nmean_square=%lld\noutput=%s\ncomplete=%d\n",
	       got, want, xruns, peak, got ? sumsq / (long long)(got * channels) : 0,
	       out, ret == 0);
out_fd:
	close(fd);
	fclose(f);
	return ret;
}
