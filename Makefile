# APEX Top-Level Makefile

.PHONY: all allocator storage jit raft runtime clean

all: allocator storage jit raft runtime fallbacks

allocator:
	clang -shared -fPIC -std=c11 -O3 core/allocator/allocator.c -o core/allocator/libapex_allocator.so

storage:
	cd core/storage && cargo build --release

jit:
	cd core/jit && LLVM_SYS_140_PREFIX=/usr/local/opt/llvm@14 cargo build --release

raft:
	cd core/raft && go build ./...

runtime:
	cd core/runtime && npm install && npm run build

fallbacks:
	clang -shared -fPIC -O3 core/kernels/hotpath_fallback.c -o core/kernels/libhotpath_fallback.so
	clang++ -shared -fPIC -std=c++11 -O3 core/kernels/parallel_join_fallback.cpp -o core/kernels/libparallel_join_fallback.so
	clang -shared -fPIC -O3 core/fpga/fpga_mock.c -o core/fpga/libfpga_mock.so

clean:
	rm -f core/allocator/libapex_allocator.so
	cd core/jit && cargo clean
	rm -rf core/runtime/node_modules core/runtime/dist
	rm -f core/kernels/libhotpath_fallback.so core/kernels/libparallel_join_fallback.so core/fpga/libfpga_mock.so
