// frontend/arena.wl
import * from "ast.wl"

// nodes are grouped by payload type, the handle carries the table tag and slot
struct AstArena(
    int_nodes: Vector(IntNode),
    float_nodes: Vector(FloatNode),
    binop_nodes: Vector(BinOpNode),
    unary_nodes: Vector(UnaryOpNode),
    var_decl_nodes: Vector(VarDeclareNode),
    var_access_nodes: Vector(VarAccessNode),
    var_assign_nodes: Vector(VarAssignNode),
    block_nodes: Vector(BlockNode),
    postfix_nodes: Vector(PostfixOpNode),
    bool_nodes: Vector(BooleanNode),
    if_nodes: Vector(IfNode),
    while_nodes: Vector(WhileNode),
    break_nodes: Vector(BreakNode),
    continue_nodes: Vector(ContinueNode),
    for_nodes: Vector(ForNode),
    call_nodes: Vector(CallNode),
    func_def_nodes: Vector(FunctionDefNode),
    return_nodes: Vector(ReturnNode),
    string_nodes: Vector(StringNode),
    struct_def_nodes: Vector(StructDefNode),
    field_access_nodes: Vector(FieldAccessNode),
    field_assign_nodes: Vector(FieldAssignNode),
    pointer_type_nodes: Vector(PointerTypeNode),
    ref_nodes: Vector(RefNode),
    deref_nodes: Vector(DerefNode),
    ptr_assign_nodes: Vector(PtrAssignNode),
    nullptr_nodes: Vector(NullPtrNode),
    function_type_nodes: Vector(FunctionTypeNode),
    null_nodes: Vector(NullNode),
    extern_block_nodes: Vector(ExternBlockNode),
    extern_func_nodes: Vector(ExternFuncNode),
    vector_type_nodes: Vector(VectorTypeNode),
    vector_lit_nodes: Vector(VectorLitNode),
    index_access_nodes: Vector(IndexAccessNode),
    index_assign_nodes: Vector(IndexAssignNode),
    import_nodes: Vector(ImportNode),
    class_def_nodes: Vector(ClassDefNode),
    method_def_nodes: Vector(MethodDefNode),
    super_nodes: Vector(SuperNode),
    method_type_nodes: Vector(MethodTypeNode),
    array_type_nodes: Vector(ArrayTypeNode),
    slice_type_nodes: Vector(SliceTypeNode),
    slice_access_nodes: Vector(SliceAccessNode),
    map_lit_nodes: Vector(MapLitNode),
    char_nodes: Vector(CharNode),
    enum_def_nodes: Vector(EnumDefNode),
    interface_def_nodes: Vector(InterfaceDefNode),
    try_unwrap_nodes: Vector(TryUnwrapNode),
    catch_nodes: Vector(CatchNode),
    throw_nodes: Vector(ThrowNode),
    fallible_type_nodes: Vector(FallibleTypeNode),
    type_layout_nodes: Vector(TypeLayoutNode),
    generic_type_nodes: Vector(GenericTypeNode),
    type_decl_nodes: Vector(TypeDeclNode)
)

func new_ast_arena() -> AstArena {
    return AstArena(
        int_nodes=[],
        float_nodes=[],
        binop_nodes=[],
        unary_nodes=[],
        var_decl_nodes=[],
        var_access_nodes=[],
        var_assign_nodes=[],
        block_nodes=[],
        postfix_nodes=[],
        bool_nodes=[],
        if_nodes=[],
        while_nodes=[],
        break_nodes=[],
        continue_nodes=[],
        for_nodes=[],
        call_nodes=[],
        func_def_nodes=[],
        return_nodes=[],
        string_nodes=[],
        struct_def_nodes=[],
        field_access_nodes=[],
        field_assign_nodes=[],
        pointer_type_nodes=[],
        ref_nodes=[],
        deref_nodes=[],
        ptr_assign_nodes=[],
        nullptr_nodes=[],
        function_type_nodes=[],
        null_nodes=[],
        extern_block_nodes=[],
        extern_func_nodes=[],
        vector_type_nodes=[],
        vector_lit_nodes=[],
        index_access_nodes=[],
        index_assign_nodes=[],
        import_nodes=[],
        class_def_nodes=[],
        method_def_nodes=[],
        super_nodes=[],
        method_type_nodes=[],
        array_type_nodes=[],
        slice_type_nodes=[],
        slice_access_nodes=[],
        map_lit_nodes=[],
        char_nodes=[],
        enum_def_nodes=[],
        interface_def_nodes=[],
        try_unwrap_nodes=[],
        catch_nodes=[],
        throw_nodes=[],
        fallible_type_nodes=[],
        type_layout_nodes=[],
        generic_type_nodes=[],
        type_decl_nodes=[]
    );
}

func add_int_node(arena: AstArena, node: IntNode) -> NodeID {
    let slot: Int = arena.int_nodes.length();
    arena.int_nodes.append(node);
    return make_node_id(NODE_INT, slot);
}

func get_int_node(arena: AstArena, id: NodeID) -> IntNode {
    return arena.int_nodes[node_slot(id)];
}

func add_float_node(arena: AstArena, node: FloatNode) -> NodeID {
    let slot: Int = arena.float_nodes.length();
    arena.float_nodes.append(node);
    return make_node_id(NODE_FLOAT, slot);
}

func get_float_node(arena: AstArena, id: NodeID) -> FloatNode {
    return arena.float_nodes[node_slot(id)];
}

func add_binop_node(arena: AstArena, node: BinOpNode) -> NodeID {
    let slot: Int = arena.binop_nodes.length();
    arena.binop_nodes.append(node);
    return make_node_id(node.type, slot);
}

func get_binop_node(arena: AstArena, id: NodeID) -> BinOpNode {
    return arena.binop_nodes[node_slot(id)];
}

func add_unary_node(arena: AstArena, node: UnaryOpNode) -> NodeID {
    let slot: Int = arena.unary_nodes.length();
    arena.unary_nodes.append(node);
    return make_node_id(NODE_UNARYOP, slot);
}

func get_unary_node(arena: AstArena, id: NodeID) -> UnaryOpNode {
    return arena.unary_nodes[node_slot(id)];
}

func add_var_decl_node(arena: AstArena, node: VarDeclareNode) -> NodeID {
    let slot: Int = arena.var_decl_nodes.length();
    arena.var_decl_nodes.append(node);
    return make_node_id(NODE_VAR_DECL, slot);
}

func get_var_decl_node(arena: AstArena, id: NodeID) -> VarDeclareNode {
    return arena.var_decl_nodes[node_slot(id)];
}

func add_var_access_node(arena: AstArena, node: VarAccessNode) -> NodeID {
    let slot: Int = arena.var_access_nodes.length();
    arena.var_access_nodes.append(node);
    return make_node_id(NODE_VAR_ACCESS, slot);
}

func get_var_access_node(arena: AstArena, id: NodeID) -> VarAccessNode {
    return arena.var_access_nodes[node_slot(id)];
}

func add_var_assign_node(arena: AstArena, node: VarAssignNode) -> NodeID {
    let slot: Int = arena.var_assign_nodes.length();
    arena.var_assign_nodes.append(node);
    return make_node_id(NODE_VAR_ASSIGN, slot);
}

func get_var_assign_node(arena: AstArena, id: NodeID) -> VarAssignNode {
    return arena.var_assign_nodes[node_slot(id)];
}

func add_block_node(arena: AstArena, node: BlockNode) -> NodeID {
    let slot: Int = arena.block_nodes.length();
    arena.block_nodes.append(node);
    return make_node_id(NODE_BLOCK, slot);
}

func get_block_node(arena: AstArena, id: NodeID) -> BlockNode {
    return arena.block_nodes[node_slot(id)];
}

func add_postfix_node(arena: AstArena, node: PostfixOpNode) -> NodeID {
    let slot: Int = arena.postfix_nodes.length();
    arena.postfix_nodes.append(node);
    return make_node_id(NODE_POSTFIX, slot);
}

func get_postfix_node(arena: AstArena, id: NodeID) -> PostfixOpNode {
    return arena.postfix_nodes[node_slot(id)];
}

func add_bool_node(arena: AstArena, node: BooleanNode) -> NodeID {
    let slot: Int = arena.bool_nodes.length();
    arena.bool_nodes.append(node);
    return make_node_id(NODE_BOOL, slot);
}

func get_bool_node(arena: AstArena, id: NodeID) -> BooleanNode {
    return arena.bool_nodes[node_slot(id)];
}

func add_if_node(arena: AstArena, node: IfNode) -> NodeID {
    let slot: Int = arena.if_nodes.length();
    arena.if_nodes.append(node);
    return make_node_id(NODE_IF, slot);
}

func get_if_node(arena: AstArena, id: NodeID) -> IfNode {
    return arena.if_nodes[node_slot(id)];
}

func add_while_node(arena: AstArena, node: WhileNode) -> NodeID {
    let slot: Int = arena.while_nodes.length();
    arena.while_nodes.append(node);
    return make_node_id(NODE_WHILE, slot);
}

func get_while_node(arena: AstArena, id: NodeID) -> WhileNode {
    return arena.while_nodes[node_slot(id)];
}

func add_break_node(arena: AstArena, node: BreakNode) -> NodeID {
    let slot: Int = arena.break_nodes.length();
    arena.break_nodes.append(node);
    return make_node_id(NODE_BREAK, slot);
}

func get_break_node(arena: AstArena, id: NodeID) -> BreakNode {
    return arena.break_nodes[node_slot(id)];
}

func add_continue_node(arena: AstArena, node: ContinueNode) -> NodeID {
    let slot: Int = arena.continue_nodes.length();
    arena.continue_nodes.append(node);
    return make_node_id(NODE_CONTINUE, slot);
}

func get_continue_node(arena: AstArena, id: NodeID) -> ContinueNode {
    return arena.continue_nodes[node_slot(id)];
}

func add_for_node(arena: AstArena, node: ForNode) -> NodeID {
    let slot: Int = arena.for_nodes.length();
    arena.for_nodes.append(node);
    return make_node_id(NODE_FOR, slot);
}

func get_for_node(arena: AstArena, id: NodeID) -> ForNode {
    return arena.for_nodes[node_slot(id)];
}

func add_call_node(arena: AstArena, node: CallNode) -> NodeID {
    let slot: Int = arena.call_nodes.length();
    arena.call_nodes.append(node);
    return make_node_id(NODE_CALL, slot);
}

func get_call_node(arena: AstArena, id: NodeID) -> CallNode {
    return arena.call_nodes[node_slot(id)];
}

func add_func_def_node(arena: AstArena, node: FunctionDefNode) -> NodeID {
    let slot: Int = arena.func_def_nodes.length();
    arena.func_def_nodes.append(node);
    return make_node_id(NODE_FUNC_DEF, slot);
}

func get_func_def_node(arena: AstArena, id: NodeID) -> FunctionDefNode {
    return arena.func_def_nodes[node_slot(id)];
}

func add_return_node(arena: AstArena, node: ReturnNode) -> NodeID {
    let slot: Int = arena.return_nodes.length();
    arena.return_nodes.append(node);
    return make_node_id(NODE_RETURN, slot);
}

func get_return_node(arena: AstArena, id: NodeID) -> ReturnNode {
    return arena.return_nodes[node_slot(id)];
}

func add_string_node(arena: AstArena, node: StringNode) -> NodeID {
    let slot: Int = arena.string_nodes.length();
    arena.string_nodes.append(node);
    return make_node_id(NODE_STRING, slot);
}

func get_string_node(arena: AstArena, id: NodeID) -> StringNode {
    return arena.string_nodes[node_slot(id)];
}

func add_struct_def_node(arena: AstArena, node: StructDefNode) -> NodeID {
    let slot: Int = arena.struct_def_nodes.length();
    arena.struct_def_nodes.append(node);
    return make_node_id(NODE_STRUCT_DEF, slot);
}

func get_struct_def_node(arena: AstArena, id: NodeID) -> StructDefNode {
    return arena.struct_def_nodes[node_slot(id)];
}

func add_field_access_node(arena: AstArena, node: FieldAccessNode) -> NodeID {
    let slot: Int = arena.field_access_nodes.length();
    arena.field_access_nodes.append(node);
    return make_node_id(NODE_FIELD_ACCESS, slot);
}

func get_field_access_node(arena: AstArena, id: NodeID) -> FieldAccessNode {
    return arena.field_access_nodes[node_slot(id)];
}

func add_field_assign_node(arena: AstArena, node: FieldAssignNode) -> NodeID {
    let slot: Int = arena.field_assign_nodes.length();
    arena.field_assign_nodes.append(node);
    return make_node_id(NODE_FIELD_ASSIGN, slot);
}

func get_field_assign_node(arena: AstArena, id: NodeID) -> FieldAssignNode {
    return arena.field_assign_nodes[node_slot(id)];
}

func add_pointer_type_node(arena: AstArena, node: PointerTypeNode) -> NodeID {
    let slot: Int = arena.pointer_type_nodes.length();
    arena.pointer_type_nodes.append(node);
    return make_node_id(NODE_PTR_TYPE, slot);
}

func get_pointer_type_node(arena: AstArena, id: NodeID) -> PointerTypeNode {
    return arena.pointer_type_nodes[node_slot(id)];
}

func add_ref_node(arena: AstArena, node: RefNode) -> NodeID {
    let slot: Int = arena.ref_nodes.length();
    arena.ref_nodes.append(node);
    return make_node_id(NODE_REF, slot);
}

func get_ref_node(arena: AstArena, id: NodeID) -> RefNode {
    return arena.ref_nodes[node_slot(id)];
}

func add_deref_node(arena: AstArena, node: DerefNode) -> NodeID {
    let slot: Int = arena.deref_nodes.length();
    arena.deref_nodes.append(node);
    return make_node_id(NODE_DEREF, slot);
}

func get_deref_node(arena: AstArena, id: NodeID) -> DerefNode {
    return arena.deref_nodes[node_slot(id)];
}

func add_ptr_assign_node(arena: AstArena, node: PtrAssignNode) -> NodeID {
    let slot: Int = arena.ptr_assign_nodes.length();
    arena.ptr_assign_nodes.append(node);
    return make_node_id(NODE_PTR_ASSIGN, slot);
}

func get_ptr_assign_node(arena: AstArena, id: NodeID) -> PtrAssignNode {
    return arena.ptr_assign_nodes[node_slot(id)];
}

func add_nullptr_node(arena: AstArena, node: NullPtrNode) -> NodeID {
    let slot: Int = arena.nullptr_nodes.length();
    arena.nullptr_nodes.append(node);
    return make_node_id(NODE_NULLPTR, slot);
}

func get_nullptr_node(arena: AstArena, id: NodeID) -> NullPtrNode {
    return arena.nullptr_nodes[node_slot(id)];
}

func add_function_type_node(arena: AstArena, node: FunctionTypeNode) -> NodeID {
    let slot: Int = arena.function_type_nodes.length();
    arena.function_type_nodes.append(node);
    return make_node_id(NODE_FUNCTION_TYPE, slot);
}

func get_function_type_node(arena: AstArena, id: NodeID) -> FunctionTypeNode {
    return arena.function_type_nodes[node_slot(id)];
}

func add_null_node(arena: AstArena, node: NullNode) -> NodeID {
    let slot: Int = arena.null_nodes.length();
    arena.null_nodes.append(node);
    return make_node_id(NODE_NULL, slot);
}

func get_null_node(arena: AstArena, id: NodeID) -> NullNode {
    return arena.null_nodes[node_slot(id)];
}

func add_extern_block_node(arena: AstArena, node: ExternBlockNode) -> NodeID {
    let slot: Int = arena.extern_block_nodes.length();
    arena.extern_block_nodes.append(node);
    return make_node_id(NODE_EXTERN_BLOCK, slot);
}

func get_extern_block_node(arena: AstArena, id: NodeID) -> ExternBlockNode {
    return arena.extern_block_nodes[node_slot(id)];
}

func add_extern_func_node(arena: AstArena, node: ExternFuncNode) -> NodeID {
    let slot: Int = arena.extern_func_nodes.length();
    arena.extern_func_nodes.append(node);
    return make_node_id(NODE_EXTERN_FUNC, slot);
}

func get_extern_func_node(arena: AstArena, id: NodeID) -> ExternFuncNode {
    return arena.extern_func_nodes[node_slot(id)];
}

func add_vector_type_node(arena: AstArena, node: VectorTypeNode) -> NodeID {
    let slot: Int = arena.vector_type_nodes.length();
    arena.vector_type_nodes.append(node);
    return make_node_id(NODE_VECTOR_TYPE, slot);
}

func get_vector_type_node(arena: AstArena, id: NodeID) -> VectorTypeNode {
    return arena.vector_type_nodes[node_slot(id)];
}

func add_vector_lit_node(arena: AstArena, node: VectorLitNode) -> NodeID {
    let slot: Int = arena.vector_lit_nodes.length();
    arena.vector_lit_nodes.append(node);
    return make_node_id(NODE_VECTOR_LIT, slot);
}

func get_vector_lit_node(arena: AstArena, id: NodeID) -> VectorLitNode {
    return arena.vector_lit_nodes[node_slot(id)];
}

func add_index_access_node(arena: AstArena, node: IndexAccessNode) -> NodeID {
    let slot: Int = arena.index_access_nodes.length();
    arena.index_access_nodes.append(node);
    return make_node_id(NODE_INDEX_ACCESS, slot);
}

func get_index_access_node(arena: AstArena, id: NodeID) -> IndexAccessNode {
    return arena.index_access_nodes[node_slot(id)];
}

func add_index_assign_node(arena: AstArena, node: IndexAssignNode) -> NodeID {
    let slot: Int = arena.index_assign_nodes.length();
    arena.index_assign_nodes.append(node);
    return make_node_id(NODE_INDEX_ASSIGN, slot);
}

func get_index_assign_node(arena: AstArena, id: NodeID) -> IndexAssignNode {
    return arena.index_assign_nodes[node_slot(id)];
}

func add_import_node(arena: AstArena, node: ImportNode) -> NodeID {
    let slot: Int = arena.import_nodes.length();
    arena.import_nodes.append(node);
    return make_node_id(NODE_IMPORT, slot);
}

func get_import_node(arena: AstArena, id: NodeID) -> ImportNode {
    return arena.import_nodes[node_slot(id)];
}

func add_class_def_node(arena: AstArena, node: ClassDefNode) -> NodeID {
    let slot: Int = arena.class_def_nodes.length();
    arena.class_def_nodes.append(node);
    return make_node_id(NODE_CLASS_DEF, slot);
}

func get_class_def_node(arena: AstArena, id: NodeID) -> ClassDefNode {
    return arena.class_def_nodes[node_slot(id)];
}

func add_method_def_node(arena: AstArena, node: MethodDefNode) -> NodeID {
    let slot: Int = arena.method_def_nodes.length();
    arena.method_def_nodes.append(node);
    return make_node_id(NODE_METHOD_DEF, slot);
}

func get_method_def_node(arena: AstArena, id: NodeID) -> MethodDefNode {
    return arena.method_def_nodes[node_slot(id)];
}

func add_super_node(arena: AstArena, node: SuperNode) -> NodeID {
    let slot: Int = arena.super_nodes.length();
    arena.super_nodes.append(node);
    return make_node_id(NODE_SUPER, slot);
}

func get_super_node(arena: AstArena, id: NodeID) -> SuperNode {
    return arena.super_nodes[node_slot(id)];
}

func add_method_type_node(arena: AstArena, node: MethodTypeNode) -> NodeID {
    let slot: Int = arena.method_type_nodes.length();
    arena.method_type_nodes.append(node);
    return make_node_id(NODE_METHOD_TYPE, slot);
}

func get_method_type_node(arena: AstArena, id: NodeID) -> MethodTypeNode {
    return arena.method_type_nodes[node_slot(id)];
}

func add_array_type_node(arena: AstArena, node: ArrayTypeNode) -> NodeID {
    let slot: Int = arena.array_type_nodes.length();
    arena.array_type_nodes.append(node);
    return make_node_id(NODE_ARRAY_TYPE, slot);
}

func get_array_type_node(arena: AstArena, id: NodeID) -> ArrayTypeNode {
    return arena.array_type_nodes[node_slot(id)];
}

func add_slice_type_node(arena: AstArena, node: SliceTypeNode) -> NodeID {
    let slot: Int = arena.slice_type_nodes.length();
    arena.slice_type_nodes.append(node);
    return make_node_id(NODE_SLICE_TYPE, slot);
}

func get_slice_type_node(arena: AstArena, id: NodeID) -> SliceTypeNode {
    return arena.slice_type_nodes[node_slot(id)];
}

func add_slice_access_node(arena: AstArena, node: SliceAccessNode) -> NodeID {
    let slot: Int = arena.slice_access_nodes.length();
    arena.slice_access_nodes.append(node);
    return make_node_id(NODE_SLICE_ACCESS, slot);
}

func get_slice_access_node(arena: AstArena, id: NodeID) -> SliceAccessNode {
    return arena.slice_access_nodes[node_slot(id)];
}

func add_map_lit_node(arena: AstArena, node: MapLitNode) -> NodeID {
    let slot: Int = arena.map_lit_nodes.length();
    arena.map_lit_nodes.append(node);
    return make_node_id(NODE_MAP_LIT, slot);
}

func get_map_lit_node(arena: AstArena, id: NodeID) -> MapLitNode {
    return arena.map_lit_nodes[node_slot(id)];
}

func add_char_node(arena: AstArena, node: CharNode) -> NodeID {
    let slot: Int = arena.char_nodes.length();
    arena.char_nodes.append(node);
    return make_node_id(NODE_CHAR, slot);
}

func get_char_node(arena: AstArena, id: NodeID) -> CharNode {
    return arena.char_nodes[node_slot(id)];
}

func add_enum_def_node(arena: AstArena, node: EnumDefNode) -> NodeID {
    let slot: Int = arena.enum_def_nodes.length();
    arena.enum_def_nodes.append(node);
    return make_node_id(NODE_ENUM_DEF, slot);
}

func get_enum_def_node(arena: AstArena, id: NodeID) -> EnumDefNode {
    return arena.enum_def_nodes[node_slot(id)];
}

func add_interface_def_node(arena: AstArena, node: InterfaceDefNode) -> NodeID {
    let slot: Int = arena.interface_def_nodes.length();
    arena.interface_def_nodes.append(node);
    return make_node_id(NODE_INTERFACE_DEF, slot);
}

func get_interface_def_node(arena: AstArena, id: NodeID) -> InterfaceDefNode {
    return arena.interface_def_nodes[node_slot(id)];
}

func add_try_unwrap_node(arena: AstArena, node: TryUnwrapNode) -> NodeID {
    let slot: Int = arena.try_unwrap_nodes.length();
    arena.try_unwrap_nodes.append(node);
    return make_node_id(NODE_TRY_UNWRAP, slot);
}

func get_try_unwrap_node(arena: AstArena, id: NodeID) -> TryUnwrapNode {
    return arena.try_unwrap_nodes[node_slot(id)];
}

func add_catch_node(arena: AstArena, node: CatchNode) -> NodeID {
    let slot: Int = arena.catch_nodes.length();
    arena.catch_nodes.append(node);
    return make_node_id(NODE_CATCH, slot);
}

func get_catch_node(arena: AstArena, id: NodeID) -> CatchNode {
    return arena.catch_nodes[node_slot(id)];
}

func add_throw_node(arena: AstArena, node: ThrowNode) -> NodeID {
    let slot: Int = arena.throw_nodes.length();
    arena.throw_nodes.append(node);
    return make_node_id(NODE_THROW, slot);
}

func get_throw_node(arena: AstArena, id: NodeID) -> ThrowNode {
    return arena.throw_nodes[node_slot(id)];
}

func add_fallible_type_node(arena: AstArena, node: FallibleTypeNode) -> NodeID {
    let slot: Int = arena.fallible_type_nodes.length();
    arena.fallible_type_nodes.append(node);
    return make_node_id(NODE_FALLIBLE_TYPE, slot);
}

func get_fallible_type_node(arena: AstArena, id: NodeID) -> FallibleTypeNode {
    return arena.fallible_type_nodes[node_slot(id)];
}

func add_type_layout_node(arena: AstArena, node: TypeLayoutNode) -> NodeID {
    let slot: Int = arena.type_layout_nodes.length();
    arena.type_layout_nodes.append(node);
    return make_node_id(NODE_TYPE_LAYOUT, slot);
}

func get_type_layout_node(arena: AstArena, id: NodeID) -> TypeLayoutNode {
    return arena.type_layout_nodes[node_slot(id)];
}

func add_generic_type_node(arena: AstArena, node: GenericTypeNode) -> NodeID {
    let slot: Int = arena.generic_type_nodes.length();
    arena.generic_type_nodes.append(node);
    return make_node_id(NODE_GENERIC_TYPE, slot);
}

func get_generic_type_node(arena: AstArena, id: NodeID) -> GenericTypeNode {
    return arena.generic_type_nodes[node_slot(id)];
}

func add_type_decl_node(arena: AstArena, node: TypeDeclNode) -> NodeID {
    let slot: Int = arena.type_decl_nodes.length();
    arena.type_decl_nodes.append(node);
    return make_node_id(NODE_TYPE_DECL, slot);
}

func get_type_decl_node(arena: AstArena, id: NodeID) -> TypeDeclNode {
    return arena.type_decl_nodes[node_slot(id)];
}
