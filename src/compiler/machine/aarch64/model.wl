// src/compiler/machine/aarch64/model.wl
enum A64Register {
    None,
    X0,
    X1,
    X2,
    X3,
    X4,
    X5,
    X6,
    X7,
    X8,
    X9,
    X10,
    X11,
    X12,
    X13,
    X14,
    X15,
    X16,
    X17,
    X18,
    X19,
    X20,
    X21,
    X22,
    X23,
    X24,
    X25,
    X26,
    X27,
    X28,
    X29,
    X30,
    SP,
    ZR,
    V0,
    V1,
    V2,
    V3,
    V4,
    V5,
    V6,
    V7,
    V8,
    V9,
    V10,
    V11,
    V12,
    V13,
    V14,
    V15,
    V16,
    V17,
    V18,
    V19,
    V20,
    V21,
    V22,
    V23,
    V24,
    V25,
    V26,
    V27,
    V28,
    V29,
    V30,
    V31
}

enum A64Condition {
    Equal,
    NotEqual,
    CarrySet,
    CarryClear,
    Minus,
    Plus,
    Overflow,
    NoOverflow,
    UnsignedHigher,
    UnsignedLowerOrSame,
    SignedGreaterOrEqual,
    SignedLess,
    SignedGreater,
    SignedLessOrEqual,
    Always,
    Never
}

enum A64RelocationKind {
    None,
    Call26,
    Jump26,
    Page21,
    PageOffset12,
    Abs64
}

struct A64Symbol(
    name: String,
    section: String,
    offset: UInt32,
    external: Bool,
    hidden: Bool
)

struct A64Relocation(
    section: String,
    offset: UInt32,
    kind: A64RelocationKind,
    symbol: String,
    addend: Long
)

struct A64Section(
    name: String,
    bytes: Vector(Byte),
    alignment: Int,
    executable: Bool,
    writable: Bool
)

struct A64Object(
    sections: Vector(A64Section),
    symbols: Vector(A64Symbol),
    relocations: Vector(A64Relocation)
)

func a64_gpr_code(register: A64Register) -> Int {
// X0-X30 use their architectural number, SP and ZR both encode as 31 and
// are kept separate because the instruction decides which meaning is legal.
    let value: Int = Int(register);

    if (value >= Int(A64Register.X0) && value <= Int(A64Register.X30)) {
        return value - Int(A64Register.X0);
    }
    if (register == A64Register.SP || register == A64Register.ZR) {
        return 31;
    }

    return -1;
}

func a64_vec_code(register: A64Register) -> Int {
    let value: Int = Int(register);

    if (value < Int(A64Register.V0) || value > Int(A64Register.V31)) {
        return -1;
    }

    return value - Int(A64Register.V0);
}
