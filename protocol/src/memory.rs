//! Rust heap accounting with a last-resort allocation limit. This is neither
//! aggregate RSS containment nor graceful recovery from infallible OOM. OS,
//! driver, JNI/Java, and thread-stack allocations are outside these counters.
use std::{
    alloc::{GlobalAlloc, Layout},
    sync::atomic::{AtomicUsize, Ordering},
};

pub struct BudgetedAllocator<A> {
    inner: A,
    limit: usize,
    used: AtomicUsize,
    peak: AtomicUsize,
    rejected: AtomicUsize,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HeapMetrics {
    pub used: usize,
    pub peak: usize,
    pub limit: usize,
    pub rejected: usize,
}
impl<A> BudgetedAllocator<A> {
    pub const fn new(inner: A, limit: usize) -> Self {
        Self {
            inner,
            limit,
            used: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            rejected: AtomicUsize::new(0),
        }
    }
    pub fn metrics(&self) -> HeapMetrics {
        HeapMetrics {
            used: self.used.load(Ordering::Acquire),
            peak: self.peak.load(Ordering::Acquire),
            limit: self.limit,
            rejected: self.rejected.load(Ordering::Acquire),
        }
    }
    fn reserve(&self, size: usize) -> bool {
        let mut current = self.used.load(Ordering::Acquire);
        loop {
            let Some(next) = current.checked_add(size).filter(|next| *next <= self.limit) else {
                self.rejected.fetch_add(1, Ordering::Relaxed);
                return false;
            };
            match self.used.compare_exchange_weak(
                current,
                next,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => {
                    self.peak.fetch_max(next, Ordering::AcqRel);
                    return true;
                }
                Err(actual) => current = actual,
            }
        }
    }
    fn release(&self, size: usize) {
        self.used.fetch_sub(size, Ordering::AcqRel);
    }
}
// SAFETY: reservations only wrap the allocator contract. Every layout/pointer
// is forwarded unchanged and accounting never allocates, blocks, or logs.
unsafe impl<A: GlobalAlloc> GlobalAlloc for BudgetedAllocator<A> {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if !self.reserve(layout.size()) {
            return std::ptr::null_mut();
        }
        let ptr = unsafe { self.inner.alloc(layout) };
        if ptr.is_null() {
            self.release(layout.size())
        }
        ptr
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        if !self.reserve(layout.size()) {
            return std::ptr::null_mut();
        }
        let ptr = unsafe { self.inner.alloc_zeroed(layout) };
        if ptr.is_null() {
            self.release(layout.size())
        }
        ptr
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { self.inner.dealloc(ptr, layout) };
        self.release(layout.size());
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        // Account old+new transient storage, including shrink and failures;
        // reserving only the delta undercounts a moving realloc's peak.
        if !self.reserve(new_size) {
            return std::ptr::null_mut();
        }
        let result = unsafe { self.inner.realloc(ptr, layout, new_size) };
        if result.is_null() {
            self.release(new_size)
        } else {
            self.release(layout.size())
        }
        result
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::alloc::System;
    #[test]
    fn reservations_rollback_and_realloc_counts_transient_peak() {
        let a = BudgetedAllocator::new(System, 100);
        let layout = Layout::from_size_align(40, 16).unwrap();
        unsafe {
            let ptr = a.alloc_zeroed(layout);
            assert!(!ptr.is_null());
            assert_eq!(a.metrics().used, 40);
            assert!(a.realloc(ptr, layout, 70).is_null());
            assert_eq!(a.metrics().used, 40);
            let ptr = a.realloc(ptr, layout, 50);
            assert!(!ptr.is_null());
            assert_eq!(a.metrics().used, 50);
            assert_eq!(a.metrics().peak, 90);
            a.dealloc(ptr, Layout::from_size_align(50, 16).unwrap());
        }
        assert_eq!(a.metrics().used, 0);
        assert_eq!(a.metrics().rejected, 1);
    }
    #[test]
    fn failed_underlying_alloc_and_overflow_release_reservation() {
        struct Failing;
        unsafe impl GlobalAlloc for Failing {
            unsafe fn alloc(&self, _: Layout) -> *mut u8 {
                std::ptr::null_mut()
            }
            unsafe fn dealloc(&self, _: *mut u8, _: Layout) {}
        }
        let a = BudgetedAllocator::new(Failing, 100);
        unsafe {
            assert!(a.alloc(Layout::from_size_align(20, 1).unwrap()).is_null());
        }
        assert_eq!(a.metrics().used, 0);
        assert!(!a.reserve(usize::MAX));
        assert_eq!(a.metrics().used, 0);
    }
    #[test]
    fn concurrent_reservations_never_exceed_budget() {
        let a = std::sync::Arc::new(BudgetedAllocator::new(System, 100));
        let threads: Vec<_> = (0..8)
            .map(|_| {
                let a = a.clone();
                std::thread::spawn(move || {
                    for _ in 0..1000 {
                        if a.reserve(30) {
                            assert!(a.metrics().used <= 100);
                            a.release(30);
                        }
                    }
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        assert_eq!(a.metrics().used, 0);
        assert!(a.metrics().peak <= 100);
    }
}
