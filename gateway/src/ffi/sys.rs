//! The few system calls the standard library does not expose, declared by hand (std already links libc): epoll, eventfd, signalfd, sigprocmask.
//! Everything here is wrapped in a small safe API; the `unsafe` blocks state the invariants they rely on.

use std::io;
use std::os::raw::{c_int, c_uint, c_void};

pub type RawFd = c_int;

pub const EPOLL_CLOEXEC: c_int = 0o2_000_000;
pub const EPOLL_CTL_ADD: c_int = 1;
pub const EPOLL_CTL_DEL: c_int = 2;
pub const EPOLL_CTL_MOD: c_int = 3;
pub const EPOLLIN: u32 = 0x001;
pub const EPOLLOUT: u32 = 0x004;
pub const EPOLLERR: u32 = 0x008;
pub const EPOLLHUP: u32 = 0x010;
pub const EPOLLRDHUP: u32 = 0x2000;
const EFD_NONBLOCK: c_int = 0o4_000;
const EFD_CLOEXEC: c_int = 0o2_000_000;
const SFD_NONBLOCK: c_int = 0o4_000;
const SFD_CLOEXEC: c_int = 0o2_000_000;
const SIG_BLOCK: c_int = 0;
pub const SIGINT: c_int = 2;
pub const SIGTERM: c_int = 15;

/// `struct epoll_event`: packed on x86-64 (the kernel ABI), naturally aligned elsewhere.
#[cfg_attr(target_arch = "x86_64", repr(C, packed))]
#[cfg_attr(not(target_arch = "x86_64"), repr(C))]
#[derive(Clone, Copy)]
pub struct EpollEvent {
    pub events: u32,
    pub data: u64,
}

/// `sigset_t` is 128 bytes on Linux (glibc and musl).
#[repr(C)]
pub struct SigSet {
    _bits: [u64; 16],
}

extern "C" {
    fn epoll_create1(flags: c_int) -> c_int;
    fn epoll_ctl(epfd: c_int, op: c_int, fd: c_int, ev: *mut EpollEvent) -> c_int;
    fn epoll_wait(epfd: c_int, events: *mut EpollEvent, maxevents: c_int, timeout: c_int) -> c_int;
    fn eventfd(initval: c_uint, flags: c_int) -> c_int;
    fn read(fd: c_int, buf: *mut c_void, count: usize) -> isize;
    fn write(fd: c_int, buf: *const c_void, count: usize) -> isize;
    fn close(fd: c_int) -> c_int;
    fn sigemptyset(set: *mut SigSet) -> c_int;
    fn sigaddset(set: *mut SigSet, signum: c_int) -> c_int;
    fn pthread_sigmask(how: c_int, set: *const SigSet, old: *mut SigSet) -> c_int;
    fn signalfd(fd: c_int, mask: *const SigSet, flags: c_int) -> c_int;
}

fn cvt(r: c_int) -> io::Result<c_int> {
    if r < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(r)
    }
}

/// An epoll instance.  `key` is an opaque 64-bit value returned with each event.
pub struct Epoll {
    fd: RawFd,
}

impl Epoll {
    pub fn new() -> io::Result<Epoll> {
        // SAFETY: plain syscall without pointers; the result is checked.
        let fd = cvt(unsafe { epoll_create1(EPOLL_CLOEXEC) })?;
        Ok(Epoll { fd })
    }
    fn ctl(&self, op: c_int, fd: RawFd, events: u32, key: u64) -> io::Result<()> {
        let mut ev = EpollEvent { events, data: key };
        // SAFETY: `ev` is a valid, initialised epoll_event that lives for the call; the kernel copies it.
        cvt(unsafe { epoll_ctl(self.fd, op, fd, &mut ev) }).map(|_| ())
    }
    pub fn add(&self, fd: RawFd, events: u32, key: u64) -> io::Result<()> {
        self.ctl(EPOLL_CTL_ADD, fd, events, key)
    }
    pub fn modify(&self, fd: RawFd, events: u32, key: u64) -> io::Result<()> {
        self.ctl(EPOLL_CTL_MOD, fd, events, key)
    }
    pub fn delete(&self, fd: RawFd) -> io::Result<()> {
        self.ctl(EPOLL_CTL_DEL, fd, 0, 0)
    }
    /// Waits up to `timeout_ms` (-1 = forever).  Fills `out` (cleared first) with at most `out.capacity()` events.
    pub fn wait(&self, out: &mut Vec<EpollEvent>, timeout_ms: i32) -> io::Result<usize> {
        out.clear();
        let cap = out.capacity().max(1).min(i32::MAX as usize);
        if out.capacity() < cap {
            out.reserve(cap);
        }
        // SAFETY: the buffer has room for `cap` events (reserved above); the kernel writes at most `cap` and returns how many; we set the length to that count.
        let n = unsafe { epoll_wait(self.fd, out.as_mut_ptr(), cap as c_int, timeout_ms) };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                return Ok(0);
            }
            return Err(e);
        }
        unsafe { out.set_len(n as usize) };
        Ok(n as usize)
    }
}

impl Drop for Epoll {
    fn drop(&mut self) {
        // SAFETY: we own the descriptor.
        unsafe { close(self.fd) };
    }
}

/// An eventfd used to wake the loop from worker threads.
pub struct EventFd {
    fd: RawFd,
}

impl EventFd {
    pub fn new() -> io::Result<EventFd> {
        // SAFETY: plain syscall; the result is checked.
        let fd = cvt(unsafe { eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC) })?;
        Ok(EventFd { fd })
    }
    pub fn fd(&self) -> RawFd {
        self.fd
    }
    /// Adds 1 to the counter (wakes a waiter).  Safe to call from any thread.
    pub fn notify(&self) {
        let one: u64 = 1;
        // SAFETY: writes exactly 8 bytes from a valid u64; the eventfd is non-blocking so this cannot hang; a failed write (counter at its limit) only means a wake-up is already pending.
        unsafe { write(self.fd, &one as *const u64 as *const c_void, 8) };
    }
    /// Resets the counter.
    pub fn drain(&self) {
        let mut v: u64 = 0;
        // SAFETY: reads exactly 8 bytes into a valid u64; non-blocking (EAGAIN when the counter is 0 is fine).
        unsafe { read(self.fd, &mut v as *mut u64 as *mut c_void, 8) };
    }
}

impl Drop for EventFd {
    fn drop(&mut self) {
        // SAFETY: we own the descriptor.
        unsafe { close(self.fd) };
    }
}

// An EventFd is only a file descriptor number; `notify` is a single write(2), which the kernel serialises.
unsafe impl Send for EventFd {}
unsafe impl Sync for EventFd {}

/// Blocks SIGINT and SIGTERM in the calling thread (call BEFORE spawning threads so that they inherit the mask) and returns a non-blocking signalfd for them.
pub fn block_and_open_signals() -> io::Result<RawFd> {
    let mut set = SigSet { _bits: [0; 16] };
    // SAFETY: `set` is a valid, writable sigset_t-sized buffer for every call below; the arguments are valid signal numbers.
    unsafe {
        cvt(sigemptyset(&mut set))?;
        cvt(sigaddset(&mut set, SIGINT))?;
        cvt(sigaddset(&mut set, SIGTERM))?;
        let r = pthread_sigmask(SIG_BLOCK, &set, std::ptr::null_mut());
        if r != 0 {
            return Err(io::Error::from_raw_os_error(r));
        }
        cvt(signalfd(-1, &set, SFD_NONBLOCK | SFD_CLOEXEC))
    }
}

/// Reads and discards pending signal records; returns true if at least one was read.
pub fn drain_signalfd(fd: RawFd) -> bool {
    let mut buf = [0u8; 128]; // struct signalfd_siginfo is 128 bytes
    let mut got = false;
    loop {
        // SAFETY: reads at most 128 bytes into a valid 128-byte buffer.
        let n = unsafe { read(fd, buf.as_mut_ptr() as *mut c_void, buf.len()) };
        if n <= 0 {
            return got;
        }
        got = true;
    }
}
