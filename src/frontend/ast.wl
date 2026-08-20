// frontend/ast.wl
import Token from "tokens.wl"
import Position, no_position, throw_internal_compiler_error from "diagnostics.wl"

const NODE_INT            : Int = 1;
const NODE_FLOAT          : Int = 2;
const NODE_BINOP          : Int = 3;
const NODE_UNARYOP        : Int = 4;
const NODE_VAR_DECL       : Int = 5; // let identi: Type = ...
const NODE_VAR_ACCESS     : Int = 6; // x
const NODE_VAR_ASSIGN     : Int = 7;
const NODE_BLOCK          : Int = 8; // { stmt1; stmt2; ... }
const NODE_POSTFIX        : Int = 9; // a++, a--
const NODE_BOOL           : Int = 10;
const NODE_IF             : Int = 11;
const NODE_WHILE          : Int = 12;
const NODE_BREAK          : Int = 13;
const NODE_CONTINUE       : Int = 14;
const NODE_FOR            : Int = 15;
const NODE_CALL           : Int = 16; // func()
const NODE_FUNC_DEF       : Int = 17; // func foo
const NODE_RETURN         : Int = 18; // return ...
const NODE_PARAM          : Int = 19; // func foo(...)
const NODE_STRING         : Int = 20;
const NODE_STRUCT_DEF     : Int = 21;
const NODE_FIELD_ACCESS   : Int = 22;
const NODE_FIELD_ASSIGN   : Int = 23;
const NODE_PTR_TYPE       : Int = 24;
const NODE_REF            : Int = 25;
const NODE_DEREF          : Int = 26;
const NODE_PTR_ASSIGN     : Int = 27;
const NODE_NULLPTR        : Int = 28;
const NODE_FUNCTION_TYPE  : Int = 29;
const NODE_NULL           : Int = 30;
const NODE_IS             : Int = 32; // is ...
const NODE_IS_NOT         : Int = 33; // is !...
const NODE_EXTERN_BLOCK   : Int = 34;
const NODE_EXTERN_FUNC    : Int = 35;
const NODE_VECTOR_TYPE    : Int = 36;
const NODE_VECTOR_LIT     : Int = 37;
const NODE_INDEX_ACCESS   : Int = 38;
const NODE_INDEX_ASSIGN   : Int = 39;
const NODE_IMPORT         : Int = 40;
const NODE_CLASS_DEF      : Int = 41;
const NODE_METHOD_DEF     : Int = 42;
const NODE_SUPER          : Int = 43;
const NODE_METHOD_TYPE    : Int = 44;
const NODE_ARRAY_TYPE     : Int = 45;
const NODE_SLICE_TYPE     : Int = 46;
const NODE_SLICE_ACCESS   : Int = 47;
const NODE_MAP_LIT        : Int = 48;
const NODE_ANNOTATION     : Int = 49; // @XXX
const NODE_CHAR           : Int = 50;
const NODE_ENUM_DEF       : Int = 51;
const NODE_ENUM_FIELD     : Int = 52;
const NODE_INTERFACE_DEF  : Int = 53;
const NODE_TRY_UNWRAP     : Int = 54;
const NODE_CATCH          : Int = 55;
const NODE_THROW          : Int = 56;
const NODE_FALLIBLE_TYPE  : Int = 57;
const NODE_TYPE_LAYOUT    : Int = 58;
const NODE_GENERIC_TYPE   : Int = 59;
const NODE_TYPE_DECL      : Int = 60;



type NodeID = UInt32;

const NO_NODE: NodeID = NodeID(0U);
const NODE_KIND_SHIFT: UInt32 = 24U;
const NODE_SLOT_MASK: UInt32 = 0x00ffffffU;
const NODE_SLOT_LIMIT: Int = 16777215;

func node_tag(node: NodeID) -> Int {
// the upper byte is the tag, zero is reserved for an absent node
    return Int(UInt32(node) >> NODE_KIND_SHIFT);
}

func node_slot(node: NodeID) -> Int {
    return Int((UInt32(node) & NODE_SLOT_MASK) - 1U);
}

func make_node_id(kind: Int, slot: Int) -> NodeID {
    if (kind <= 0 || kind > 255 || slot < 0 || slot >= NODE_SLOT_LIMIT) {
        throw_internal_compiler_error(no_position(), "AST arena node limit exceeded.");
        return NO_NODE;
    }
    return NodeID((UInt32(kind) << NODE_KIND_SHIFT) | UInt32(slot + 1));
}

func has_node(node: NodeID) -> Bool {
    return node != NO_NODE;
}

struct IntNode(
    type  : Int,
    tok   : Token,
    pos   : Position
)

struct FloatNode(
    type  : Int,
    tok   : Token, 
    pos   : Position
)

struct BooleanNode(
    type : Int, 
    tok : Token,
    value : Int, // 1 for true, 0 for false
    pos   : Position
)

struct StringNode(
    type : Int,    // NODE_STRING
    tok  : Token,  // TOK_STR_LIT
    pos  : Position
)

struct BinOpNode(
    type     : Int,
    left     : NodeID,
    op_tok   : Token,    // Token object
    right    : NodeID, 
    pos      : Position
)

struct UnaryOpNode(
    type   : Int,
    op_tok : Token,
    node   : NodeID, 
    pos    : Position
)

struct PostfixOpNode(
    type   : Int,     // NODE_POSTFIX
    node   : NodeID,  // VarAccessNode
    op_tok : Token,   // ++ or --
    pos    : Position
)

struct VarDeclareNode(
    type         : Int,    // NODE_VAR_DECL
    name_tok     : Token,  // Variable Name Token
    type_node    : NodeID,  // Type Name Token
    value        : NodeID, 
    is_const     : Bool, 
    annotations  : Vector(AnnotationNode),
    pos          : Position,    // Error position
    alloc_id     : Int
)

struct VarAccessNode(
    type     : Int,    // NODE_VAR_ACCESS
    name_tok : Token,  // Variable Name Token
    pos      : Position
)

struct VarAssignNode(
    type      : Int,       // NODE_VAR_ASSIGN
    name_tok  : Token,
    value     : NodeID,
    pos       : Position
)

struct StmtListNode(stmt: NodeID)

struct BlockNode(
    type  : Int,      // NODE_BLOCK
    stmts : Vector(NodeID)   // StmtListNode head node
)

struct IfNode(
    type      : Int,       // NODE_IF
    condition : NodeID,    // Boolean expression
    body      : NodeID,    // BlockNode
    else_body : NodeID,    // BlockNode or IfNode (else if) or null
    pos       : Position
)

struct WhileNode(
    type      : Int,       // NODE_WHILE
    condition : NodeID,    // Boolean expression
    body      : NodeID,    // BlockNode
    pos       : Position
)

struct BreakNode(
    type : Int,    // NODE_BREAK
    pos  : Position
)

struct ContinueNode(
    type : Int,   // NODE_CONTINUE
    pos  : Position
)

struct ForNode(
    type : Int,        // NODE_FOR
    init : NodeID,
    cond : NodeID,
    step : NodeID,
    body : NodeID,
    pos  : Position
)

struct CallNode(
    type   : Int,    // NODE_CALL
    callee : NodeID,
    args   : Vector(ArgNode),
    type_args : Vector(NodeID),
    pos    : Position,
    preserve_fallible : Bool
)

struct ArgNode(
    val  : NodeID, // expression
    name : String,
    is_spread : Bool
)

struct TypeDeclNode(
    type        : Int,
    name_tok    : Token,
    target_type : NodeID,
    is_alias    : Bool,
    pos         : Position
)

struct ParamNode(
    type     : Int,    // NODE_PARAM
    name_tok : Token,
    type_tok : NodeID,
    pos      : Position,
    is_variadic : Bool,
    default_val : NodeID
)


struct ParamListNode(
    param : ParamNode
)

struct BoundCallArgs(
    ordered : Vector(ArgNode),
    variadic : Vector(ArgNode)
)

struct GenericParamNode(
    name_tok : Token,
    constraints : Vector(NodeID),
    pos : Position
)


// func name(params...) : RetType { body }
struct FunctionDefNode(
    type     : Int,    // NODE_FUNC_DEF
    name_tok : Token,
    type_params : Vector(GenericParamNode),
    params   : Vector(ParamNode),
    ret_type_tok : NodeID,
    body     : NodeID,
    annotations : Vector(AnnotationNode),
    pos      : Position
)

struct ReturnNode(
    type  : Int,       // NODE_RETURN
    value : NodeID,
    pos   : Position
)

// function type syntax: Function(Type)
struct FunctionTypeNode(
    type        : Int,    // NODE_FUNCTION_TYPE
    arg_types   : Vector(NodeID),
    arg_names   : Vector(String),
    return_type : NodeID,
    variadic_param : Int,
    pos         : Position
)

struct StructDefNode(
    type     : Int,    // NODE_STRUCT_DEF
    name_tok : Token,
    type_params : Vector(GenericParamNode),
    fields   : Vector(ParamNode),
    body     : NodeID,
    annotations : Vector(AnnotationNode),
    pos      : Position
)

struct GenericTypeNode(
    type : Int,
    base_type : NodeID,
    type_args : Vector(NodeID),
    pos : Position
)

struct FieldAccessNode(
    type : Int,      // NODE_FIELD_ACCESS
    obj : NodeID,
    field_name : String,
    pos : Position
)

struct FieldAssignNode(type : Int,
    obj : NodeID,      // NODE_FIELD_ASSIGN
    field_name : String,
    value : NodeID,
    pos : Position
)


struct PointerTypeNode(
    type      : Int,    // NODE_PTR_TYPE
    base_type : NodeID,
    level     : Int,    // depth
    pos       : Position
)
struct RefNode(
    type : Int, // NODE_REF
    node : NodeID,
    pos  : Position
)
struct DerefNode(
    type  : Int, // NODE_DEREF
    node  : NodeID,
    level : Int,
    pos   : Position
)

struct ThrowNode(
    type  : Int, // NODE_THROW
    value : NodeID,
    pos   : Position
)
struct PtrAssignNode(
    type  : Int, // NODE_PTR_ASSIGN
    pointer   : NodeID, // DerefNode
    value : NodeID,
    pos   : Position
)
struct NullPtrNode(
    type : Int,      // NODE_NULLPTR
    pos  : Position
)

struct NullNode(
    type : Int,
    pos  : Position
)

struct ExternBlockNode(
    type      : Int, // NODE_EXTERN_BLOCK
    funcs     : Vector(NodeID),
    abi_name  : String,
    link_name : String,
    pos       : Position
)

struct ExternFuncNode(
    type         : Int, // NODE_EXTERN_FUNC
    name_tok     : Token,
    params       : Vector(ParamNode),
    ret_type_tok : NodeID,
    is_varargs   : Bool,    // 1 if has '...', else 0
    abi_name     : String,
    link_name    : String,
    pos          : Position
)

struct VectorTypeNode(
    type         : Int, // NODE_VECTOR_TYPE
    element_type : NodeID, // Type Node (e.g. IntNode)
    pos          : Position
)

struct VectorLitNode(
    type     : Int, // NODE_VECTOR_LIT
    elements : Vector(ArgNode),
    count    : Int,
    pos      : Position
)

struct IndexAccessNode(
    type       : Int, // NODE_INDEX_ACCESS
    target     : NodeID,
    index_node : NodeID,
    pos        : Position
)

struct IndexAssignNode(
    type       : Int, // NODE_INDEX_ASSIGN
    target     : NodeID,
    index_node : NodeID,
    value      : NodeID,
    pos        : Position
)

struct ImportSymbolNode(
    name_tok : Token,
    alias_tok : Token
)

struct ImportNode(
    type       : Int,    // NODE_IMPORT
    path_tok   : Token,
    symbols    : Vector(ImportSymbolNode),
    alias_tok  : Token,
    pos        : Position
)

struct ClassDefNode(
    type : Int, // NODE_CLASS_DEF
    pos : Position,
    name_tok : Token,
    type_params : Vector(GenericParamNode),
    parent_tok : NodeID,
    interfaces : Vector(NodeID),
    fields : Vector(NodeID),
    methods : Vector(NodeID),
    annotations : Vector(AnnotationNode)
)

struct MethodDefNode(
    type : Int, // NODE_METHOD_DEF
    pos : Position,
    name_tok : Token,
    type_params : Vector(GenericParamNode),
    params : Vector(ParamNode),
    return_type : NodeID,
    body : NodeID,
    is_override : Bool,
    annotations : Vector(AnnotationNode)
)

struct SuperNode(
    type : Int, // NODE_SUPER
    pos  : Position
)

struct MethodTypeNode(
    type        : Int,    // NODE_METHOD_TYPE
    arg_types   : Vector(NodeID),
    arg_names   : Vector(String),
    return_type : NodeID,
    variadic_param : Int,
    pos         : Position
)

struct ArrayTypeNode(
    type      : Int,    // NODE_ARRAY_TYPE
    base_type : NodeID,
    size_tok  : Token,
    pos       : Position
)

struct SliceTypeNode(
    type         : Int, // NODE_SLICE_TYPE
    element_type : NodeID,
    pos          : Position
)

struct SliceAccessNode(
    type : Int, // NODE_SLICE_ACCESS
    target : NodeID, // data
    start_idx : NodeID,
    end_idx : NodeID,
    pos : Position
)

struct MapPairNode(
    key   : NodeID,
    value : NodeID
)
struct MapLitNode(
    type  : Int, // NODE_MAP_LIT
    pairs : Vector(MapPairNode),
    pos   : Position
)

struct AnnotationNode(
    type : Int, // NODE_ANNOTATION
    name : String,
    args : Vector(ArgNode),
    pos  : Position
)

struct CharNode(
    type : Int, // NODE_CHAR
    tok  : Token,
    pos  : Position
)

struct EnumDefNode(
    type     : Int, // NODE_ENUM_DEF
    name_tok : Token,
    fields   : Vector(EnumFieldNode),
    annotations : Vector(AnnotationNode),
    is_error : Bool,
    pos      : Position
)

struct EnumFieldNode(
    type     : Int, // NODE_ENUM_FIELD
    name_tok : Token,
    value    : NodeID, // optional explicit Int value
    pos      : Position
)

struct TryUnwrapNode(
    type : Int, // NODE_TRY_UNWRAP
    expr : NodeID,
    pos  : Position
)

struct CatchNode(
    type     : Int, // NODE_CATCH
    stmt     : NodeID,
    err_name : Token, 
    body     : NodeID, // BlockNode
    pos      : Position,
    alloc_id : Int
)

struct FallibleTypeNode(
    type      : Int, // NODE_FALLIBLE_TYPE
    base_type : NodeID,
    pos       : Position
)

struct TypeLayoutNode(
    type : Int, // NODE_TYPE_LAYOUT
    type_node : NodeID,
    is_align : Bool,
    pos : Position
)

struct InterfaceDefNode(
    type     : Int, // NODE_INTERFACE_DEF
    name_tok : Token,
    type_params : Vector(GenericParamNode),
    interfaces : Vector(NodeID),
    methods  : Vector(NodeID),
    annotations : Vector(AnnotationNode),
    pos      : Position
)
