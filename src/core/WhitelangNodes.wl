// core/WhitelangNodes.wl
import Token from "WhitelangTokens.wl"
import Position from "WhitelangExceptions.wl"

const NODE_INT            -> Int = 1;
const NODE_FLOAT          -> Int = 2;
const NODE_BINOP          -> Int = 3;
const NODE_UNARYOP        -> Int = 4;
const NODE_VAR_DECL       -> Int = 5; // let identi -> Type = ...
const NODE_VAR_ACCESS     -> Int = 6; // x
const NODE_VAR_ASSIGN     -> Int = 7;
const NODE_BLOCK          -> Int = 8; // { stmt1; stmt2; ... }
const NODE_POSTFIX        -> Int = 9; // a++, a--
const NODE_BOOL           -> Int = 10;
const NODE_IF             -> Int = 11;
const NODE_WHILE          -> Int = 12;
const NODE_BREAK          -> Int = 13;
const NODE_CONTINUE       -> Int = 14;
const NODE_FOR            -> Int = 15;
const NODE_CALL           -> Int = 16; // func()
const NODE_FUNC_DEF       -> Int = 17; // func foo
const NODE_RETURN         -> Int = 18; // return ...
const NODE_PARAM          -> Int = 19; // func foo(...)
const NODE_STRING         -> Int = 20;
const NODE_STRUCT_DEF     -> Int = 21;
const NODE_FIELD_ACCESS   -> Int = 22;
const NODE_FIELD_ASSIGN   -> Int = 23;
const NODE_PTR_TYPE       -> Int = 24;
const NODE_REF            -> Int = 25;
const NODE_DEREF          -> Int = 26;
const NODE_PTR_ASSIGN     -> Int = 27;
const NODE_NULLPTR        -> Int = 28;
const NODE_FUNCTION_TYPE  -> Int = 29;
const NODE_NULL           -> Int = 30;
const NODE_IS             -> Int = 32; // is ...
const NODE_IS_NOT         -> Int = 33; // is !...
const NODE_EXTERN_BLOCK   -> Int = 34;
const NODE_EXTERN_FUNC    -> Int = 35;
const NODE_VECTOR_TYPE    -> Int = 36;
const NODE_VECTOR_LIT     -> Int = 37;
const NODE_INDEX_ACCESS   -> Int = 38;
const NODE_INDEX_ASSIGN   -> Int = 39;
const NODE_IMPORT         -> Int = 40;
const NODE_CLASS_DEF      -> Int = 41;
const NODE_METHOD_DEF     -> Int = 42;
const NODE_SUPER          -> Int = 43;
const NODE_METHOD_TYPE    -> Int = 44;
const NODE_ARRAY_TYPE     -> Int = 45;
const NODE_SLICE_TYPE     -> Int = 46;
const NODE_SLICE_ACCESS   -> Int = 47;
const NODE_MAP_LIT        -> Int = 48;
const NODE_ANNOTATION     -> Int = 49; // @XXX
const NODE_CHAR           -> Int = 50;
const NODE_ENUM_DEF       -> Int = 51;
const NODE_ENUM_FIELD     -> Int = 52;
const NODE_INTERFACE_DEF  -> Int = 53;
const NODE_TRY_UNWRAP     -> Int = 54;
const NODE_CATCH          -> Int = 55;
const NODE_THROW          -> Int = 56;
const NODE_FALLIBLE_TYPE  -> Int = 57;
const NODE_TYPE_LAYOUT    -> Int = 58;
const NODE_GENERIC_TYPE   -> Int = 59;

struct BaseNode(type -> Int) // Used to read node type

struct IntNode(
    type  -> Int,
    tok   -> Token,
    pos   -> Position
)

struct FloatNode(
    type  -> Int,
    tok   -> Token, 
    pos   -> Position
)

struct BooleanNode(
    type -> Int, 
    tok -> Token,
    value -> Int, // 1 for true, 0 for false
    pos   -> Position
)

struct StringNode(
    type -> Int,    // NODE_STRING
    tok  -> Token,  // TOK_STR_LIT
    pos  -> Position
)

struct BinOpNode(
    type     -> Int,
    left     -> Struct,
    op_tok   -> Token,    // Token object
    right    -> Struct, 
    pos      -> Position
)

struct UnaryOpNode(
    type   -> Int,
    op_tok -> Token,
    node   -> Struct, 
    pos    -> Position
)

struct PostfixOpNode(
    type   -> Int,     // NODE_POSTFIX
    node   -> Struct,  // VarAccessNode
    op_tok -> Token,   // ++ or --
    pos    -> Position
)

struct VarDeclareNode(
    type         -> Int,    // NODE_VAR_DECL
    name_tok     -> Token,  // Variable Name Token
    type_node    -> Struct,  // Type Name Token
    value        -> Struct, 
    is_const     -> Bool, 
    annotations  -> Vector(Struct),
    pos          -> Position,    // Error position
    alloc_id     -> Int
)

struct VarAccessNode(
    type     -> Int,    // NODE_VAR_ACCESS
    name_tok -> Token,  // Variable Name Token
    pos      -> Position
)

struct VarAssignNode(
    type      -> Int,       // NODE_VAR_ASSIGN
    name_tok  -> Token,
    value     -> Struct,
    pos       -> Position
)

struct StmtListNode(
    stmt -> Struct
)

struct BlockNode(
    type  -> Int,      // NODE_BLOCK
    stmts -> Vector(Struct)   // StmtListNode head node
)

struct IfNode(
    type      -> Int,       // NODE_IF
    condition -> Struct,    // Boolean expression
    body      -> Struct,    // BlockNode
    else_body -> Struct,    // BlockNode or IfNode (else if) or null
    pos       -> Position
)

struct WhileNode(
    type      -> Int,       // NODE_WHILE
    condition -> Struct,    // Boolean expression
    body      -> Struct,    // BlockNode
    pos       -> Position
)

struct BreakNode(
    type -> Int,    // NODE_BREAK
    pos  -> Position
)

struct ContinueNode(
    type -> Int,   // NODE_CONTINUE
    pos  -> Position
)

struct ForNode(
    type -> Int,        // NODE_FOR
    init -> Struct,
    cond -> Struct,
    step -> Struct,
    body -> Struct,
    pos  -> Position
)

struct CallNode(
    type   -> Int,    // NODE_CALL
    callee -> Struct,
    args   -> Vector(Struct),
    type_args -> Vector(Struct),
    pos    -> Position,
    preserve_fallible -> Bool
)

struct ArgNode(
    val  -> Struct, // expression
    name -> String
)

struct ParamNode(
    type     -> Int,    // NODE_PARAM
    name_tok -> Token,
    type_tok -> Struct,
    pos      -> Position
)


struct ParamListNode(
    param -> Struct // ParamNode
)

struct GenericParamNode(
    name_tok -> Token,
    constraints -> Vector(Struct),
    pos -> Position
)


// func name(params...) -> RetType { body }
struct FunctionDefNode(
    type     -> Int,    // NODE_FUNC_DEF
    name_tok -> Token,
    type_params -> Vector(Struct),
    params   -> Vector(Struct), // ParamListNode
    ret_type_tok -> Struct,
    body     -> Struct,
    annotations -> Vector(Struct),
    pos      -> Position
)

struct ReturnNode(
    type  -> Int,       // NODE_RETURN
    value -> Struct,
    pos   -> Position
)

// Function(Type)
struct FunctionTypeNode(
    type        -> Int,    // NODE_FUNCTION_TYPE
    arg_types   -> Vector(Struct),
    return_type -> Struct,
    pos         -> Position
)

struct StructDefNode(
    type     -> Int,    // NODE_STRUCT_DEF
    name_tok -> Token,
    type_params -> Vector(Struct),
    fields   -> Vector(Struct),
    body     -> Struct,
    annotations -> Vector(Struct),
    pos      -> Position
)

struct GenericTypeNode(
    type -> Int,
    base_type -> Struct,
    type_args -> Vector(Struct),
    pos -> Position
)

struct FieldAccessNode(
    type -> Int,      // NODE_FIELD_ACCESS
    obj -> Struct,
    field_name -> String,
    pos -> Position
)

struct FieldAssignNode(type -> Int,
    obj -> Struct,      // NODE_FIELD_ASSIGN
    field_name -> String,
    value -> Struct,
    pos -> Position
)


struct PointerTypeNode(
    type      -> Int,    // NODE_PTR_TYPE
    base_type -> Struct,
    level     -> Int,    // depth
    pos       -> Position
)
struct RefNode(
    type -> Int, // NODE_REF
    node -> Struct,
    pos  -> Position
)
struct DerefNode(
    type  -> Int, // NODE_DEREF
    node  -> Struct,
    level -> Int,
    pos   -> Position
)

struct ThrowNode(
    type  -> Int, // NODE_THROW
    value -> Struct,
    pos   -> Position
)
struct PtrAssignNode(
    type  -> Int, // NODE_PTR_ASSIGN
    pointer   -> Struct, // DerefNode
    value -> Struct,
    pos   -> Position
)
struct NullPtrNode(
    type -> Int,      // NODE_NULLPTR
    pos  -> Position
)

struct NullNode(
    type -> Int,
    pos  -> Position
)

struct ExternBlockNode(
    type      -> Int, // NODE_EXTERN_BLOCK
    funcs     -> Vector(Struct),
    abi_name  -> String,
    link_name -> String,
    pos       -> Position
)

struct ExternFuncNode(
    type         -> Int, // NODE_EXTERN_FUNC
    name_tok     -> Token,
    params       -> Vector(Struct),
    ret_type_tok -> Struct,
    is_varargs   -> Bool,    // 1 if has '...', else 0
    abi_name     -> String,
    link_name    -> String,
    pos          -> Position
)

struct VectorTypeNode(
    type         -> Int, // NODE_VECTOR_TYPE
    element_type -> Struct, // Type Node (e.g. IntNode)
    pos          -> Position
)

struct VectorLitNode(
    type     -> Int, // NODE_VECTOR_LIT
    elements -> Vector(Struct),
    count    -> Int,
    pos      -> Position
)

struct IndexAccessNode(
    type       -> Int, // NODE_INDEX_ACCESS
    target     -> Struct,
    index_node -> Struct,
    pos        -> Position
)

struct IndexAssignNode(
    type       -> Int, // NODE_INDEX_ASSIGN
    target     -> Struct,
    index_node -> Struct,
    value      -> Struct,
    pos        -> Position
)

struct ImportSymbolNode(
    name_tok -> Token,
    alias_tok -> Token
)

struct ImportNode(
    type       -> Int,    // NODE_IMPORT
    path_tok   -> Token,
    symbols    -> Vector(Struct),
    alias_tok  -> Token,
    pos        -> Position
)

struct ClassDefNode(
    type -> Int, // NODE_CLASS_DEF
    pos -> Position,
    name_tok -> Token,
    type_params -> Vector(Struct),
    parent_tok -> Struct,
    interfaces -> Vector(Struct),
    fields -> Vector(Struct),
    methods -> Vector(Struct),
    annotations -> Vector(Struct)
)

struct MethodDefNode(
    type -> Int, // NODE_METHOD_DEF
    pos -> Position,
    name_tok -> Token,
    type_params -> Vector(Struct),
    params -> Vector(Struct),
    return_type -> Struct,
    body -> Struct,
    is_override -> Bool,
    annotations -> Vector(Struct)
)

struct SuperNode(
    type -> Int, // NODE_SUPER
    pos  -> Position
)

struct MethodTypeNode(
    type        -> Int,    // NODE_METHOD_TYPE
    arg_types   -> Vector(Struct),
    return_type -> Struct,
    pos         -> Position
)

struct ArrayTypeNode(
    type      -> Int,    // NODE_ARRAY_TYPE
    base_type -> Struct,
    size_tok  -> Token,
    pos       -> Position
)

struct SliceTypeNode(
    type         -> Int, // NODE_SLICE_TYPE
    element_type -> Struct,
    pos          -> Position
)

struct SliceAccessNode(
    type -> Int, // NODE_SLICE_ACCESS
    target -> Struct, // data
    start_idx -> Struct,
    end_idx -> Struct,
    pos -> Position
)

struct MapPairNode(
    key   -> Struct,
    value -> Struct
)
struct MapLitNode(
    type  -> Int, // NODE_MAP_LIT
    pairs -> Vector(Struct), // MapPairNode
    pos   -> Position
)

struct AnnotationNode(
    type -> Int, // NODE_ANNOTATION
    name -> String,
    args -> Vector(Struct),
    pos  -> Position
)

struct CharNode(
    type -> Int, // NODE_CHAR
    tok  -> Token,
    pos  -> Position
)

struct EnumDefNode(
    type     -> Int, // NODE_ENUM_DEF
    name_tok -> Token,
    fields   -> Vector(Struct),
    annotations -> Vector(Struct),
    is_error -> Bool,
    pos      -> Position
)

struct EnumFieldNode(
    type     -> Int, // NODE_ENUM_FIELD
    name_tok -> Token,
    value    -> Struct, // optional explicit Int value
    pos      -> Position
)

struct TryUnwrapNode(
    type -> Int, // NODE_TRY_UNWRAP
    expr -> Struct,
    pos  -> Position
)

struct CatchNode(
    type     -> Int, // NODE_CATCH
    stmt     -> Struct,
    err_name -> Token, 
    body     -> Struct, // BlockNode
    pos      -> Position,
    alloc_id -> Int
)

struct FallibleTypeNode(
    type      -> Int, // NODE_FALLIBLE_TYPE
    base_type -> Struct,
    pos       -> Position
)

struct TypeLayoutNode(
    type -> Int, // NODE_TYPE_LAYOUT
    type_node -> Struct,
    is_align -> Bool,
    pos -> Position
)

struct InterfaceDefNode(
    type     -> Int, // NODE_INTERFACE_DEF
    name_tok -> Token,
    type_params -> Vector(Struct),
    methods  -> Vector(Struct),
    pos      -> Position
)
