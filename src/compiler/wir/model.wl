// compiler/wir/model.wl

type WirTypeID = UInt32;
type WirValueID = UInt32;
type WirInstID = UInt32;
type WirBlockID = UInt32;
type WirFuncID = UInt32;
type WirGlobalID = UInt32;
type WirFileID = UInt32;
type WirConstID = UInt32;

const NO_WIR_TYPE: WirTypeID = WirTypeID(0U);
const NO_WIR_VALUE: WirValueID = WirValueID(0U);
const NO_WIR_INST: WirInstID = WirInstID(0U);
const NO_WIR_BLOCK: WirBlockID = WirBlockID(0U);
const NO_WIR_FUNC: WirFuncID = WirFuncID(0U);
const NO_WIR_GLOBAL: WirGlobalID = WirGlobalID(0U);
const NO_WIR_FILE: WirFileID = WirFileID(0U);
const NO_WIR_CONST: WirConstID = WirConstID(0U);

enum WirTypeKind {
    Invalid,
    VoidType,
    BoolType,
    SignedInt,
    UnsignedInt,
    FloatType,
    Pointer,
    Array,
    Struct,
    Function
}

enum WirValueKind {
    Invalid,
    Integer,
    FloatValue,
    BoolValue,
    Null,
    FunctionParameter,
    BlockParameter,
    Instruction,
    Constant,
    Global,
    Function
}

enum WirConstKind {
    Invalid,
    Zero,
    Aggregate,
    Bytes,
    Address
}

enum WirOpcode {
    Invalid,
    StackAlloc,
    Load,
    Store,
    Field,
    FieldAddress,
    Index,
    IndexAddress,
    StructValue,
    ArrayValue,
    Add,
    Subtract,
    Multiply,
    SignedDivide,
    UnsignedDivide,
    FloatDivide,
    SignedRemainder,
    UnsignedRemainder,
    FloatRemainder,
    BitAnd,
    BitOr,
    BitXor,
    ShiftLeft,
    SignedShiftRight,
    UnsignedShiftRight,
    Equal,
    NotEqual,
    SignedLess,
    SignedLessEqual,
    SignedGreater,
    SignedGreaterEqual,
    UnsignedLess,
    UnsignedLessEqual,
    UnsignedGreater,
    UnsignedGreaterEqual,
    FloatLess,
    FloatLessEqual,
    FloatGreater,
    FloatGreaterEqual,
    Negate,
    FloatNegate,
    Not,
    Truncate,
    SignExtend,
    ZeroExtend,
    FloatExtend,
    FloatTruncate,
    SignedIntToFloat,
    UnsignedIntToFloat,
    FloatToSignedInt,
    FloatToUnsignedInt,
    Bitcast,
    PointerToInt,
    IntToPointer,
    Call,
    Retain,
    Release,
    NullCheck,
    BoundsCheck,
    Jump,
    Branch,
    Return,
    Unreachable
}

enum WirLinkage {
    Private,
    Internal,
    Exported,
    External
}

enum WirABI {
    White,
    C,
    System
}

struct WirLocation(
    file: WirFileID,
    start: UInt32,
    end: UInt32
)

struct WirType(
    kind: WirTypeKind,
    name: String,
    complete: Bool,
    bits: Int,
    element: WirTypeID,
    length: UIntSize,
    fields: Vector(WirTypeID),
    parameters: Vector(WirTypeID),
    result: WirTypeID,
    variadic: Bool,
    abi: WirABI
)

struct WirParam(
    name: String,
    type_id: WirTypeID
)

struct WirValue(
    name: String,
    type_id: WirTypeID,
    kind: WirValueKind,
    owner: UInt32,
    index: Int,
    integer: UInt128,
    float_bits: UInt64
)

struct WirConstant(
    kind: WirConstKind,
    type_id: WirTypeID,
    elements: Vector(WirValueID),
    bytes: String,
    target: WirValueID,
    addend: Long
)

struct WirEdge(
    target: WirBlockID,
    arguments: Vector(WirValueID)
)

struct WirInstruction(
    opcode: WirOpcode,
    type_id: WirTypeID,
    result: WirValueID,
    operands: Vector(WirValueID),
    edges: Vector(WirEdge),
    location: WirLocation
)

struct WirBlock(
    name: String,
    function: WirFuncID,
    parameters: Vector(WirValueID),
    instructions: Vector(WirInstID)
)

struct WirFunction(
    name: String,
    type_id: WirTypeID,
    address: WirValueID,
    parameters: Vector(WirValueID),
    blocks: Vector(WirBlockID),
    entry: WirBlockID,
    linkage: WirLinkage,
    abi: WirABI
)

struct WirGlobal(
    name: String,
    type_id: WirTypeID,
    address: WirValueID,
    initializer: WirValueID,
    linkage: WirLinkage,
    is_const: Bool,
    alignment: Int
)

struct WirSourceFile(path: String)

struct WirDataLayout(
    valid: Bool,
    little_endian: Bool,
    pointer_bits: Int,
    pointer_alignment: Int,
    i64_alignment: Int,
    i128_alignment: Int,
    f64_alignment: Int,
    stack_alignment: Int
)

struct WirTypeLayout(
    valid: Bool,
    size: UInt64,
    alignment: Int,
    field_offsets: Vector(UInt64)
)

struct WirArena(
    types: Vector(WirType),
    values: Vector(WirValue),
    instructions: Vector(WirInstruction),
    blocks: Vector(WirBlock),
    functions: Vector(WirFunction),
    globals: Vector(WirGlobal),
    constants: Vector(WirConstant)
)

struct WirModule(
    target: String,
    pointer_bits: Int,
    data_layout: WirDataLayout,
    files: Vector(WirSourceFile),
    arena: WirArena,
    void_type: WirTypeID,
    bool_type: WirTypeID
)

func no_wir_location() -> WirLocation {
    return WirLocation(file=NO_WIR_FILE, start=0U, end=0U);
}

func wir_id_index(id: UInt32) -> Int {
    return Int(id) - 1;
}

func wir_is_terminator(opcode: WirOpcode) -> Bool {
    return opcode == WirOpcode.Jump || opcode == WirOpcode.Branch || opcode == WirOpcode.Return || opcode == WirOpcode.Unreachable;
}
