# APEX 🚀 (Adaptive Polyglot Execution Engine)

**APEX** is a next-generation, high-performance Lakehouse query execution engine. Built as a proof-of-concept for extreme hardware utilization, APEX bypasses the bloated storage layers of traditional relational databases, executing arbitrary SQL queries via in-memory vectorization.

Designed entirely from scratch, APEX is a true **Polyglot Architecture**, combining the unique strengths of 8 programming languages and bridging the gap between high-level distributed consensus, advanced functional query optimization, and bare-metal memory execution.

---

## ⚡ The Lakehouse Execution CLI

APEX ships with a production-ready **Interactive REPL**. Instead of relying on slow, physical `.ibd` disk reads or duplicating 50 million rows into CSV files, the APEX CLI connects to your existing MySQL or PostgreSQL database, streams the data dynamically into RAM, and executes your queries using an advanced in-memory vectorized query engine.

### Quick Start

```bash
# Compile the APEX Interactive Terminal
cd cmd/apex
go build -o apex

# Launch the Engine
./apex
```

Once inside the REPL, simply provide your database credentials or a raw connection string (e.g., `mysql://root:pass@localhost:3306/db`), and you will be dropped into the `APEX SQL >` prompt to execute your queries at hardware speed.

### Example Session

```text
    ___    ____  ______ __  __
   /   |  / __ \/ ____/ \ \/ /
  / /| | / /_/ / ____/   \  /
 / ___ |/ ____/ /___     /  \
/_/  |_/_/   /_____/    /_/\_\

The Polyglot Query Execution Engine
v0.1.0-alpha (In-Memory Lakehouse Edition)

Select Connection Method:
1. Standard Configuration
> 1
Database Name: school_manager

[APEX] Connecting to MYSQL database... Success!

---------------------------------------------------
APEX SQL > SELECT schools.board, AVG(marks.score) as avg_math_score FROM marks JOIN enrollments ON marks.enrollment_id = enrollments.id JOIN students ON enrollments.student_id = students.id JOIN classrooms ON enrollments.classroom_id = classrooms.id JOIN teacher_subject_assignments ON classrooms.id = teacher_subject_assignments.classroom_id JOIN subjects ON teacher_subject_assignments.subject_id = subjects.id JOIN schools ON students.school_id = schools.id WHERE subjects.name = 'English' AND classrooms.grade = '5' GROUP BY schools.board;
board       |avg_math_score
2           |49.994828
0           |49.981448
1           |50.001766
3           |49.994108

[4 rows in set (91.373 sec)]
```

---

## 🏗️ Polyglot Architecture & Subsystems

APEX is divided into discrete, highly specialized modules. The system uses **Zero-Cost FFI (`extern "C"`)** for tight hardware linkage and **gRPC/Protobuf** for loose distributed coordination.

1. **Go (`cmd/apex` & `core/raft`)**
   - **CLI Engine**: The interactive REPL and universal RDBMS streaming adapter.
   - **Consensus**: Distributed coordination and state replication using the Raft algorithm.
2. **Rust (`core/jit` & `core/storage`)**
   - **Execution Engine**: Powered by Apache Arrow / DataFusion, parsing and executing queries using AVX-512 hardware vectorization across all CPU cores.
   - **Storage Engine**: Experimental logic capable of navigating raw B-Tree binary structures and decoding proprietary `InnoDB COMPACT` row formats.
3. **Haskell (`core/optimizer`)**
   - **Query Optimizer**: A Cascades-style top-down optimizer with memoization and advanced algebraic cardinality estimation.
4. **C (`core/allocator`)**
   - **Memory Management**: A lock-free, NUMA-aware, ABA-safe slab allocator using epoch-based reclamation for zero-copy data buffering.
5. **Hardware Kernels (`core/kernels` & `core/fpga`)**
   - **CUDA / ASM / SystemVerilog**: Specialized hardware routines (partitioned warp-cooperative hash joins, DMA scatter-gather engines) designed for immense parallel acceleration.

---

## 🛠️ Build Requirements

Because APEX leverages a true polyglot stack, compiling the entire repository from source requires several toolchains:

- **Go**: `1.21+` (Required for the CLI and Raft Coordinator)
- **Rust & Cargo**: `rustup default stable` (Required for the Execution Engine)
- **Clang / GCC**: (Required for the C Allocator and Hardware Kernels)
- **Haskell**: `ghc` and `cabal-install` (Required for the Optimizer)
- **Node.js**: `v18+` (Required for WebAssembly Runtimes)
- **LLVM 14**: (Required by the Rust JIT to link `llvm-sys`)

### Compiling the Ecosystem

The repository is fully orchestrated via a top-level `Makefile`. To build the internal libraries and cross-boundary FFI tests:

```bash
# Build the entire stack
make all

# Or build individual subsystems
make allocator
make jit
make raft
make optimizer
```

---

## 🧪 Development & Testing

APEX includes deep integration tests to verify the binary linkage between the Rust execution engine and the C memory allocator.

For example, to run the InnoDB B-Tree and C-FFI tests on macOS:

```bash
export LLVM_SYS_140_PREFIX=/usr/local/opt/llvm@14
export DYLD_LIBRARY_PATH=$PWD/core/allocator:$PWD/core/kernels:$PWD/core/fpga

cd core/storage
cargo test
```

### Protocol Buffers

The Protobuf schemas defining the network boundaries between Go, Haskell, and Rust are located at `core/proto/apex.proto`. To regenerate the stubs after making modifications:

```bash
./core/proto/generate.sh
```

---

_Built for the future of analytical execution._
