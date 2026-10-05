// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Nigel Shearman

/* Tiny uinput virtual keyboard for driving the MiSTer Minimig core.
 *
 *   uinput_kbd create               - create device, own it, read fifo (run bg)
 *   uinput_kbd type "text"          - type an ASCII string
 *   uinput_kbd key KEY_X [KEY_Y..]  - tap raw KEY_* names (chord if >1)
 *   uinput_kbd enter                - tap ENTER
 *   uinput_kbd quit
 *
 * fifo: /tmp/uinput_kbd.ctl
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <ctype.h>
#include <sys/stat.h>
#include <linux/uinput.h>

static int ufd = -1;

static void emit(int type, int code, int val)
{
    struct input_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = type; ev.code = code; ev.value = val;
    write(ufd, &ev, sizeof ev);
}
static void syn(void){ emit(EV_SYN, SYN_REPORT, 0); }

static void tap(int code)
{
    emit(EV_KEY, code, 1); syn(); usleep(25000);
    emit(EV_KEY, code, 0); syn(); usleep(40000);
}
static void chord(int mod, int code)
{
    emit(EV_KEY, mod, 1); syn(); usleep(20000);
    emit(EV_KEY, code, 1); syn(); usleep(25000);
    emit(EV_KEY, code, 0); syn(); usleep(20000);
    emit(EV_KEY, mod, 0); syn(); usleep(40000);
}

/* ascii -> (shift, KEY_ code) */
struct map { char c; int shift; int code; };
static int ascii_key(char c, int *shift)
{
    *shift = 0;
    if (c >= 'a' && c <= 'z') { static const int t[] = {
        KEY_A,KEY_B,KEY_C,KEY_D,KEY_E,KEY_F,KEY_G,KEY_H,KEY_I,KEY_J,KEY_K,KEY_L,KEY_M,
        KEY_N,KEY_O,KEY_P,KEY_Q,KEY_R,KEY_S,KEY_T,KEY_U,KEY_V,KEY_W,KEY_X,KEY_Y,KEY_Z};
        return t[c-'a']; }
    if (c >= 'A' && c <= 'Z') { *shift = 1; static const int t[] = {
        KEY_A,KEY_B,KEY_C,KEY_D,KEY_E,KEY_F,KEY_G,KEY_H,KEY_I,KEY_J,KEY_K,KEY_L,KEY_M,
        KEY_N,KEY_O,KEY_P,KEY_Q,KEY_R,KEY_S,KEY_T,KEY_U,KEY_V,KEY_W,KEY_X,KEY_Y,KEY_Z};
        return t[c-'A']; }
    if (c >= '1' && c <= '9') { static const int t[]={KEY_1,KEY_2,KEY_3,KEY_4,KEY_5,KEY_6,KEY_7,KEY_8,KEY_9}; return t[c-'1']; }
    switch (c) {
        case '0': return KEY_0;
        case ' ': return KEY_SPACE;
        case '\n': return KEY_ENTER;
        case '.': return KEY_DOT;
        case ',': return KEY_COMMA;
        case '/': return KEY_SLASH;
        case '-': return KEY_MINUS;
        case '=': return KEY_EQUAL;
        case ';': return KEY_SEMICOLON;
        case '\'': return KEY_APOSTROPHE;
        case ':': *shift=1; return KEY_SEMICOLON;
        case '"': *shift=1; return KEY_APOSTROPHE;
        case '?': *shift=1; return KEY_SLASH;
        case '>': *shift=1; return KEY_DOT;
        case '<': *shift=1; return KEY_COMMA;
        case '_': *shift=1; return KEY_MINUS;
        case '(': *shift=1; return KEY_9;
        case ')': *shift=1; return KEY_0;
        case '*': *shift=1; return KEY_8;
        case '!': *shift=1; return KEY_1;
    }
    return 0;
}

static void type_str(const char *s)
{
    for (; *s; s++) {
        int sh, k = ascii_key(*s, &sh);
        if (!k) continue;
        if (sh) { emit(EV_KEY, KEY_LEFTSHIFT, 1); syn(); usleep(15000); }
        emit(EV_KEY, k, 1); syn(); usleep(20000);
        emit(EV_KEY, k, 0); syn(); usleep(20000);
        if (sh) { emit(EV_KEY, KEY_LEFTSHIFT, 0); syn(); usleep(15000); }
        usleep(30000);
    }
}

static int keyname(const char *n)
{
    struct { const char *n; int c; } t[] = {
        {"KEY_ENTER",KEY_ENTER},{"KEY_ESC",KEY_ESC},{"KEY_SPACE",KEY_SPACE},
        {"KEY_LEFTMETA",KEY_LEFTMETA},{"KEY_RIGHTMETA",KEY_RIGHTMETA},
        {"KEY_LEFTCTRL",KEY_LEFTCTRL},{"KEY_LEFTALT",KEY_LEFTALT},
        {"KEY_RIGHTALT",KEY_RIGHTALT},{"KEY_LEFTSHIFT",KEY_LEFTSHIFT},
        {"KEY_E",KEY_E},{"KEY_BACKSPACE",KEY_BACKSPACE},{"KEY_TAB",KEY_TAB},
        {"KEY_UP",KEY_UP},{"KEY_DOWN",KEY_DOWN},{"KEY_LEFT",KEY_LEFT},{"KEY_RIGHT",KEY_RIGHT},
        {"KEY_F1",KEY_F1},{"KEY_DELETE",KEY_DELETE},{0,0}};
    for (int i=0;t[i].n;i++) if (!strcmp(t[i].n,n)) return t[i].c;
    return 0;
}

static void setup(void)
{
    ufd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (ufd < 0) { perror("open /dev/uinput"); exit(1); }
    ioctl(ufd, UI_SET_EVBIT, EV_KEY);
    for (int k = 1; k < 128; k++) ioctl(ufd, UI_SET_KEYBIT, k);
    ioctl(ufd, UI_SET_KEYBIT, KEY_LEFTMETA);
    ioctl(ufd, UI_SET_KEYBIT, KEY_RIGHTMETA);
    struct uinput_setup us;
    memset(&us, 0, sizeof us);
    us.id.bustype = BUS_USB; us.id.vendor = 0x1234; us.id.product = 0x6001;
    strcpy(us.name, "MiSTer Virtual Keyboard");
    if (ioctl(ufd, UI_DEV_SETUP, &us) < 0) {
        struct uinput_user_dev uud;
        memset(&uud, 0, sizeof uud);
        strncpy(uud.name, us.name, UINPUT_MAX_NAME_SIZE);
        uud.id.bustype = BUS_USB; uud.id.vendor = 0x1234; uud.id.product = 0x6001;
        write(ufd, &uud, sizeof uud);
    }
    if (ioctl(ufd, UI_DEV_CREATE) < 0) { perror("UI_DEV_CREATE"); exit(1); }
}

static void do_cmd(char *line)
{
    char *a = strtok(line, " \t\n");
    if (!a) return;
    if (!strcmp(a, "type")) {
        char *rest = strtok(NULL, "\n");
        if (rest) type_str(rest);
    } else if (!strcmp(a, "enter")) {
        tap(KEY_ENTER);
    } else if (!strcmp(a, "key")) {
        int codes[6], n = 0; char *k;
        while (n < 6 && (k = strtok(NULL, " \t\n"))) { int c = keyname(k); if (c) codes[n++] = c; }
        if (n == 1) tap(codes[0]);
        else if (n == 2) chord(codes[0], codes[1]);
        else for (int i=0;i<n;i++) tap(codes[i]);
    } else if (!strcmp(a, "quit")) {
        ioctl(ufd, UI_DEV_DESTROY); exit(0);
    }
}

int main(int argc, char **argv)
{
    const char *fifo = "/tmp/uinput_kbd.ctl";
    if (argc >= 2 && !strcmp(argv[1], "create")) {
        setup();
        unlink(fifo);
        if (mkfifo(fifo, 0666) < 0 && errno != EEXIST) { perror("mkfifo"); return 1; }
        fprintf(stderr, "uinput kbd up; pipe %s\n", fifo);
        for (;;) {
            FILE *f = fopen(fifo, "r");
            if (!f) { usleep(100000); continue; }
            char buf[512];
            while (fgets(buf, sizeof buf, f)) do_cmd(buf);
            fclose(f);
        }
    }
    if (argc >= 2) {
        int fd = open(fifo, O_WRONLY | O_NONBLOCK);
        if (fd < 0) { fprintf(stderr, "no fifo server\n"); return 1; }
        char line[512]; int n = 0;
        for (int i = 1; i < argc; i++) n += snprintf(line+n, sizeof line-n, "%s ", argv[i]);
        snprintf(line+n, sizeof line-n, "\n");
        write(fd, line, strlen(line));
        close(fd);
        return 0;
    }
    fprintf(stderr, "usage: create | type <s> | key KEY_x [KEY_y] | enter | quit\n");
    return 1;
}
