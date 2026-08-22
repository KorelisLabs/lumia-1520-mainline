/*
 * alsa-setctl -- a minimal ALSA control-plane helper.
 *
 * WHY THIS EXISTS
 *
 * The build-2 gate must enable "SLIMBUS_0_RX Audio Mixer MultiMedia1" before
 * the PCM is opened: that control is what gives q6routing a port_id. Without
 * it q6routing_stream_open() connects nothing, the FE never reaches the BE,
 * and every downstream check fails for a reason that has nothing to do with
 * the DSP. The device has no amixer, no tinymix, no alsactl, and no DNS with
 * which to fetch them.
 *
 * WHAT IT DELIBERATELY CANNOT DO
 *
 * It opens only /dev/snd/controlC*. It never opens a PCM device, never calls
 * write(), and issues no PCM ioctl, so it cannot start a stream. The absence
 * of RUN is the central claim of the milestone this serves, and a helper that
 * could move samples would undermine it no matter how it were invoked.
 *
 * --list is not a convenience. Asserting that the expected control name is
 * present, and reading the value back after writing it, is the difference
 * between "the route was enabled" and "a write returned 0".
 *
 * Output is key=value, one per line, for the gate to parse.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <sound/asound.h>

static const char *type_name(int t)
{
	switch (t) {
	case SNDRV_CTL_ELEM_TYPE_BOOLEAN:    return "BOOLEAN";
	case SNDRV_CTL_ELEM_TYPE_INTEGER:    return "INTEGER";
	case SNDRV_CTL_ELEM_TYPE_ENUMERATED: return "ENUMERATED";
	case SNDRV_CTL_ELEM_TYPE_BYTES:      return "BYTES";
	case SNDRV_CTL_ELEM_TYPE_INTEGER64:  return "INTEGER64";
	default:                             return "OTHER";
	}
}

/* Two-pass: ask how many elements exist, then fetch that many. */
static struct snd_ctl_elem_id *fetch_ids(int fd, unsigned int *n_out)
{
	struct snd_ctl_elem_id *ids;
	struct snd_ctl_elem_list list;

	memset(&list, 0, sizeof(list));
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list) < 0) {
		printf("error=ELEM_LIST_count:%s\n", strerror(errno));
		return NULL;
	}
	if (list.count == 0) {
		*n_out = 0;
		return calloc(1, sizeof(*ids));
	}
	ids = calloc(list.count, sizeof(*ids));
	if (!ids) {
		printf("error=oom\n");
		return NULL;
	}
	list.space = list.count;
	list.offset = 0;
	list.pids = ids;
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list) < 0) {
		printf("error=ELEM_LIST_fetch:%s\n", strerror(errno));
		free(ids);
		return NULL;
	}
	*n_out = list.used;
	return ids;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: alsa-setctl [-D dev] --list\n"
		"       alsa-setctl [-D dev] --set NAME VALUE\n"
		"       alsa-setctl [-D dev] --get NAME\n");
}

int main(int argc, char **argv)
{
	const char *dev = "/dev/snd/controlC0";
	const char *name = NULL;
	int do_list = 0, do_set = 0, do_get = 0;
	long setval = 0;
	unsigned int n = 0, i, j;
	int fd, found = -1, rc = 0;
	struct snd_ctl_elem_id *ids;
	struct snd_ctl_elem_info info;
	struct snd_ctl_elem_value val;

	for (i = 1; i < (unsigned int)argc; i++) {
		if (!strcmp(argv[i], "-D") && i + 1 < (unsigned int)argc) {
			dev = argv[++i];
		} else if (!strcmp(argv[i], "--list")) {
			do_list = 1;
		} else if (!strcmp(argv[i], "--set") && i + 2 < (unsigned int)argc) {
			do_set = 1;
			name = argv[++i];
			setval = strtol(argv[++i], NULL, 0);
		} else if (!strcmp(argv[i], "--get") && i + 1 < (unsigned int)argc) {
			do_get = 1;
			name = argv[++i];
		} else {
			usage();
			return 2;
		}
	}
	if (!do_list && !do_set && !do_get) {
		usage();
		return 2;
	}

	fd = open(dev, O_RDWR);
	if (fd < 0) {
		printf("ctl_dev=%s\nerror=open:%s\n", dev, strerror(errno));
		return 1;
	}
	printf("ctl_dev=%s\n", dev);

	ids = fetch_ids(fd, &n);
	if (!ids) {
		close(fd);
		return 1;
	}
	printf("ctl_count=%u\n", n);

	if (do_list)
		for (i = 0; i < n; i++)
			printf("ctl=%u %s\n", ids[i].numid, (char *)ids[i].name);

	if (!name) {
		free(ids);
		close(fd);
		return 0;
	}

	for (i = 0; i < n; i++) {
		if (!strcmp((char *)ids[i].name, name)) {
			found = (int)i;
			break;
		}
	}
	printf("name=%s\n", name);
	printf("found=%d\n", found >= 0 ? 1 : 0);
	if (found < 0) {
		free(ids);
		close(fd);
		return 1;
	}

	memset(&info, 0, sizeof(info));
	info.id = ids[found];
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &info) < 0) {
		printf("error=ELEM_INFO:%s\n", strerror(errno));
		free(ids);
		close(fd);
		return 1;
	}
	printf("numid=%u\ntype=%s\ncount=%u\n",
	       info.id.numid, type_name(info.type), info.count);

	if (do_set) {
		memset(&val, 0, sizeof(val));
		val.id = ids[found];
		for (j = 0; j < info.count && j < 128; j++) {
			if (info.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED)
				val.value.enumerated.item[j] = (unsigned int)setval;
			else
				val.value.integer.value[j] = setval;
		}
		if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &val) < 0) {
			printf("write_rc=-1\nerror=ELEM_WRITE:%s\n", strerror(errno));
			rc = 1;
		} else {
			printf("write_rc=0\n");
		}
	}

	/* Always read back: a write that returned 0 is not proof of a value. */
	memset(&val, 0, sizeof(val));
	val.id = ids[found];
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_READ, &val) < 0) {
		printf("error=ELEM_READ:%s\n", strerror(errno));
		rc = 1;
	} else {
		printf("readback=");
		for (j = 0; j < info.count && j < 8; j++) {
			if (info.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED)
				printf("%s%u", j ? "," : "", val.value.enumerated.item[j]);
			else
				printf("%s%ld", j ? "," : "", (long)val.value.integer.value[j]);
		}
		printf("\n");
	}

	free(ids);
	close(fd);
	return rc;
}
