// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Nigel Shearman

/* Tiny uinput virtual mouse for driving the MiSTer Minimig core.
 *
 *   uinput_mouse create                 - create the device, hold it open (run in bg)
 *   uinput_mouse move  <dx> <dy>        - relative move
 *   uinput_mouse click <l|r>            - press+release a button
 *   uinput_mouse down  <l|r>  / up <l|r>
 *   uinput_mouse home                   - slam to top-left (many big -X/-Y moves)
 *
 * Uses a named fifo /tmp/uinput_mouse.ctl so one long-lived 'create' process
 * owns the device and short commands are piped to it.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <linux/uinput.h>

static int ufd = -1;

static void emit(int type, int code, int val)
{
    struct input_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = type; ev.code = code; ev.value = val;
    write(ufd, &ev, sizeof ev);
}
static void syn(void) { emit(EV_SYN, SYN_REPORT, 0); }

static void rel(int dx, int dy)
{
    if (dx) emit(EV_REL, REL_X, dx);
    if (dy) emit(EV_REL, REL_Y, dy);
    syn();
    usleep(4000);
}
static void btn(int right, int down)
{
    emit(EV_KEY, right ? BTN_RIGHT : BTN_LEFT, down);
    syn();
    usleep(20000);
}

static int setup_device(void)
{
    ufd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (ufd < 0) { perror("open /dev/uinput"); return -1; }

    ioctl(ufd, UI_SET_EVBIT, EV_KEY);
    ioctl(ufd, UI_SET_KEYBIT, BTN_LEFT);
    ioctl(ufd, UI_SET_KEYBIT, BTN_RIGHT);
    ioctl(ufd, UI_SET_KEYBIT, BTN_MIDDLE);
    ioctl(ufd, UI_SET_EVBIT, EV_REL);
    ioctl(ufd, UI_SET_RELBIT, REL_X);
    ioctl(ufd, UI_SET_RELBIT, REL_Y);
    ioctl(ufd, UI_SET_RELBIT, REL_WHEEL);

    struct uinput_setup us;
    memset(&us, 0, sizeof us);
    us.id.bustype = BUS_USB;
    us.id.vendor  = 0x1234;
    us.id.product = 0x5679;
    strcpy(us.name, "MiSTer Virtual Mouse");
    if (ioctl(ufd, UI_DEV_SETUP, &us) < 0) {
        /* old kernel fallback */
        struct uinput_user_dev uud;
        memset(&uud, 0, sizeof uud);
        strncpy(uud.name, us.name, UINPUT_MAX_NAME_SIZE);
        uud.id.bustype = BUS_USB; uud.id.vendor = 0x1234; uud.id.product = 0x5679;
        write(ufd, &uud, sizeof uud);
    }
    if (ioctl(ufd, UI_DEV_CREATE) < 0) { perror("UI_DEV_CREATE"); return -1; }
    return 0;
}

static void do_cmd(char *line)
{
    char *a = strtok(line, " \t\n");
    if (!a) return;
    if (!strcmp(a, "move")) {
        int dx = atoi(strtok(NULL, " \t\n") ?: "0");
        int dy = atoi(strtok(NULL, " \t\n") ?: "0");
        /* break big moves into steps so the core tracks them */
        while (dx || dy) {
            int sx = dx >  20 ?  20 : dx < -20 ? -20 : dx;
            int sy = dy >  20 ?  20 : dy < -20 ? -20 : dy;
            rel(sx, sy);
            dx -= sx; dy -= sy;
        }
    } else if (!strcmp(a, "home")) {
        for (int i = 0; i < 60; i++) rel(-40, -40);
    } else if (!strcmp(a, "click")) {
        char *b = strtok(NULL, " \t\n");
        int r = b && (*b == 'r' || *b == 'R');
        btn(r, 1); usleep(40000); btn(r, 0);
    } else if (!strcmp(a, "down")) {
        char *b = strtok(NULL, " \t\n"); btn(b && *b=='r', 1);
    } else if (!strcmp(a, "up")) {
        char *b = strtok(NULL, " \t\n"); btn(b && *b=='r', 0);
    } else if (!strcmp(a, "quit")) {
        ioctl(ufd, UI_DEV_DESTROY);
        exit(0);
    }
}

int main(int argc, char **argv)
{
    const char *fifo = "/tmp/uinput_mouse.ctl";

    if (argc >= 2 && !strcmp(argv[1], "create")) {
        if (setup_device() < 0) return 1;
        unlink(fifo);
        if (mkfifo(fifo, 0666) < 0 && errno != EEXIST) { perror("mkfifo"); return 1; }
        fprintf(stderr, "uinput mouse up; piping %s\n", fifo);
        for (;;) {
            FILE *f = fopen(fifo, "r");
            if (!f) { usleep(100000); continue; }
            char buf[256];
            while (fgets(buf, sizeof buf, f)) do_cmd(buf);
            fclose(f);
        }
    }

    /* one-shot: open device fresh, do the command, exit (device vanishes -
       only useful if a 'create' server isn't running; prefer the fifo) */
    if (argc >= 2) {
        int fd = open(fifo, O_WRONLY | O_NONBLOCK);
        if (fd >= 0) {
            char line[256]; int n = 0;
            for (int i = 1; i < argc; i++)
                n += snprintf(line + n, sizeof line - n, "%s ", argv[i]);
            n += snprintf(line + n, sizeof line - n, "\n");
            write(fd, line, n);
            close(fd);
            return 0;
        }
        fprintf(stderr, "no fifo server; run '%s create &' first\n", argv[0]);
        return 1;
    }
    fprintf(stderr, "usage: %s create | move dx dy | click l|r | home | quit\n", argv[0]);
    return 1;
}
