#include <stdint.h>
#include <string.h>

typedef struct {
    uint64_t host_addr;
    uint64_t hbm_addr;
    uint32_t length;
    uint32_t dir; // 0=H2D, 1=D2H
    uint32_t interrupt_on_complete;
    uint32_t _pad;
} descriptor_t;

void apex_fpga_dma_mock(descriptor_t* desc) {
    if (!desc) return;
    void* host_ptr = (void*)(uintptr_t)desc->host_addr;
    void* fpga_ptr = (void*)(uintptr_t)desc->hbm_addr;
    
    if (desc->dir == 0) { // Host to Device
        memcpy(fpga_ptr, host_ptr, desc->length);
    } else if (desc->dir == 1) { // Device to Host
        memcpy(host_ptr, fpga_ptr, desc->length);
    }
}
