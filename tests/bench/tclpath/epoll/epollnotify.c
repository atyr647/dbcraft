/* A single-threaded epoll notifier for Tcl 8.6, installed through the documented Tcl_SetNotifier() embedding hook: no change to Tcl.
 * Tcl 8.6's own Unix notifier uses select(), which aborts the process on any file descriptor >= FD_SETSIZE (1024).
 * Level-triggered, one epoll set, an eventfd for Tcl_AlertNotifier.  Install before Tcl_Main.  Not for use with Tcl threads. */
#include <tcl.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

typedef struct Fh { int fd, mask, ready, queued, gen; Tcl_FileProc *proc; ClientData cd; } Fh;
typedef struct { Tcl_Event ev; int fd, gen; } FEvent;
static struct { int ep, wake, cap, n, gen; Fh **tab; } S = { -1, -1, 0, 0, 0, NULL };

static unsigned toep(int m) { return ((m & TCL_READABLE) ? EPOLLIN : 0) | ((m & TCL_WRITABLE) ? EPOLLOUT : 0) | ((m & TCL_EXCEPTION) ? EPOLLPRI : 0); }

static ClientData InitProc(void) {
    if (S.ep < 0) {
        struct epoll_event e = { EPOLLIN, { .fd = -1 } };
        S.ep = epoll_create1(EPOLL_CLOEXEC); S.wake = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
        epoll_ctl(S.ep, EPOLL_CTL_ADD, S.wake, &e);
    }
    return (ClientData) &S;
}
static void FinalizeProc(ClientData cd) { (void) cd; }
static void AlertProc(ClientData cd) { unsigned long long one = 1; (void) cd; if (S.wake >= 0 && write(S.wake, &one, 8) < 0) { /* full: already pending */ } }
static void SetTimerProc(const Tcl_Time *t) { (void) t; }
static void ServiceModeProc(int mode) { (void) mode; }

static void CreateFh(int fd, int mask, Tcl_FileProc *proc, ClientData cd) {
    struct epoll_event e; Fh *f;
    if (fd >= S.cap) { int nc = fd + 1024; S.tab = realloc(S.tab, nc * sizeof(Fh *)); memset(S.tab + S.cap, 0, (nc - S.cap) * sizeof(Fh *)); S.cap = nc; }
    f = S.tab[fd]; e.data.fd = fd; e.events = toep(mask);
    if (!f) { f = calloc(1, sizeof(Fh)); f->fd = fd; f->gen = ++S.gen; S.tab[fd] = f; S.n++; f->mask = mask; epoll_ctl(S.ep, EPOLL_CTL_ADD, fd, &e); }
    else if (f->mask != mask) epoll_ctl(S.ep, EPOLL_CTL_MOD, fd, &e);
    f->mask = mask; f->proc = proc; f->cd = cd;
}
static void DeleteFh(int fd) {
    Fh *f; if (fd < 0 || fd >= S.cap || !(f = S.tab[fd])) return;
    epoll_ctl(S.ep, EPOLL_CTL_DEL, fd, NULL); S.tab[fd] = NULL; S.n--; free(f);
}
static int FEventProc(Tcl_Event *evp, int flags) {
    FEvent *fe = (FEvent *) evp; Fh *f; int m;
    if (!(flags & TCL_FILE_EVENTS)) return 0;
    f = fe->fd < S.cap ? S.tab[fe->fd] : NULL;
    if (f && f->gen == fe->gen) { m = f->ready & f->mask; f->ready = 0; f->queued = 0; if (m) f->proc(f->cd, m); }
    return 1;
}
static int WaitProc(const Tcl_Time *t) {
    struct epoll_event ev[1024]; int ms = -1, n, i;
    if (t) { long long v = (long long) t->sec * 1000 + (t->usec + 999) / 1000; ms = v > 0x7fffffff ? 0x7fffffff : (int) v; }
    else if (S.n == 0) return -1;                       /* nothing could ever wake us: same rule as the select notifier */
    n = epoll_wait(S.ep, ev, 1024, ms);
    for (i = 0; i < n; i++) {
        int fd = ev[i].data.fd, m = 0; Fh *f;
        if (fd < 0) { unsigned long long x; if (read(S.wake, &x, 8) < 0) {} continue; }
        f = fd < S.cap ? S.tab[fd] : NULL; if (!f) continue;
        if (ev[i].events & (EPOLLIN | EPOLLHUP | EPOLLERR)) m |= TCL_READABLE;
        if (ev[i].events & (EPOLLOUT | EPOLLERR)) m |= TCL_WRITABLE;
        if (ev[i].events & EPOLLPRI) m |= TCL_EXCEPTION;
        m &= f->mask | ((f->mask & TCL_READABLE) ? 0 : 0);
        if (!m) continue;
        f->ready |= m;
        if (!f->queued) { FEvent *fe = (FEvent *) ckalloc(sizeof(FEvent)); fe->ev.proc = FEventProc; fe->fd = fd; fe->gen = f->gen; f->queued = 1; Tcl_QueueEvent(&fe->ev, TCL_QUEUE_TAIL); }
    }
    return 0;
}
void EpollNotifier_Install(void) {
    Tcl_NotifierProcs p; memset(&p, 0, sizeof p);
    p.setTimerProc = SetTimerProc; p.waitForEventProc = WaitProc; p.createFileHandlerProc = CreateFh; p.deleteFileHandlerProc = DeleteFh;
    p.initNotifierProc = InitProc; p.finalizeNotifierProc = FinalizeProc; p.alertNotifierProc = AlertProc; p.serviceModeHookProc = ServiceModeProc;
    Tcl_SetNotifier(&p);
}
