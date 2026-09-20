// compiler/machine/x86_64/model.wl

enum X86Register {
    None,
    RAX,
    RBX,
    RCX,
    RDX,
    RSI,
    RDI,
    RBP,
    RSP,
    R8,
    R9,
    R10,
    R11,
    R12,
    R13,
    R14,
    R15,
    XMM0,
    XMM1,
    XMM2,
    XMM3,
    XMM4,
    XMM5,
    XMM6,
    XMM7,
    XMM8,
    XMM9,
    XMM10,
    XMM11,
    XMM12,
    XMM13,
    XMM14,
    XMM15
}

enum X86OperandKind {
    None,
    Register,
    Immediate,
    Memory,
    Symbol
}

enum X86Opcode {
    Invalid,
    Mov,
    Lea,
    Add,
    Sub,
    Imul,
    Idiv,
    And,
    Or,
    Xor,
    Shl,
    Shr,
    Sar,
    Cmp,
    Test,
    Neg,
    Not,
    Push,
    Pop,
    Call,
    Ret,
    Jmp,
    Je,
    Jne,
    Jl,
    Jle,
    Jg,
    Jge,
    Ja,
    Jae,
    Jb,
    Jbe,
    Jp,
    Jnp,
    Syscall
}

enum X86RelocationKind {
    None,
    Rel32,
    Abs64
}

// these are machine-side records, not another IR. Instructions only live long
// enough to be encoded; sections, symbols and relocations are the object writer's
// input. Keeping the records plain also makes it possible to replace COFF without
// teaching WIR about an object format.

struct X86Memory(
    base: X86Register,
    index: X86Register,
    scale: Int,
    displacement: Long
)

struct X86Operand(
    kind: X86OperandKind,
    register: X86Register,
    immediate: Long,
    memory: X86Memory,
    symbol: String
)

struct X86Instruction(
    opcode: X86Opcode,
    operands: Vector(X86Operand),
    size: Int
)

struct X86Symbol(
    name: String,
    section: String,
    offset: UInt32,
    external: Bool
)

struct X86Relocation(
    section: String,
    offset: UInt32,
    kind: X86RelocationKind,
    symbol: String,
    addend: Long
)

struct X86CodeSection(
    name: String,
    bytes: Vector(Byte),
    alignment: Int,
    executable: Bool,
    writable: Bool
)

struct X86Object(
    sections: Vector(X86CodeSection),
    symbols: Vector(X86Symbol),
    relocations: Vector(X86Relocation)
)


func x86_is_xmm(register: X86Register) -> Bool {
    return Int(register) >= Int(X86Register.XMM0) && Int(register) <= Int(X86Register.XMM15);
}
