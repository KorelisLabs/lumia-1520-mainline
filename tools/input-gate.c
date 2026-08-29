/*
 * input-gate -- the operator's hand on a run that has no ssh.
 *
 * WHY THIS EXISTS
 *
 * C3a is measured on a scope. Section 21 of the C3 map requires the phone to
 * be disconnected from USB before scope ground is attached, and with USB gone
 * there is no ssh. So the run must be started, then complete on its own, while
 * the only channel left between the operator and the experiment is the two
 * hardware buttons.
 *
 * That makes these buttons a safety interlock rather than a convenience, and
 * the polarity of every decision in this file is chosen accordingly:
 *
 *   Volume Up   = approve, advance exactly one state
 *   Volume Down = abort, tear the whole thing down
 *   timeout     = ABORT. Never proceed.
 *   any error   = ABORT. Never proceed.
 *
 * A gate that failed open would enable a power amplifier into a jack with a
 * probe in it because a file could not be opened.
 *
 * FOUR HARDWARE FACTS, ESTABLISHED ON THE DEVICE AND NOT RE-DERIVED HERE
 *
 * 1. The two keys are on DIFFERENT input devices. Approve is KEY_VOLUMEUP
 *    (115) on "gpio-keys"; abort is KEY_VOLUMEDOWN (114) on "pm8941_resin".
 *    Confirmed by real presses.
 *
 * 2. eventN numbering is NOT stable across boots -- the Synaptics touchscreen
 *    has already re-ordered it once. Nothing here hardcodes a node. Both
 *    devices are resolved by NAME from /proc/bus/input/devices at arm time,
 *    and the resolution is then CONFIRMED against the open file descriptor
 *    with EVIOCGNAME, so a node that moved between the parse and the open is
 *    caught rather than silently used.
 *
 * 3. input_event is 16 bytes on this device: sec(4) usec(4) type(2) code(2)
 *    value(4), little endian. This file does NOT use struct input_event from
 *    the headers -- on a 64-bit-time build that struct is 24 bytes and every
 *    field would be read from the wrong offset. Events are parsed from a byte
 *    buffer at fixed offsets, which is correct whatever the host headers say
 *    and fails loudly if the stride is ever not 16.
 *
 * 4. Presses are value == 1. Releases (0) and autorepeat (2) are ignored, so
 *    holding a button is one decision and not a stream of them.
 *
 * NO QUEUED PRESSES
 *
 * evdev delivers events that arrive after the descriptor is opened, so a
 * button pressed during a previous phase cannot satisfy a later --ask.
 * Belt and braces, --ask also drains anything already readable before it
 * begins waiting. A run must never advance on a press the operator made
 * while looking at something else.
 *
 * The abort watcher is the deliberate exception: it holds its descriptor open
 * for the whole run precisely so that no abort press can ever be missed.
 *
 * Exit codes -- distinct, and the runner depends on every one of them:
 *
 *   0  approve pressed / watcher armed and fired / resolve succeeded
 *   1  ABORT pressed
 *   2  TIMEOUT -- which the caller must treat as an abort
 *   3  setup error: a device missing, a name mismatch, a read failure
 *   4  already armed: another instance holds the lock
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <linux/input.h>

/* The four facts above, as constants. */
#define APPROVE_DEV	"gpio-keys"
#define APPROVE_KEY	115		/* KEY_VOLUMEUP */
#define ABORT_DEV	"pm8941_resin"
#define ABORT_KEY	114		/* KEY_VOLUMEDOWN */

/*
 * THE ON-DEVICE EVENT STRIDE, AND WHY IT IS NOT sizeof(struct input_event).
 *
 * Measured on the phone: 16 bytes. The kernel headers on a build with a
 * 64-bit time_t describe 24, and a reader using that layout would find `type`
 * where `usec` is and conclude that nothing was ever pressed -- an interlock
 * that silently never fires. So the layout is written out here, and the read
 * loop refuses any buffer that is not a whole number of these.
 */
#define EV_STRIDE	16
#define EV_OFF_TYPE	8
#define EV_OFF_CODE	10
#define EV_OFF_VALUE	12

#define VAL_PRESS	1

enum mode {
	MODE_NONE = 0,
	MODE_RESOLVE,
	MODE_PARSE,
	MODE_SELFTEST_ABORT,
	MODE_ASK,
	MODE_WATCH,
};

enum rc {
	RC_APPROVE = 0,
	RC_ABORT = 1,
	RC_TIMEOUT = 2,
	RC_SETUP = 3,
	RC_BUSY = 4,
};

static const char *proc_devices = "/proc/bus/input/devices";
static const char *dev_dir = "/dev/input";

static unsigned short le16(const unsigned char *p)
{
	return (unsigned short)(p[0] | (p[1] << 8));
}

static int le32(const unsigned char *p)
{
	return (int)((unsigned int)p[0] | ((unsigned int)p[1] << 8) |
		     ((unsigned int)p[2] << 16) | ((unsigned int)p[3] << 24));
}

/*
 * Find the event node for a device by its exact name.
 *
 * /proc/bus/input/devices is a sequence of blocks separated by blank lines:
 *
 *   I: Bus=0019 Vendor=0001 Product=0001 Version=0100
 *   N: Name="gpio-keys"
 *   H: Handlers=kbd event2
 *
 * The match is on the WHOLE quoted name, not a prefix. "gpio-keys" and
 * "gpio-keys-wakeup" are different devices on some boards, and a prefix match
 * that picked the wrong one would put the interlock on a button nobody is
 * going to press.
 */
static int find_event_node(const char *from, const char *want, char *out,
			   size_t outsz)
{
	FILE *f = fopen(from, "r");
	char line[512];
	int matched = 0;

	if (!f)
		return -1;

	while (fgets(line, sizeof(line), f)) {
		if (line[0] == '\n' || line[0] == '\r') {
			matched = 0;		/* block boundary */
			continue;
		}
		if (line[0] == 'N' && line[1] == ':') {
			char *q = strchr(line, '"');
			char *e = q ? strchr(q + 1, '"') : NULL;

			matched = 0;
			if (q && e) {
				*e = '\0';
				matched = strcmp(q + 1, want) == 0;
			}
			continue;
		}
		if (matched && line[0] == 'H' && line[1] == ':') {
			char *tok = strstr(line, "event");

			while (tok) {
				/*
				 * "event" must start a token, so that a
				 * handler called something-event does not
				 * match, and must be followed by digits.
				 */
				int ok = (tok == line || tok[-1] == ' ' ||
					  tok[-1] == '=');
				char *p = tok + 5;
				size_t n = 0;

				while (p[n] >= '0' && p[n] <= '9')
					n++;
				if (ok && n) {
					snprintf(out, outsz, "%s/event%.*s",
						 dev_dir, (int)n, p);
					fclose(f);
					return 0;
				}
				tok = strstr(tok + 1, "event");
			}
		}
	}
	fclose(f);
	return -1;
}

/*
 * Open the node AND confirm the kernel agrees it is the device we resolved.
 *
 * This is the check that makes fact 2 safe. Resolving by name from a text file
 * and then opening a path is two steps, and between them the node could in
 * principle be something else. EVIOCGNAME asks the open descriptor itself.
 */
static int open_verified(const char *want, char *path, size_t pathsz)
{
	char got[256] = { 0 };
	int fd;

	if (find_event_node(proc_devices, want, path, pathsz) != 0) {
		fprintf(stderr, "input-gate: no input device named \"%s\" in %s\n",
			want, proc_devices);
		return -1;
	}
	fd = open(path, O_RDONLY | O_NONBLOCK);
	if (fd < 0) {
		fprintf(stderr, "input-gate: cannot open %s for \"%s\": %s\n",
			path, want, strerror(errno));
		return -1;
	}
	if (ioctl(fd, EVIOCGNAME(sizeof(got) - 1), got) < 0) {
		fprintf(stderr, "input-gate: EVIOCGNAME failed on %s: %s\n",
			path, strerror(errno));
		close(fd);
		return -1;
	}
	if (strcmp(got, want) != 0) {
		fprintf(stderr,
			"input-gate: %s reports \"%s\" but \"%s\" was resolved -- the node moved\n",
			path, got, want);
		close(fd);
		return -1;
	}
	return fd;
}

/* Discard anything already readable, so no earlier press can advance a gate. */
static void drain(int fd)
{
	unsigned char buf[EV_STRIDE * 16];

	while (read(fd, buf, sizeof(buf)) > 0)
		;
}

static long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

/*
 * Wait for a press of one of the watched keys.
 *
 * fds[i]/keys[i] are parallel arrays; returns the index that fired, -1 on
 * timeout, -2 on a read error. A short or misaligned read is an ERROR, not
 * something to resynchronise past: if the stride is not what this program
 * believes, every field it parses afterwards is meaningless.
 */
static int wait_press(int *fds, const int *keys, int n, int timeout_ms)
{
	struct pollfd pfd[2];
	long deadline = timeout_ms >= 0 ? now_ms() + timeout_ms : 0;
	int i;

	for (i = 0; i < n; i++) {
		pfd[i].fd = fds[i];
		pfd[i].events = POLLIN;
	}

	for (;;) {
		int wait_ms = -1;
		int rc;

		if (timeout_ms >= 0) {
			long left = deadline - now_ms();

			if (left <= 0)
				return -1;
			wait_ms = (int)(left > INT_MAX ? INT_MAX : left);
		}
		rc = poll(pfd, n, wait_ms);
		if (rc < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "input-gate: poll failed: %s\n",
				strerror(errno));
			return -2;
		}
		if (rc == 0)
			return -1;

		for (i = 0; i < n; i++) {
			unsigned char buf[EV_STRIDE * 32];
			ssize_t got, off;

			if (!(pfd[i].revents & POLLIN))
				continue;
			got = read(fds[i], buf, sizeof(buf));
			if (got < 0) {
				if (errno == EAGAIN || errno == EINTR)
					continue;
				fprintf(stderr, "input-gate: read failed: %s\n",
					strerror(errno));
				return -2;
			}
			if (got == 0 || got % EV_STRIDE) {
				fprintf(stderr,
					"input-gate: %zd bytes is not a whole number of %d-byte events -- the layout is not what this build assumes\n",
					got, EV_STRIDE);
				return -2;
			}
			for (off = 0; off < got; off += EV_STRIDE) {
				const unsigned char *e = buf + off;

				if (le16(e + EV_OFF_TYPE) != EV_KEY)
					continue;
				if (le16(e + EV_OFF_CODE) != keys[i])
					continue;
				if (le32(e + EV_OFF_VALUE) != VAL_PRESS)
					continue;	/* release / autorepeat */
				return i;
			}
		}
	}
}

/*
 * One instance at a time.
 *
 * Two armed watchers would each independently trigger a teardown, and two
 * armed runs would fight over the codec. The lock is held for as long as the
 * process lives and is released by the kernel when it dies, so a crashed run
 * does not leave the interlock permanently claimed.
 */
static int take_lock(const char *path)
{
	int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);

	if (fd < 0) {
		fprintf(stderr, "input-gate: cannot open lock %s: %s\n",
			path, strerror(errno));
		return -1;
	}
	if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
		fprintf(stderr,
			"input-gate: %s is already held -- another arm is live\n",
			path);
		close(fd);
		return -2;
	}
	return fd;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: input-gate --resolve\n"
		"       input-gate --parse FILE\n"
		"       input-gate --selftest-abort [--timeout SEC]\n"
		"       input-gate --ask [--timeout SEC] [--label TEXT]\n"
		"       input-gate --watch --flag PATH [--lock PATH]\n"
		"\n"
		"exit: 0 approve  1 abort  2 timeout(=abort)  3 setup  4 busy\n");
}

int main(int argc, char **argv)
{
	enum mode mode = MODE_NONE;
	const char *flag = NULL;
	const char *label = "gate";
	const char *lock = "/run/input-gate.lock";
	const char *parse_from = NULL;
	char apath[PATH_MAX], bpath[PATH_MAX];
	int timeout = -1, afd = -1, bfd = -1, lockfd = -1;
	int fds[2], keys[2], hit, i;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--resolve"))
			mode = MODE_RESOLVE;
		else if (!strcmp(argv[i], "--parse") && i + 1 < argc) {
			mode = MODE_PARSE;
			parse_from = argv[++i];
		}
		else if (!strcmp(argv[i], "--selftest-abort"))
			mode = MODE_SELFTEST_ABORT;
		else if (!strcmp(argv[i], "--ask"))
			mode = MODE_ASK;
		else if (!strcmp(argv[i], "--watch"))
			mode = MODE_WATCH;
		else if (!strcmp(argv[i], "--timeout") && i + 1 < argc)
			timeout = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--flag") && i + 1 < argc)
			flag = argv[++i];
		else if (!strcmp(argv[i], "--label") && i + 1 < argc)
			label = argv[++i];
		else if (!strcmp(argv[i], "--lock") && i + 1 < argc)
			lock = argv[++i];
		else {
			usage();
			return RC_SETUP;
		}
	}
	if (mode == MODE_NONE) {
		usage();
		return RC_SETUP;
	}
	if (mode == MODE_WATCH && !flag) {
		fprintf(stderr, "input-gate: --watch needs --flag\n");
		return RC_SETUP;
	}

	/*
	 * --parse: THE RESOLVER ALONE, AGAINST A SUPPLIED FIXTURE.
	 *
	 * This is how the offline selftest proves the run survives the input
	 * nodes being renumbered between boots -- it feeds in a
	 * /proc/bus/input/devices captured with the numbering moved and checks
	 * that both devices are still found at their new nodes.
	 *
	 * IT CANNOT ARM ANYTHING. It opens no device, reads no event, takes no
	 * lock and never returns RC_APPROVE from a button. The live modes below
	 * still read the real path, which is a compiled-in constant with no
	 * environment override -- repointing the interlock's device discovery
	 * from outside the binary is exactly the capability a safety interlock
	 * should not have, so the test hook is a separate mode rather than a
	 * setting the real modes share.
	 */
	if (mode == MODE_PARSE) {
		char p1[PATH_MAX], p2[PATH_MAX];
		int r1 = find_event_node(parse_from, APPROVE_DEV, p1, sizeof(p1));
		int r2 = find_event_node(parse_from, ABORT_DEV, p2, sizeof(p2));

		printf("parse_from=%s\n", parse_from);
		printf("approve=%s\n", r1 == 0 ? p1 : "NOT-FOUND");
		printf("abort=%s\n", r2 == 0 ? p2 : "NOT-FOUND");
		if (r1 != 0 || r2 != 0) {
			printf("parse=REFUSE\n");
			return RC_SETUP;
		}
		if (!strcmp(p1, p2)) {
			/*
			 * Both keys resolving to ONE node means the fixture --
			 * or the phone -- is not the two-device arrangement
			 * this interlock was designed against, and an abort
			 * that shares a descriptor with approve is not an
			 * independent abort.
			 */
			printf("parse=REFUSE reason=same_node\n");
			return RC_SETUP;
		}
		printf("parse=OK\n");
		return RC_APPROVE;
	}

	/*
	 * BOTH devices are resolved for every mode, including --resolve and
	 * --ask. Refusing to arm when EITHER is missing is the point: an
	 * approve button that works and an abort button that does not is
	 * strictly worse than neither, because it looks armed.
	 */
	afd = open_verified(APPROVE_DEV, apath, sizeof(apath));
	bfd = open_verified(ABORT_DEV, bpath, sizeof(bpath));
	if (afd < 0 || bfd < 0) {
		fprintf(stderr,
			"input-gate: REFUSING TO ARM -- both the approve and the abort device must be present\n");
		if (afd >= 0)
			close(afd);
		if (bfd >= 0)
			close(bfd);
		return RC_SETUP;
	}

	printf("approve_dev=%s approve_node=%s approve_key=%d\n",
	       APPROVE_DEV, apath, APPROVE_KEY);
	printf("abort_dev=%s abort_node=%s abort_key=%d\n",
	       ABORT_DEV, bpath, ABORT_KEY);
	fflush(stdout);

	if (mode == MODE_RESOLVE) {
		close(afd);
		close(bfd);
		return RC_APPROVE;
	}

	if (mode == MODE_WATCH) {
		lockfd = take_lock(lock);
		if (lockfd == -2)
			return RC_BUSY;
		if (lockfd < 0)
			return RC_SETUP;
	}

	switch (mode) {
	case MODE_SELFTEST_ABORT:
		/*
		 * THE ABORT PATH IS PROVEN ON HARDWARE BEFORE ANYTHING ARMS.
		 *
		 * Not a simulation and not an assumption: the operator
		 * physically presses Volume Down, and this reads it through
		 * the same device, the same stride and the same key code the
		 * live abort watcher will use. Until that press happens, no
		 * PA-capable run may start.
		 */
		drain(bfd);
		printf("selftest=await_abort label=%s timeout=%d\n",
		       label, timeout);
		fflush(stdout);
		fds[0] = bfd;
		keys[0] = ABORT_KEY;
		hit = wait_press(fds, keys, 1, timeout < 0 ? -1 : timeout * 1000);
		close(afd);
		close(bfd);
		if (hit == 0) {
			printf("selftest=PASS abort_path_proven=1\n");
			return RC_APPROVE;
		}
		if (hit == -1) {
			printf("selftest=TIMEOUT abort_path_proven=0\n");
			return RC_TIMEOUT;
		}
		printf("selftest=ERROR abort_path_proven=0\n");
		return RC_SETUP;

	case MODE_ASK:
		drain(afd);
		drain(bfd);
		printf("ask=%s timeout=%d\n", label, timeout);
		fflush(stdout);
		fds[0] = afd;
		keys[0] = APPROVE_KEY;
		fds[1] = bfd;
		keys[1] = ABORT_KEY;
		hit = wait_press(fds, keys, 2, timeout < 0 ? -1 : timeout * 1000);
		close(afd);
		close(bfd);
		if (hit == 0) {
			printf("ask=%s result=APPROVE\n", label);
			return RC_APPROVE;
		}
		if (hit == 1) {
			printf("ask=%s result=ABORT\n", label);
			return RC_ABORT;
		}
		if (hit == -1) {
			/* A timeout is an abort. It is never a proceed. */
			printf("ask=%s result=TIMEOUT treated_as=ABORT\n", label);
			return RC_TIMEOUT;
		}
		printf("ask=%s result=ERROR treated_as=ABORT\n", label);
		return RC_SETUP;

	case MODE_WATCH:
		/*
		 * THE INDEPENDENT ABORT WATCHER.
		 *
		 * The approve gates above are blind between calls -- while the
		 * driver is sequencing registers, while the PCM helper runs,
		 * while evidence is being written, and for as long as the main
		 * runner is stalled or wedged, nothing there is reading a
		 * button. This process does nothing else, holds its descriptor
		 * open for the whole run so no press can be missed, and drops
		 * a flag file the instant Volume Down goes down.
		 *
		 * It does NOT tear the codec down itself. One writer to the
		 * codec, always: the flag is the signal, and the runner's
		 * abort path -- which is a single sysfs write to a driver
		 * operation that is idempotent and serialised -- is the actor.
		 * A watcher that also poked registers would be the second
		 * writer this design exists to avoid.
		 */
		printf("watch=armed flag=%s\n", flag);
		fflush(stdout);
		fds[0] = bfd;
		keys[0] = ABORT_KEY;
		hit = wait_press(fds, keys, 1, timeout < 0 ? -1 : timeout * 1000);
		if (hit == 0) {
			int ffd = open(flag, O_WRONLY | O_CREAT | O_TRUNC, 0644);

			if (ffd >= 0) {
				const char *msg = "ABORT volume-down\n";

				if (write(ffd, msg, strlen(msg)) < 0)
					fprintf(stderr,
						"input-gate: flag write failed: %s\n",
						strerror(errno));
				fsync(ffd);
				close(ffd);
			} else {
				fprintf(stderr,
					"input-gate: cannot create flag %s: %s\n",
					flag, strerror(errno));
			}
			printf("watch=FIRED\n");
			fflush(stdout);
			close(afd);
			close(bfd);
			return RC_ABORT;
		}
		close(afd);
		close(bfd);
		printf("watch=%s\n", hit == -1 ? "TIMEOUT" : "ERROR");
		return hit == -1 ? RC_TIMEOUT : RC_SETUP;

	default:
		usage();
		return RC_SETUP;
	}
}
