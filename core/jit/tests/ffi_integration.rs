#[cfg(test)]
mod tests {
    use apex_jit::ffi::*;

    #[test]
    fn test_ffi_allocator() {
        unsafe {
            apex_init();
            let ptr = apex_alloc(1024);
            assert!(!ptr.is_null());
            apex_free(ptr, 1024);
        }
    }

    #[test]
    fn test_ffi_hotpath() {
        let data = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let mut sum = 0.0;
        let mut min = 0.0;
        let mut max = 0.0;

        unsafe {
            apex_aggregate_f64_fallback(
                data.as_ptr(),
                data.len(),
                &mut sum,
                &mut min,
                &mut max,
            );
        }

        assert_eq!(sum, 15.0);
        assert_eq!(min, 1.0);
        assert_eq!(max, 5.0);
    }
}
