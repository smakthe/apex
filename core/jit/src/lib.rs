//! APEX JIT Compiler
//! Pipeline: APEX-IR → SSA → Dominance → Loop Analysis →
//!           Alias Analysis → Instruction Selection → RegAlloc → Emit

pub mod ffi;

use std::collections::{HashMap, HashSet, BinaryHeap, VecDeque};
use std::sync::Arc;
use inkwell::{
    context::Context,
    builder::Builder,
    module::Module,
    passes::PassManager,
    targets::{
        CodeModel, FileType, InitializationConfig, RelocMode,
        Target, TargetMachine,
    },
    types::BasicType,
    values::{BasicValue, FunctionValue, PointerValue},
    OptimizationLevel,
};

// ── APEX Intermediate Representation ─────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum ApexType {
    I8, I16, I32, I64, I128,
    F32, F64,
    Ptr(Box<ApexType>),
    Vec(Box<ApexType>, u32),   /* SIMD: <N x T> */
    Struct(Vec<ApexType>),
    Opaque(String),
}

#[derive(Debug, Clone)]
pub enum ApexValue {
    Const(i128),
    ConstF(f64),
    Reg(u32),                  /* SSA register */
    Global(String),
    Undef,
}

/// Every instruction is in SSA form: exactly one def, N uses.
#[derive(Debug, Clone)]
pub enum ApexInstr {
    /* Arithmetic */
    BinOp { op: BinOpKind, dst: u32, lhs: ApexValue, rhs: ApexValue, ty: ApexType },
    UnOp  { op: UnOpKind,  dst: u32, src: ApexValue, ty: ApexType },

    /* Memory */
    Load  { dst: u32, addr: ApexValue, ty: ApexType, volatile: bool, align: u32 },
    Store { addr: ApexValue, val: ApexValue, ty: ApexType, volatile: bool, align: u32 },
    Alloca{ dst: u32, ty: ApexType, count: ApexValue },
    Gep   { dst: u32, base: ApexValue, indices: Vec<ApexValue>, ty: ApexType },

    /* Control flow */
    Br      { cond: ApexValue, then_bb: usize, else_bb: usize },
    Jump    { target: usize },
    Switch  { val: ApexValue, default: usize, arms: Vec<(i128, usize)> },
    Ret     { val: Option<ApexValue> },

    /* Calls */
    Call    { dst: Option<u32>, func: ApexValue, args: Vec<ApexValue>, cc: CallConv },
    Intrinsic{ dst: Option<u32>, name: String, args: Vec<ApexValue> },

    /* SSA */
    Phi     { dst: u32, ty: ApexType, incoming: Vec<(ApexValue, usize)> },

    /* Atomic */
    AtomicRMW { dst: u32, op: AtomicOp, ptr: ApexValue, val: ApexValue,
                ordering: MemOrdering },
    Cmpxchg   { dst: u32, ptr: ApexValue, cmp: ApexValue, new: ApexValue,
                success: MemOrdering, failure: MemOrdering },
}

#[derive(Debug, Clone, Copy)] pub enum BinOpKind { Add,Sub,Mul,UDiv,SDiv,URem,SRem,
    And,Or,Xor,Shl,LShr,AShr,FAdd,FSub,FMul,FDiv,FRem,
    ICmpEq,ICmpNe,ICmpUlt,ICmpUle,ICmpUgt,ICmpUge,
    ICmpSlt,ICmpSle,ICmpSgt,ICmpSge,
    FCmpOlt,FCmpOle,FCmpOgt,FCmpOge,FCmpOeq,FCmpOne }
#[derive(Debug, Clone, Copy)] pub enum UnOpKind  { Neg,Not,FNeg,Trunc,ZExt,SExt,FPExt,
    FPTrunc,FPToUI,FPToSI,UIToFP,SIToFP,PtrToInt,IntToPtr,Bitcast }
#[derive(Debug, Clone, Copy)] pub enum CallConv  { C, Fast, Cold, GHC }
#[derive(Debug, Clone, Copy)] pub enum AtomicOp  { Xchg,Add,Sub,And,Nand,Or,Xor,Max,Min,UMax,UMin }
#[derive(Debug, Clone, Copy)] pub enum MemOrdering { Unordered,Monotonic,Acquire,Release,AcqRel,SeqCst }

#[derive(Debug)]
pub struct BasicBlock {
    pub id:    usize,
    pub label: String,
    pub instrs: Vec<ApexInstr>,
    pub preds:  Vec<usize>,
    pub succs:  Vec<usize>,
}

#[derive(Debug)]
pub struct ApexFunction {
    pub name:   String,
    pub params: Vec<(u32, ApexType)>,
    pub ret_ty: Option<ApexType>,
    pub blocks: Vec<BasicBlock>,
    pub reg_count: u32,
}

// ── Dominance Tree (Cooper-Harvey-Kennedy algorithm) ─────────────────

#[derive(Debug)]
pub struct DomTree {
    pub idom:    Vec<Option<usize>>,       /* immediate dominator per block */
    pub dom_set: Vec<HashSet<usize>>,
    pub df:      Vec<HashSet<usize>>,      /* dominance frontier */
}

impl DomTree {
    pub fn compute(func: &ApexFunction) -> Self {
        let n = func.blocks.len();
        let mut idom: Vec<Option<usize>> = vec![None; n];
        idom[0] = Some(0);

        // Reverse post-order numbering
        let rpo = Self::reverse_postorder(func);
        let rpo_num: Vec<usize> = {
            let mut m = vec![0usize; n];
            for (i, &b) in rpo.iter().enumerate() { m[b] = i; }
            m
        };

        let mut changed = true;
        while changed {
            changed = false;
            for &b in rpo.iter().skip(1) {
                let processed_preds: Vec<usize> = func.blocks[b].preds.iter()
                    .copied()
                    .filter(|&p| idom[p].is_some())
                    .collect();

                if let Some(&first) = processed_preds.first() {
                    let mut new_idom = first;
                    for &p in processed_preds.iter().skip(1) {
                        new_idom = Self::intersect(p, new_idom, &idom, &rpo_num);
                    }
                    if idom[b] != Some(new_idom) {
                        idom[b] = Some(new_idom);
                        changed = true;
                    }
                }
            }
        }

        // Dominance frontier
        let mut df = vec![HashSet::new(); n];
        for b in 0..n {
            if func.blocks[b].preds.len() >= 2 {
                for &p in &func.blocks[b].preds {
                    let mut runner = p;
                    while Some(runner) != idom[b] {
                        df[runner].insert(b);
                        runner = idom[runner].unwrap();
                    }
                }
            }
        }

        let dom_set = vec![HashSet::new(); n]; // computed lazily
        DomTree { idom, dom_set, df }
    }

    fn intersect(b1: usize, b2: usize,
                 idom: &[Option<usize>],
                 rpo_num: &[usize]) -> usize {
        let (mut f, mut g) = (b1, b2);
        while f != g {
            while rpo_num[f] > rpo_num[g] { f = idom[f].unwrap(); }
            while rpo_num[g] > rpo_num[f] { g = idom[g].unwrap(); }
        }
        f
    }

    fn reverse_postorder(func: &ApexFunction) -> Vec<usize> {
        let n = func.blocks.len();
        let mut visited = vec![false; n];
        let mut order   = Vec::with_capacity(n);
        let mut stack   = vec![(0usize, false)];

        while let Some((b, done)) = stack.pop() {
            if done { order.push(b); continue; }
            if visited[b] { continue; }
            visited[b] = true;
            stack.push((b, true));
            for &s in func.blocks[b].succs.iter().rev() {
                if !visited[s] { stack.push((s, false)); }
            }
        }
        order.reverse();
        order
    }
}

// ── Graph-Coloring Register Allocator (Chaitin-Briggs) ───────────────

#[derive(Debug)]
struct InterferenceGraph {
    adj:    Vec<HashSet<u32>>,             /* adjacency: reg → set of regs */
    degree: Vec<u32>,
    n_regs: u32,
}

impl InterferenceGraph {
    fn new(n: u32) -> Self {
        Self { adj: vec![HashSet::new(); n as usize], degree: vec![0; n as usize], n_regs: n }
    }

    fn add_edge(&mut self, u: u32, v: u32) {
        if u != v && !self.adj[u as usize].contains(&v) {
            self.adj[u as usize].insert(v);
            self.adj[v as usize].insert(u);
            self.degree[u as usize] += 1;
            self.degree[v as usize] += 1;
        }
    }
}

pub struct RegisterAllocator {
    k: u32,    /* number of physical registers */
}

impl RegisterAllocator {
    pub fn new(k: u32) -> Self { Self { k } }

    /// Returns: mapping virtual_reg → physical_reg, or None = spill
    pub fn allocate(
        &self,
        func: &ApexFunction,
        ig:   &mut InterferenceGraph,
    ) -> HashMap<u32, Option<u32>> {
        let n = ig.n_regs;
        let k = self.k;

        // Simplify → Coalesce → Freeze → Potential-Spill → Select
        let mut stack: Vec<u32> = Vec::new();
        let mut removed         = vec![false; n as usize];
        let mut spill_cost      = vec![f64::INFINITY; n as usize];

        // Compute spill costs (uses/defs weighted by loop depth)
        // simplified here — real impl weights by 10^loop_depth
        for bb in &func.blocks {
            for instr in &bb.instrs {
                if let ApexInstr::BinOp { dst, .. } = instr {
                    spill_cost[*dst as usize] = 1.0;
                }
            }
        }

        let mut degree = ig.degree.clone();

        let simplify = |stack: &mut Vec<u32>, removed: &mut Vec<bool>, degree: &mut Vec<u32>| {
            'outer: loop {
                for v in 0..n {
                    if !removed[v as usize] && degree[v as usize] < k {
                        removed[v as usize] = true;
                        stack.push(v);
                        for &u in &ig.adj[v as usize] {
                            if !removed[u as usize] {
                                degree[u as usize] = degree[u as usize].saturating_sub(1);
                            }
                        }
                        continue 'outer;
                    }
                }
                break;
            }
        };

        let select_spill = |removed: &Vec<bool>, degree: &Vec<u32>,
                            spill_cost: &Vec<f64>| -> u32 {
            (0..n)
                .filter(|&v| !removed[v as usize])
                .min_by(|&a, &b| {
                    let ca = spill_cost[a as usize] / degree[a as usize].max(1) as f64;
                    let cb = spill_cost[b as usize] / degree[b as usize].max(1) as f64;
                    ca.partial_cmp(&cb).unwrap()
                })
                .expect("no node to spill")
        };

        // Main Chaitin-Briggs loop
        loop {
            simplify(&mut stack, &mut removed, &mut degree);
            if stack.len() == n as usize { break; }
            let spill = select_spill(&removed, &degree, &spill_cost);
            removed[spill as usize] = true;
            stack.push(spill);
        }

        // Color phase (reverse of simplify order)
        let mut color: HashMap<u32, Option<u32>> = HashMap::new();
        while let Some(v) = stack.pop() {
            let used: HashSet<u32> = ig.adj[v as usize].iter()
                .filter_map(|&u| color.get(&u).and_then(|c| *c))
                .collect();
            let assigned = (0..k).find(|c| !used.contains(c));
            color.insert(v, assigned);   /* None → spill */
        }

        color
    }
}

// ── LLVM Code Generation ──────────────────────────────────────────────

pub struct CodeGen<'ctx> {
    ctx:     &'ctx Context,
    module:  Module<'ctx>,
    builder: Builder<'ctx>,
    reg_map: HashMap<u32, inkwell::values::BasicValueEnum<'ctx>>,
}

impl<'ctx> CodeGen<'ctx> {
    pub fn new(ctx: &'ctx Context, module_name: &str) -> Self {
        Self {
            ctx,
            module:  ctx.create_module(module_name),
            builder: ctx.create_builder(),
            reg_map: HashMap::new(),
        }
    }

    fn apex_type_to_llvm(&self, ty: &ApexType)
        -> inkwell::types::BasicTypeEnum<'ctx>
    {
        match ty {
            ApexType::I8   => self.ctx.i8_type().into(),
            ApexType::I16  => self.ctx.i16_type().into(),
            ApexType::I32  => self.ctx.i32_type().into(),
            ApexType::I64  => self.ctx.i64_type().into(),
            ApexType::I128 => self.ctx.i128_type().into(),
            ApexType::F32  => self.ctx.f32_type().into(),
            ApexType::F64  => self.ctx.f64_type().into(),
            ApexType::Ptr(inner) => {
                let inner_ty = self.apex_type_to_llvm(inner);
                inner_ty.ptr_type(inkwell::AddressSpace::from(0)).into()
            }
            ApexType::Vec(elem, n) => {
                match self.apex_type_to_llvm(elem) {
                    inkwell::types::BasicTypeEnum::IntType(t) =>
                        t.vec_type(*n).into(),
                    inkwell::types::BasicTypeEnum::FloatType(t) =>
                        t.vec_type(*n).into(),
                    _ => panic!("unsupported vector element type"),
                }
            }
            ApexType::Struct(fields) => {
                let field_types: Vec<_> = fields.iter()
                    .map(|f| self.apex_type_to_llvm(f)).collect();
                self.ctx.struct_type(&field_types, false).into()
            }
            ApexType::Opaque(name) => {
                self.ctx.opaque_struct_type(name).into()
            }
        }
    }

    pub fn emit_native(&self) -> Vec<u8> {
        Target::initialize_all(&InitializationConfig::default());
        let target_triple = TargetMachine::get_default_triple();
        let target = Target::from_triple(&target_triple).unwrap();
        let target_machine = target
            .create_target_machine(
                &target_triple,
                "native",
                "+avx2,+avx512f,+avx512cd,+avx512bw,+avx512vl",
                OptimizationLevel::Aggressive,
                RelocMode::PIC,
                CodeModel::Default,
            )
            .unwrap();

        let pm: PassManager<Module> = PassManager::create(());
        pm.add_instruction_combining_pass();
        pm.add_reassociate_pass();
        pm.add_gvn_pass();
        pm.add_cfg_simplification_pass();
        pm.add_basic_alias_analysis_pass();
        pm.add_promote_memory_to_register_pass();
        pm.add_loop_unroll_pass();
        pm.add_loop_vectorize_pass();
        pm.add_slp_vectorize_pass();
        pm.add_licm_pass();
        pm.run_on(&self.module);

        let buf = target_machine
            .write_to_memory_buffer(&self.module, FileType::Object)
            .unwrap();
        buf.as_slice().to_vec()
    }
}
