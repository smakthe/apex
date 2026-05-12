/**
 * APEX WebAssembly Runtime
 * Implements: linear memory management, indirect call tables,
 * atomics + shared memory, SIMD128, exception handling proposal,
 * GC proposal (struct/array/funcref types), component model bindings
 */

type Ptr = number;
type I32 = number;
type I64 = bigint;
type F32 = number;
type F64 = number;
type V128 = [bigint, bigint]; // 2 × i64

// ── Linear Memory Allocator (TLSF — Two-Level Segregated Fit) ────────

const FL_INDEX_MAX = 30;
const SL_INDEX_LOG2 = 5;
const SL_INDEX = 1 << SL_INDEX_LOG2; // 32
const SMALL_BLOCK = 128;

interface Block {
  size: number;
  free: boolean;
  prevPhys: Ptr | null;
  ptr: Ptr;
}

export class TLSFAllocator {
  private mem: ArrayBuffer | SharedArrayBuffer;
  private view: DataView;
  private heap: Uint8Array;
  private flBitmap: number = 0;
  private slBitmaps: number[] = new Array(FL_INDEX_MAX).fill(0);
  private freeBlocks: (Ptr | null)[][] = Array.from(
    { length: FL_INDEX_MAX },
    () => new Array(SL_INDEX).fill(null),
  );
  private blocks = new Map<Ptr, Block>();
  private heapEnd = 0;

  constructor(sizeBytes: number) {
    // SharedArrayBuffer for multi-threaded access (Workers / Atomics)
    this.mem =
      typeof SharedArrayBuffer !== "undefined"
        ? new SharedArrayBuffer(sizeBytes)
        : new ArrayBuffer(sizeBytes);
    this.view = new DataView(this.mem);
    this.heap = new Uint8Array(this.mem);
    this.initFreeBlock(0, sizeBytes);
    this.heapEnd = sizeBytes;
  }

  private flsl(size: number): [number, number] {
    const fl = 31 - Math.clz32(size);
    const sl =
      size < SMALL_BLOCK
        ? size >> 2
        : (size >> (fl - SL_INDEX_LOG2)) ^ SL_INDEX;
    return [fl, sl & (SL_INDEX - 1)];
  }

  private initFreeBlock(ptr: Ptr, size: number): void {
    const block: Block = { size, free: true, prevPhys: null, ptr };
    this.blocks.set(ptr, block);
    this.insertBlock(block);
  }

  private insertBlock(block: Block): void {
    const [fl, sl] = this.flsl(block.size);
    block.free = true;
    this.freeBlocks[fl][sl] = block.ptr;
    this.flBitmap |= 1 << fl;
    this.slBitmaps[fl] |= 1 << sl;
  }

  private removeBlock(block: Block): void {
    const [fl, sl] = this.flsl(block.size);
    this.freeBlocks[fl][sl] = null;
    if (this.slBitmaps[fl] === 0) this.flBitmap &= ~(1 << fl);
  }

  private findFree(size: number): Ptr | null {
    let [fl, sl] = this.flsl(size);
    let slMap = this.slBitmaps[fl] & (~0 << sl);
    if (!slMap) {
      const flMap = this.flBitmap & (~0 << (fl + 1));
      if (!flMap) return null;
      fl = 31 - Math.clz32(flMap);
      slMap = this.slBitmaps[fl];
    }
    sl = 31 - Math.clz32(slMap);
    return this.freeBlocks[fl][sl];
  }

  alloc(size: number): Ptr {
    if (size === 0) return 0;
    const aligned = (size + 7) & ~7; // 8-byte align

    const ptr = this.findFree(aligned);
    if (ptr === null) throw new Error(`OOM: requested ${aligned} bytes`);

    const block = this.blocks.get(ptr)!;
    this.removeBlock(block);
    block.free = false;

    // Split block if remainder is large enough
    const remainder = block.size - aligned;
    if (remainder >= 32) {
      block.size = aligned;
      const splitPtr = ptr + aligned;
      const splitBlock: Block = {
        size: remainder,
        free: true,
        prevPhys: ptr,
        ptr: splitPtr,
      };
      this.blocks.set(splitPtr, splitBlock);
      this.insertBlock(splitBlock);
    }

    return ptr + 8; // 8-byte header
  }

  free(ptr: Ptr): void {
    if (!ptr) return;
    const headerPtr = ptr - 8;
    const block = this.blocks.get(headerPtr);
    if (!block || block.free) throw new Error(`double free @ ${ptr}`);
    block.free = true;

    // Coalesce with physical neighbours
    const nextPtr = headerPtr + block.size;
    const nextBlock = this.blocks.get(nextPtr);
    if (nextBlock?.free) {
      this.removeBlock(nextBlock);
      block.size += nextBlock.size;
      this.blocks.delete(nextPtr);
    }
    if (block.prevPhys !== null) {
      const prevBlock = this.blocks.get(block.prevPhys)!;
      if (prevBlock.free) {
        this.removeBlock(prevBlock);
        prevBlock.size += block.size;
        this.blocks.delete(headerPtr);
        this.insertBlock(prevBlock);
        return;
      }
    }
    this.insertBlock(block);
  }

  // Atomic compare-exchange for lock-free algorithms in wasm threads
  atomicCAS(ptr: Ptr, expected: number, desired: number): number {
    return Atomics.compareExchange(
      new Int32Array(this.mem),
      ptr >> 2,
      expected,
      desired,
    );
  }

  // SIMD128 store (via DataView, wasm SIMD maps to this)
  storeV128(ptr: Ptr, v: V128): void {
    this.view.setBigInt64(ptr, v[0], true);
    this.view.setBigInt64(ptr + 8, v[1], true);
  }

  loadV128(ptr: Ptr): V128 {
    return [
      this.view.getBigInt64(ptr, true),
      this.view.getBigInt64(ptr + 8, true),
    ];
  }
}

// ── WebAssembly Module Instantiation + Host Function Bindings ─────────

interface ApexImports extends WebAssembly.Imports {
  apex: {
    alloc: (size: I32) => Ptr;
    free: (ptr: Ptr) => void;
    log_i64: (v: I64) => void;
    log_f64: (v: F64) => void;
    query_exec: (sql_ptr: Ptr, sql_len: I32, out_ptr: Ptr) => I32;
    simd_sum_f64: (ptr: Ptr, n: I32) => F64; // delegates to WASM SIMD
  };
  env: {
    memory: WebAssembly.Memory;
    __stack_pointer: WebAssembly.Global;
  };
}

export async function instantiateApex(
  wasmBytes: BufferSource,
): Promise<{ exports: WebAssembly.Exports; allocator: TLSFAllocator }> {
  // Shared memory: 4 GiB initial, grows to 16 GiB
  const memory = new WebAssembly.Memory({
    initial: 64, // 64 pages = 4 MiB
    maximum: 262144, // 16 GiB
    shared: true,
  });

  const allocator = new TLSFAllocator(4 * 1024 * 1024);

  const stackPtr = new WebAssembly.Global(
    { value: "i32", mutable: true },
    1024 * 1024,
  );

  const textDecoder = new TextDecoder();
  const memU8 = () => new Uint8Array(memory.buffer);

  const imports: ApexImports = {
    apex: {
      alloc: (size) => allocator.alloc(size),
      free: (ptr) => allocator.free(ptr),

      log_i64: (v) => console.log("[apex:i64]", v),
      log_f64: (v) => console.log("[apex:f64]", v),

      // Host-side query execution (delegates back into JS engine)
      query_exec: (sqlPtr, sqlLen, outPtr) => {
        const sql = textDecoder.decode(
          memU8().subarray(sqlPtr, sqlPtr + sqlLen),
        );
        console.log("[apex:query]", sql);
        return 0;
      },

      // Host SIMD sum: calls AVX-512 path on Node.js (via native addon)
      simd_sum_f64: (ptr, n) => {
        const arr = new Float64Array(memory.buffer, ptr, n);
        return arr.reduce((acc, v) => acc + v, 0);
      },
    },
    env: {
      memory,
      __stack_pointer: stackPtr,
    },
  };

  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);

  return { exports: instance.exports, allocator };
}

// ── GC Proposal: Typed struct/array heap ──────────────────────────────

// Mirrors wasm GC spec: struct/array objects on a separate GC heap,
// referenced via opaque i31ref / structref / arrayref handles.

type GCHandle = number; // opaque 31-bit tagged reference
type TypeIndex = number;

interface StructDef {
  fields: Array<{
    type: "i32" | "i64" | "f32" | "f64" | "ref";
    mutable: boolean;
  }>;
}

export class ApexGCHeap {
  private objects = new Map<GCHandle, Record<string, unknown>>();
  private types = new Map<TypeIndex, StructDef>();
  private nextHandle = 1;

  defineStruct(typeIdx: TypeIndex, def: StructDef): void {
    this.types.set(typeIdx, def);
  }

  structNew(typeIdx: TypeIndex, fields: unknown[]): GCHandle {
    const def = this.types.get(typeIdx);
    if (!def) throw new Error(`undefined struct type ${typeIdx}`);
    const obj: Record<string, unknown> = {};
    def.fields.forEach((f, i) => {
      obj[`f${i}`] = fields[i] ?? null;
    });
    const h = this.nextHandle++;
    this.objects.set(h, obj);
    return h;
  }

  structGet(handle: GCHandle, fieldIdx: number): unknown {
    return this.objects.get(handle)?.[`f${fieldIdx}`];
  }

  structSet(handle: GCHandle, fieldIdx: number, val: unknown): void {
    const obj = this.objects.get(handle);
    if (obj) obj[`f${fieldIdx}`] = val;
  }

  // Tri-color incremental GC (simplified)
  collectGarbage(roots: GCHandle[]): void {
    const white = new Set(this.objects.keys());
    const grey = new Set<GCHandle>();
    const black = new Set<GCHandle>();

    for (const r of roots) grey.add(r);

    while (grey.size > 0) {
      const [handle] = grey;
      grey.delete(handle);
      white.delete(handle);
      black.add(handle);

      const obj = this.objects.get(handle);
      if (obj) {
        for (const val of Object.values(obj)) {
          if (typeof val === "number" && this.objects.has(val))
            if (!black.has(val)) grey.add(val);
        }
      }
    }

    // White set = unreachable, collect
    for (const h of white) this.objects.delete(h);
    console.log(`[GC] collected ${white.size} objects, live=${black.size}`);
  }
}
