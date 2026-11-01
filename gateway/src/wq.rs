//! The bytes queued for one socket and not yet written, with the backpressure cap: a client that cannot keep up is disconnected instead of letting the queue grow
//! without bound (vanilla does the same).  Chunks are kept as they arrive (no copying into one big buffer); `front()` is the unwritten part of the first chunk.

use std::collections::VecDeque;

pub struct WriteQueue {
    chunks: VecDeque<Vec<u8>>,
    off: usize,
    bytes: usize,
}

impl WriteQueue {
    pub fn new() -> WriteQueue {
        WriteQueue { chunks: VecDeque::new(), off: 0, bytes: 0 }
    }
    /// Queues `data` (empty data is ignored).  Returns the number of bytes now pending.
    pub fn push(&mut self, data: Vec<u8>) -> usize {
        if !data.is_empty() {
            self.bytes += data.len();
            self.chunks.push_back(data);
        }
        self.bytes
    }
    #[cfg(test)]
    pub fn pending(&self) -> usize {
        self.bytes
    }
    pub fn is_empty(&self) -> bool {
        self.bytes == 0
    }
    /// The next bytes to write (the unwritten rest of the first chunk), or an empty slice.
    pub fn front(&self) -> &[u8] {
        match self.chunks.front() {
            Some(c) => &c[self.off..],
            None => &[],
        }
    }
    /// `n` bytes of `front()` were written.
    pub fn consume(&mut self, n: usize) {
        let mut n = n.min(self.bytes);
        self.bytes -= n;
        while n > 0 {
            let first_left = self.chunks.front().map_or(0, |c| c.len() - self.off);
            if n >= first_left {
                n -= first_left;
                self.chunks.pop_front();
                self.off = 0;
            } else {
                self.off += n;
                n = 0;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_in_order_across_chunks_and_partial_writes() {
        let mut q = WriteQueue::new();
        q.push(vec![1, 2, 3]);
        q.push(vec![]);
        q.push(vec![4, 5]);
        assert_eq!(q.pending(), 5);
        assert_eq!(q.front(), &[1, 2, 3]);
        q.consume(2);
        assert_eq!(q.front(), &[3]);
        assert_eq!(q.pending(), 3);
        q.consume(1);
        assert_eq!(q.front(), &[4, 5]);
        q.consume(2);
        assert!(q.is_empty());
        assert_eq!(q.front(), &[] as &[u8]);
    }

    #[test]
    fn consuming_more_than_pending_is_harmless() {
        let mut q = WriteQueue::new();
        q.push(vec![9; 10]);
        q.consume(1000);
        assert!(q.is_empty());
        q.push(vec![1]);
        assert_eq!(q.front(), &[1]);
    }

    #[test]
    fn pending_bytes_drive_the_backpressure_decision() {
        let cap = 1000;
        let mut q = WriteQueue::new();
        let mut dropped = false;
        for _ in 0..50 {
            if q.push(vec![0; 100]) > cap {
                dropped = true;
                break;
            }
        }
        assert!(dropped, "a client that never reads exceeds the cap");
        assert!(q.pending() <= cap + 100, "and the queue stopped growing right after the cap");
    }
}
