// SPDX-License-Identifier: GPL-2.0
/*
 * pcm-prepare-only -- drive an ALSA PCM to PREPARED and stop there.
 *
 * WHY THIS EXISTS
 *
 * The Q6 control-plane milestone must prove that the DSP acknowledges ASM,
 * ADM and AFE setup commands WITHOUT moving a single sample. ALSA draws that
 * line exactly where we need it: hw_params and prepare are the setup phase,
 * and trigger(START) is what begins the stream.
 *
 * aplay cannot express that. Its first write() drives trigger(START), and
 * from there the session runs and ASM_DATA_CMD_WRITE_V2 goes out. So the
 * instrument has to be its own program:
 *
 *     open -> HW_PARAMS -> SW_PARAMS -> PREPARE -> STATUS -> DROP -> close
 *
 *     NEVER write(), never mmap-commit, never SNDRV_PCM_IOCTL_START,
 *     never DRAIN.
 *
 * DELIBERATELY NOT alsa-lib. libasound helpfully does things on your behalf --
 * that helpfulness is the exact hazard here. Raw ioctls mean the syscall
 * sequence in the source is the syscall sequence on the wire.
 *
 * WHAT THE KERNEL DOES FOR US, checked in 6.16.12 rather than assumed:
 *
 *   - snd_pcm_hw_params() calls snd_pcm_hw_refine() and THEN
 *     snd_pcm_hw_params_choose(), so under-determined parameters are resolved
 *     by the kernel. This program sets only what it cares about (access,
 *     format, subformat, rate, channels) and leaves the rest "any". No
 *     REFINE pass of its own is needed.
 *
 *   - snd_pcm_do_stop() issues trigger(STOP) only when snd_pcm_running(), i.e.
 *     RUNNING or DRAINING. From PREPARED it does not, so DROP here is a pure
 *     PREPARED -> SETUP transition and this program bakes in NO expectation
 *     about which driver callbacks fire. What actually fires is for the
 *     kernel-side evidence to report.
 *
 * BUILD: cross-compiled for armv7 musl; see tools/build-pcm-helper.sh.
 *
 * Exit: 0 reached PREPARED and cleaned up, 1 a step failed, 2 usage/open error.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <sound/asound.h>

/*
 * A start threshold this large cannot be reached by any buffer we configure.
 * Belt and braces: this program never writes, but if it ever did, the stream
 * still could not auto-start. The whole point of the instrument is that
 * START is unreachable, so it is worth making that true twice.
 */
#define NEVER_START_THRESHOLD	0x7fffffffUL

static void mask_none(struct snd_mask *m)
{
	memset(m, 0, sizeof(*m));
}

static void mask_any(struct snd_mask *m)
{
	memset(m, 0xff, sizeof(*m));
}

static void mask_set(struct snd_mask *m, unsigned int val)
{
	mask_none(m);
	m->bits[val >> 5] |= (1u << (val & 31));
}

static void interval_any(struct snd_interval *i)
{
	memset(i, 0, sizeof(*i));
	i->min = 0;
	i->max = UINT_MAX;
}

static void interval_set(struct snd_interval *i, unsigned int val)
{
	memset(i, 0, sizeof(*i));
	i->min = val;
	i->max = val;
	i->integer = 1;
}

static struct snd_mask *hw_mask(struct snd_pcm_hw_params *p, int var)
{
	return &p->masks[var - SNDRV_PCM_HW_PARAM_FIRST_MASK];
}

static struct snd_interval *hw_interval(struct snd_pcm_hw_params *p, int var)
{
	return &p->intervals[var - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
}

static void hw_params_any(struct snd_pcm_hw_params *p)
{
	int v;

	memset(p, 0, sizeof(*p));
	for (v = SNDRV_PCM_HW_PARAM_FIRST_MASK;
	     v <= SNDRV_PCM_HW_PARAM_LAST_MASK; v++)
		mask_any(hw_mask(p, v));
	for (v = SNDRV_PCM_HW_PARAM_FIRST_INTERVAL;
	     v <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL; v++)
		interval_any(hw_interval(p, v));
	p->rmask = ~0u;
	p->cmask = 0;
	p->info = ~0u;
}

static unsigned int iv(struct snd_pcm_hw_params *p, int var)
{
	return hw_interval(p, var)->min;
}

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

static void usage(const char *me)
{
	fprintf(stderr,
"usage: %s -D <pcm-device> [-r rate] [-c channels] [-f S16_LE|S24_LE|S32_LE]\n"
"\n"
"  Drives the PCM to PREPARED and stops. Never writes, never starts.\n"
"  Example: %s -D /dev/snd/pcmC0D0p -r 48000 -c 1 -f S16_LE\n",
		me, me);
}

int main(int argc, char **argv)
{
	const char *dev = NULL;
	const char *fmt_name = "S16_LE";
	unsigned int rate = 48000, channels = 1, format = SNDRV_PCM_FORMAT_S16_LE;
	struct snd_pcm_hw_params hw;
	struct snd_pcm_sw_params sw;
	struct snd_pcm_status st;
	struct snd_pcm_info info;
	int fd, rc, opt;
	int rc_hw = -1, rc_sw = -1, rc_prep = -1, rc_status = -1, rc_drop = -1;
	int reached_prepared = 0;

	while ((opt = getopt(argc, argv, "D:r:c:f:h")) != -1) {
		switch (opt) {
		case 'D': dev = optarg; break;
		case 'r': rate = strtoul(optarg, NULL, 0); break;
		case 'c': channels = strtoul(optarg, NULL, 0); break;
		case 'f':
			fmt_name = optarg;
			if (!strcmp(optarg, "S16_LE"))
				format = SNDRV_PCM_FORMAT_S16_LE;
			else if (!strcmp(optarg, "S24_LE"))
				format = SNDRV_PCM_FORMAT_S24_LE;
			else if (!strcmp(optarg, "S32_LE"))
				format = SNDRV_PCM_FORMAT_S32_LE;
			else {
				fprintf(stderr, "unknown format %s\n", optarg);
				return 2;
			}
			break;
		default:
			usage(argv[0]);
			return 2;
		}
	}
	if (!dev) {
		usage(argv[0]);
		return 2;
	}

	printf("tool=pcm-prepare-only\n");
	printf("device=%s\n", dev);
	printf("requested_rate=%u\n", rate);
	printf("requested_channels=%u\n", channels);
	printf("requested_format=%s\n", fmt_name);

	/* O_NONBLOCK so a driver that would block on open cannot hang the run. */
	fd = open(dev, O_WRONLY | O_NONBLOCK);
	if (fd < 0) {
		printf("open_errno=%d\n", errno);
		printf("open_error=%s\n", strerror(errno));
		printf("final_rc=2\n");
		fprintf(stderr, "open(%s): %s\n", dev, strerror(errno));
		return 2;
	}
	printf("open_rc=0\n");

	memset(&info, 0, sizeof(info));
	if (ioctl(fd, SNDRV_PCM_IOCTL_INFO, &info) == 0) {
		printf("pcm_id=%s\n", info.id);
		printf("pcm_name=%s\n", info.name);
		printf("pcm_subname=%s\n", info.subname);
		printf("pcm_card=%d\n", info.card);
		printf("pcm_device=%u\n", info.device);
	}

	/* --------------------------------------------------------- HW_PARAMS */
	hw_params_any(&hw);
	mask_set(hw_mask(&hw, SNDRV_PCM_HW_PARAM_ACCESS),
		 SNDRV_PCM_ACCESS_RW_INTERLEAVED);
	mask_set(hw_mask(&hw, SNDRV_PCM_HW_PARAM_FORMAT), format);
	mask_set(hw_mask(&hw, SNDRV_PCM_HW_PARAM_SUBFORMAT),
		 SNDRV_PCM_SUBFORMAT_STD);
	interval_set(hw_interval(&hw, SNDRV_PCM_HW_PARAM_RATE), rate);
	interval_set(hw_interval(&hw, SNDRV_PCM_HW_PARAM_CHANNELS), channels);
	/*
	 * Everything else is left "any" on purpose: snd_pcm_hw_params() runs
	 * refine and then _choose(), so the kernel resolves period and buffer
	 * sizes from the driver's own constraints. Imposing our guesses here
	 * would test our guesses rather than the driver.
	 */

	rc_hw = ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw);
	printf("hw_params_rc=%d\n", rc_hw);
	if (rc_hw < 0) {
		printf("hw_params_errno=%d\n", errno);
		printf("hw_params_error=%s\n", strerror(errno));
	} else {
		printf("actual_rate=%u\n", iv(&hw, SNDRV_PCM_HW_PARAM_RATE));
		printf("actual_channels=%u\n",
		       iv(&hw, SNDRV_PCM_HW_PARAM_CHANNELS));
		printf("actual_period_size=%u\n",
		       iv(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE));
		printf("actual_periods=%u\n",
		       iv(&hw, SNDRV_PCM_HW_PARAM_PERIODS));
		printf("actual_buffer_size=%u\n",
		       iv(&hw, SNDRV_PCM_HW_PARAM_BUFFER_SIZE));
		printf("actual_period_bytes=%u\n",
		       iv(&hw, SNDRV_PCM_HW_PARAM_PERIOD_BYTES));
		printf("actual_buffer_bytes=%u\n",
		       iv(&hw, SNDRV_PCM_HW_PARAM_BUFFER_BYTES));
	}

	/* --------------------------------------------------------- SW_PARAMS */
	if (rc_hw == 0) {
		memset(&sw, 0, sizeof(sw));
		sw.tstamp_mode = SNDRV_PCM_TSTAMP_NONE;
		sw.period_step = 1;
		sw.avail_min = iv(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE);
		sw.start_threshold = NEVER_START_THRESHOLD;
		sw.stop_threshold = ULONG_MAX;
		sw.silence_threshold = 0;
		sw.silence_size = 0;
		sw.boundary = iv(&hw, SNDRV_PCM_HW_PARAM_BUFFER_SIZE);
		while (sw.boundary && sw.boundary * 2 <= LONG_MAX - sw.boundary)
			sw.boundary *= 2;

		rc_sw = ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw);
		printf("sw_params_rc=%d\n", rc_sw);
		if (rc_sw < 0) {
			printf("sw_params_errno=%d\n", errno);
			printf("sw_params_error=%s\n", strerror(errno));
		} else {
			printf("start_threshold=%lu\n",
			       (unsigned long)sw.start_threshold);
		}
	}

	/* ----------------------------------------------------------- PREPARE */
	if (rc_hw == 0 && rc_sw == 0) {
		rc_prep = ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, NULL);
		printf("prepare_rc=%d\n", rc_prep);
		if (rc_prep < 0) {
			printf("prepare_errno=%d\n", errno);
			printf("prepare_error=%s\n", strerror(errno));
		}
	}

	/* ------------------------------------------------------------ STATUS */
	memset(&st, 0, sizeof(st));
	rc_status = ioctl(fd, SNDRV_PCM_IOCTL_STATUS, &st);
	if (rc_status == 0) {
		printf("state=%s\n", state_name(st.state));
		printf("state_num=%d\n", (int)st.state);
		if (st.state == SNDRV_PCM_STATE_PREPARED)
			reached_prepared = 1;
	} else {
		printf("status_rc=%d\n", rc_status);
		printf("status_errno=%d\n", errno);
	}
	printf("reached_prepared=%d\n", reached_prepared);

	/* -------------------------------------------------------------- DROP */
	/*
	 * From PREPARED this is a pure state transition to SETUP: the kernel
	 * only issues trigger(STOP) when snd_pcm_running(). No claim is made
	 * here about which driver callbacks fire -- that is the kernel-side
	 * evidence's job.
	 */
	rc_drop = ioctl(fd, SNDRV_PCM_IOCTL_DROP, NULL);
	printf("drop_rc=%d\n", rc_drop);
	if (rc_drop < 0)
		printf("drop_errno=%d\n", errno);

	memset(&st, 0, sizeof(st));
	if (ioctl(fd, SNDRV_PCM_IOCTL_STATUS, &st) == 0)
		printf("state_after_drop=%s\n", state_name(st.state));

	close(fd);
	printf("close_rc=0\n");

	/*
	 * The negative assertions. These are constants, not measurements --
	 * this program contains no write(), no START ioctl and no DRAIN, so
	 * they cannot be anything else. They are printed so the evidence file
	 * records the claim explicitly rather than by omission, and so the
	 * kernel side has something to be checked against.
	 */
	printf("write_calls=0\n");
	printf("frames_submitted=0\n");
	printf("start_requested=0\n");
	printf("drain_requested=0\n");
	printf("mmap_committed=0\n");

	rc = (rc_hw == 0 && rc_sw == 0 && rc_prep == 0 && reached_prepared &&
	      rc_drop == 0) ? 0 : 1;
	printf("final_rc=%d\n", rc);
	return rc;
}
