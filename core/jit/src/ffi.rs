use std::os::raw::{c_void, c_double, c_int};

#[repr(C)]
pub struct JoinTuple {
    pub key: i64,
    pub payload: i64,
}

#[repr(C)]
pub struct DescriptorT {
    pub host_addr: u64,
    pub hbm_addr: u64,
    pub length: u32,
    pub dir: u32,
    pub interrupt_on_complete: u32,
    pub _pad: u32,
}

#[link(name = "apex_allocator")]
extern "C" {
    pub fn apex_init();
    pub fn apex_alloc(size: usize) -> *mut c_void;
    pub fn apex_free(ptr: *mut c_void, size: usize);
}

#[link(name = "hotpath_fallback")]
extern "C" {
    pub fn apex_aggregate_f64_fallback(
        data: *const c_double,
        n: usize,
        out_sum: *mut c_double,
        out_min: *mut c_double,
        out_max: *mut c_double,
    );
}

#[link(name = "parallel_join_fallback")]
extern "C" {
    pub fn apex_hash_join_fallback(
        probe_input: *const JoinTuple,
        probe_sz: usize,
        build_input: *const JoinTuple,
        build_sz: usize,
        output: *mut JoinTuple,
        output_count: *mut u32,
    );
}

#[link(name = "fpga_mock")]
extern "C" {
    pub fn apex_fpga_dma_mock(desc: *mut DescriptorT);
}
