#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

#ifndef TIOCSTI
#define TIOCSTI 0x5412
#endif

/*
 * ttyinject - pushes <text> (+ newline) into the stdin input queue of the
 * foreground process of a tty, as if typed.
 *
 * ttyinject <text>                 -> target = foreground of our own tty
 * ttyinject -t /dev/pts/N <text>   -> target = foreground process of that tty
 *
 * The target pid is determined here (tcgetpgrp, with a /proc scan fallback);
 * no pid is taken from args.
 *
 * Build:   gcc -O2 -o ttyinject ttyinject.c
 * Install: sudo install -o root -g username -m 4750 ttyinject $HOME/.local/bin/
 *          (TIOCSTI needs CAP_SYS_ADMIN on kernels >= 6.2; mode 4750, group
 *          restricted so no other user can execute it. The binary also
 *          refuses to inject into a tty not owned by the real uid that
 *          invoked it.)
 */

/* Fallback: scan /proc for processes whose stdin (fd 0) is `dev`.
 * Prefer a job leader (pid==pgrp, pid!=sid); otherwise the newest. */
static pid_t scan_proc_for_tty(const char *dev) {
    DIR *d = opendir("/proc");
    if (!d) {
        perror("opendir /proc");
        return -1;
    }

    pid_t best_job = -1, best_any = -1;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!isdigit((unsigned char)e->d_name[0]))
            continue;
        pid_t pid = (pid_t)strtol(e->d_name, NULL, 10);

        char link[64], buf[256];
        snprintf(link, sizeof link, "/proc/%d/fd/0", pid);
        ssize_t n = readlink(link, buf, sizeof buf - 1);
        if (n < 0)
            continue;
        buf[n] = '\0';
        if (strcmp(buf, dev) != 0)
            continue;

        char path[64], sbuf[4096];
        snprintf(path, sizeof path, "/proc/%d/stat", pid);
        int fd = open(path, O_RDONLY);
        if (fd < 0)
            continue;
        n = read(fd, sbuf, sizeof sbuf - 1);
        close(fd);
        if (n <= 0)
            continue;
        sbuf[n] = '\0';

        /* 1 pid  2 (comm)  3 state  4 ppid  5 pgrp  6 session  7 tty_nr ... */
        char *s = strrchr(sbuf, ')');
        if (!s)
            continue;
        char state;
        pid_t ppid, pgrp, sid;
        if (sscanf(s + 1, " %c %d %d %d", &state, &ppid, &pgrp, &sid) != 4)
            continue;
        if (state == 'Z')
            continue;

        if (pid > best_any)
            best_any = pid;
        if (pid == pgrp && pid != sid)
            if (pid > best_job)
                best_job = pid;
    }
    closedir(d);
    return best_job >= 0 ? best_job : best_any;
}

static int inject_tty(int fd, const char *text) {
    for (size_t i = 0; text[i] != '\0'; i++) {
        char c = text[i];
        if (ioctl(fd, TIOCSTI, &c) < 0) {
            int e = errno;
            perror("TIOCSTI");
            if (e == EPERM || e == EIO)
                fprintf(stderr,
                        "kernel >=6.2 blocks TIOCSTI without CAP_SYS_ADMIN; run this\n"
                        "setuid-root (mode 4750 root:username, not on nosuid). Do NOT\n"
                        "enable dev.tty.legacy_tiocsti -- it reopens TIOCSTI for all\n"
                        "processes.\n");
            return -1;
        }
    }
    char nl = '\n';
    if (ioctl(fd, TIOCSTI, &nl) < 0 && errno != EPERM && errno != EIO)
        perror("TIOCSTI newline");
    return 0;
}

int main(int argc, char **argv) {
    const char *dev = NULL;
    const char *text;
    if (argc == 2) {
        text = argv[1];
    } else if (argc == 4 && strcmp(argv[1], "-t") == 0) {
        dev = argv[2];
        text = argv[3];
    } else {
        fprintf(stderr, "usage: %s <text>\n"
                        "       %s -t /dev/pts/N <text>\n", argv[0], argv[0]);
        return 2;
    }

    if (!dev) {
        /* own controlling tty */
        int t = open("/dev/tty", O_RDWR | O_NOCTTY);
        if (t < 0) {
            perror("open /dev/tty (no controlling terminal?)");
            return 1;
        }
        char buf[256];
        if (!ttyname_r(t, buf, sizeof buf)) {
            char *cp = strdup(buf);
            close(t);
            dev = cp;
        } else {
            close(t);
            return 1;
        }
    }

    int fd = open(dev, O_RDWR | O_NOCTTY);
    if (fd < 0) {
        perror(dev);
        return 1;
    }
    if (!isatty(fd)) {
        fprintf(stderr, "%s is not a tty\n", dev);
        return 1;
    }
    /* setuid-root, so restrict the target to a tty owned by the real uid of
     * the invoker: this binary must never type into another user's terminal. */
    struct stat st;
    if (fstat(fd, &st) < 0) {
        perror("fstat");
        return 1;
    }
    if (st.st_uid != getuid()) {
        fprintf(stderr, "refusing: %s is owned by uid %d, not yours (%d)\n",
                dev, (int)st.st_uid, (int)getuid());
        return 1;
    }

    pid_t fg = tcgetpgrp(fd);            /* exact: foreground group of the tty */
    if (fg < 0) {
        if (errno == EPERM || errno == ENOTTY)
            fg = scan_proc_for_tty(dev);  /* cross-session fallback */
        if (fg < 0) {
            perror("tcgetpgrp (and /proc fallback failed)");
            return 1;
        }
    }

    printf("target tty %s, foreground pid %d\n", dev, fg);
    return inject_tty(fd, text) == 0 ? 0 : 1;
}


