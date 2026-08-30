// Test: WIR_CLASSES
// File: tests/integration/tooling/test_wir_classes.wl
// Focus: Lowering class and interface dispatch without object-specific WIR instructions.

import * from "../../../src/compiler/context.wl"
import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import * from "../../../src/frontend/tokens.wl"
import Position from "../../../src/frontend/diagnostics.wl"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/lowering/module.wl"
import wir_find_function from "../../../src/compiler/wir/lowering/declarations.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func class_token(value: String) -> Token {
    return Token(type=TOK_IDENTIFIER, value=value, line=1, col=1);
}

func main() -> Int {
    let arena: AstArena = new_ast_arena();
    let pos: Position = Position(idx=0, ln=1, col=1, text="", fn="memory.wl");
    let structs: Dict(String, StructInfo) = Dict();
    let struct_ids: Dict(String, StructInfo) = Dict();
    let functions: Dict(String, FuncInfo) = Dict();
    let int_type_node: NodeID = add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=class_token("Int"), pos=pos));
    let interface_method: MethodDefNode = MethodDefNode(type=NODE_METHOD_DEF, pos=pos, name_tok=class_token("get_value"), type_params=[], params=[], return_type=int_type_node, body=NO_NODE, is_override=false, annotations=[]);
    let interface_info: StructInfo = StructInfo(name="Reader", type_id=101, fields=[], llvm_name="", init_body=NO_NODE, is_class=false, is_enum=false, is_interface=true, vtable=[interface_method], interfaces=[]);
    let fields: Vector(Struct) = [
        FieldInfo(name="_vptr", type=TYPE_VOID, llvm_type="", offset=0, is_const=true),
        FieldInfo(name="value", type=TYPE_INT, llvm_type="", offset=1, is_const=false),
        FieldInfo(name="name", type=TYPE_STRING, llvm_type="", offset=2, is_const=false)
    ];
    let class_info: StructInfo = StructInfo(name="Box", type_id=100, fields=fields, llvm_name="", init_body=NO_NODE, is_class=true, is_enum=false, is_interface=false, vtable=[], interfaces=[TypeListNode(type=101)]);
    let args: Vector(Struct) = [TypeListNode(type=100, pass_mode=PARAM_VALUE)];
    let method_info: FuncInfo = FuncInfo(name="Box.get_value", base_name="get_value", ret_type=TYPE_INT, arg_types=args, arg_names=["self"], is_varargs=false, abi_name="");
    let read_info: FuncInfo = FuncInfo(name="read", base_name="read", ret_type=TYPE_INT, arg_types=args, arg_names=["box"], is_varargs=false, abi_name="");
    let interface_args: Vector(Struct) = [TypeListNode(type=101, pass_mode=PARAM_VALUE)];
    let read_interface_info: FuncInfo = FuncInfo(name="read_interface", base_name="read_interface", ret_type=TYPE_INT, arg_types=interface_args, arg_names=["reader"], is_varargs=false, abi_name="");
    let make_box_info: FuncInfo = FuncInfo(name="make_box", base_name="make_box", ret_type=100, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    let make_reader_info: FuncInfo = FuncInfo(name="make_reader", base_name="make_reader", ret_type=101, arg_types=[], arg_names=[], is_varargs=false, abi_name="");
    let allocator_info: FuncInfo = FuncInfo(name="memory_alloc", base_name="memory_alloc", ret_type=TYPE_ANYPTR, arg_types=[TypeListNode(type=TYPE_UINTSIZE, pass_mode=PARAM_VALUE)], arg_names=["size"], is_varargs=false, abi_name="C");
    class_info.vtable.append(method_info);
    structs.put("Box", class_info);
    structs.put("Reader", interface_info);
    struct_ids.put("100", class_info);
    struct_ids.put("101", interface_info);
    functions.put("Box_get_value", method_info);
    functions.put("read", read_info);
    functions.put("read_interface", read_interface_info);
    functions.put("make_box", make_box_info);
    functions.put("make_reader", make_reader_info);
    functions.put("memory_alloc", allocator_info);

    let self_node: NodeID = add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=class_token("self"), pos=pos));
    let field_node: NodeID = add_field_access_node(arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=self_node, field_name="value", pos=pos));
    let return_node: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=field_node, pos=pos));
    let body: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[return_node]));
    let method_node: NodeID = add_method_def_node(arena, MethodDefNode(type=NODE_METHOD_DEF, pos=pos, name_tok=class_token("get_value"), type_params=[], params=[], return_type=int_type_node, body=body, is_override=false, annotations=[]));
    let class_node: NodeID = add_class_def_node(arena, ClassDefNode(type=NODE_CLASS_DEF, pos=pos, name_tok=class_token("Box"), type_params=[], parent_tok=NO_NODE, interfaces=[], fields=[], methods=[method_node], annotations=[]));
    let box_node: NodeID = add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=class_token("box"), pos=pos));
    let callee: NodeID = add_field_access_node(arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=box_node, field_name="get_value", pos=pos));
    let call: NodeID = add_call_node(arena, CallNode(type=NODE_CALL, callee=callee, args=[], type_args=[], pos=pos, preserve_fallible=false));
    let read_return: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=call, pos=pos));
    let read_body: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[read_return]));
    let box_type: NodeID = add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=class_token("Box"), pos=pos));
    let box_param: ParamNode = ParamNode(type=NODE_PARAM, name_tok=class_token("box"), type_tok=box_type, pos=pos, pass_mode=PARAM_VALUE, is_variadic=false, default_val=NO_NODE);
    let read_node: NodeID = add_func_def_node(arena, FunctionDefNode(type=NODE_FUNC_DEF, name_tok=class_token("read"), type_params=[], params=[box_param], ret_type_tok=int_type_node, body=read_body, annotations=[], pos=pos));
    let reader_node: NodeID = add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=class_token("reader"), pos=pos));
    let interface_callee: NodeID = add_field_access_node(arena, FieldAccessNode(type=NODE_FIELD_ACCESS, obj=reader_node, field_name="get_value", pos=pos));
    let interface_call: NodeID = add_call_node(arena, CallNode(type=NODE_CALL, callee=interface_callee, args=[], type_args=[], pos=pos, preserve_fallible=false));
    let interface_return: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=interface_call, pos=pos));
    let interface_body: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[interface_return]));
    let reader_type: NodeID = add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=class_token("Reader"), pos=pos));
    let reader_param: ParamNode = ParamNode(type=NODE_PARAM, name_tok=class_token("reader"), type_tok=reader_type, pos=pos, pass_mode=PARAM_VALUE, is_variadic=false, default_val=NO_NODE);
    let read_interface_node: NodeID = add_func_def_node(arena, FunctionDefNode(type=NODE_FUNC_DEF, name_tok=class_token("read_interface"), type_params=[], params=[reader_param], ret_type_tok=int_type_node, body=interface_body, annotations=[], pos=pos));
    let constructor_name: NodeID = add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=class_token("Box"), pos=pos));
    let constructor_call: NodeID = add_call_node(arena, CallNode(type=NODE_CALL, callee=constructor_name, args=[], type_args=[], pos=pos, preserve_fallible=false));
    let make_box_return: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=constructor_call, pos=pos));
    let make_box_body: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[make_box_return]));
    let make_box_node: NodeID = add_func_def_node(arena, FunctionDefNode(type=NODE_FUNC_DEF, name_tok=class_token("make_box"), type_params=[], params=[], ret_type_tok=box_type, body=make_box_body, annotations=[], pos=pos));
    let interface_constructor_name: NodeID = add_var_access_node(arena, VarAccessNode(type=NODE_VAR_ACCESS, name_tok=class_token("Box"), pos=pos));
    let interface_constructor_call: NodeID = add_call_node(arena, CallNode(type=NODE_CALL, callee=interface_constructor_name, args=[], type_args=[], pos=pos, preserve_fallible=false));
    let make_reader_return: NodeID = add_return_node(arena, ReturnNode(type=NODE_RETURN, value=interface_constructor_call, pos=pos));
    let make_reader_body: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[make_reader_return]));
    let make_reader_node: NodeID = add_func_def_node(arena, FunctionDefNode(type=NODE_FUNC_DEF, name_tok=class_token("make_reader"), type_params=[], params=[], ret_type_tok=reader_type, body=make_reader_body, annotations=[], pos=pos));
    let root: NodeID = add_block_node(arena, BlockNode(type=NODE_BLOCK, stmts=[class_node, read_node, read_interface_node, make_box_node, make_reader_node]));
    let modules: Vector(ParsedModule) = [ParsedModule(path="memory.wl", prefix="", dir="", is_package=false, ast=root, visible=Dict(), namespaces=Dict(), types=Dict(), funcs=Dict(), globals=Dict(), imports=[])];
    let links: Dict(String, String) = Dict();
    links.put("memory_alloc", "memory_alloc");
    let source: Compiler = Compiler(arena=arena, struct_table=structs, struct_id_map=struct_ids, func_table=functions, compiler_link=links, ptr_base_map=Dict(), array_info_map=Dict(), vector_base_map=Dict(), fallible_base_map=Dict(), func_ret_map=Dict(), method_ret_map=Dict(), named_type_ids=Dict(), generic_bindings=Dict(), generic_instance_templates=Dict(), generic_instance_bindings=Dict(), current_file_visible_prefixes=Dict(), current_file_type_aliases=Dict(), current_file_func_aliases=Dict(), current_file_global_aliases=Dict(), global_var_aliases=Dict(), global_symbol_table=Dict());
    let result: WirLoweringResult = wir_lower_program(ref source, modules, "x86_64-pc-windows-msvc", 64);
    if (result.errors.length() != 0) {
        print("FAIL: class method lowering failed: ", result.errors[0]);
        return 1;
    }
    if (result.program.arena.functions.length() < 7 || result.program.arena.functions[0].blocks.length() == 0 || result.program.arena.globals.length() != 2) {
        print("FAIL: class method was not emitted as a WIR function");
        return 1;
    }
    let saw_field_address: Bool = false;
    let saw_interface_value: Bool = false;
    let saw_field_release: Bool = false;
    let released_method_self: Bool = false;
    let allocation_calls: Int = 0;
    let indirect_calls: Int = 0;
    let method_id: WirFuncID = wir_find_function(result.program, "Box.get_value");
    let method_self: WirValueID = result.program.arena.functions[wir_id_index(UInt32(method_id))].parameters[0];
    let i: Int = 0;
    while (i < result.program.arena.instructions.length()) {
        if (result.program.arena.instructions[i].opcode == WirOpcode.FieldAddress) { saw_field_address = true; }
        if (result.program.arena.instructions[i].opcode == WirOpcode.StructValue) { saw_interface_value = true; }
        if (result.program.arena.instructions[i].opcode == WirOpcode.Release) {
            saw_field_release = true;
            if (result.program.arena.instructions[i].operands[0] == method_self) { released_method_self = true; }
        }
        if (result.program.arena.instructions[i].opcode == WirOpcode.Call) {
            let instruction: WirInstruction = result.program.arena.instructions[i];
            let callee_value: WirValue = result.program.arena.values[wir_id_index(UInt32(instruction.operands[0]))];
            if (callee_value.kind == WirValueKind.Instruction && instruction.call_type != NO_WIR_TYPE) { indirect_calls++; }
            if (callee_value.kind == WirValueKind.Function && callee_value.name == "memory_alloc") { allocation_calls++; }
        }
        i++;
    }
    if (!saw_field_address) {
        print("FAIL: class field access did not lower to an address operation");
        return 1;
    }
    if (indirect_calls != 2) {
        print("FAIL: class and interface calls did not lower through loaded code addresses");
        return 1;
    }
    if (allocation_calls != 2 || !saw_interface_value || !saw_field_release || wir_find_function(result.program, "__wl_drop.100") == NO_WIR_FUNC) {
        print("FAIL: class construction or interface conversion did not lower to primitive WIR");
        return 1;
    }
    if (released_method_self) {
        print("FAIL: class method released its borrowed self parameter");
        return 1;
    }
    let emitted: WirLLVMResult = emit_wir_llvm(result.program)?;
    catch(err) {
        print("FAIL: class WIR could not be emitted as LLVM IR");
        return 1;
    }
    if (emitted.errors.length() != 0) {
        print("FAIL: LLVM rejected class WIR: ", emitted.errors[0]);
        return 1;
    }
    print("PASS: WIR class and interface lowering");
    return 0;
}
