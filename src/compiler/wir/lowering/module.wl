// compiler/wir/lowering/module.wl
import * from "../model.wl"
import * from "../builder.wl"
import * from "../verify.wl"
import * from "types.wl"
import * from "declarations.wl"
import * from "globals.wl"
import * from "functions.wl"
import * from "../../context.wl"
import find_interface_implementation from "../../analysis.wl"
import * from "../../../frontend/ast.wl"
import * from "../../../frontend/arena.wl"

struct WirLoweringResult(
    program: WirModule,
    errors: Vector(String)
)

func wir_definition_info(ref source: Compiler, node: FunctionDefNode) -> FuncInfo {
    let key: String = node.name_tok.value;
    if (key != "main") { key = source.current_package_prefix + key; }
    return source.func_table.lookup(key);
}

func wir_extern_info(ref source: Compiler, node: ExternFuncNode) -> FuncInfo {
    let key: String = source.current_package_prefix + node.name_tok.value;
    let info: FuncInfo = source.func_table.lookup(key);
    if (!has_func(info)) { info = source.func_table.lookup(node.name_tok.value); }
    return info;
}

func wir_declare_extern(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: ExternFuncNode) -> Void {
    let info: FuncInfo = wir_extern_info(ref source, node);
    if (!has_func(info)) {
        types.errors.append("Extern function '" + node.name_tok.value + "' was not registered before WIR lowering");
        return;
    }
    wir_lower_function_decl(ref types, ref source, ref program, info);
}

func wir_class_name(source: Compiler, node: ClassDefNode) -> String {
    return source.current_package_prefix + node.name_tok.value;
}

func wir_method_info(ref source: Compiler, class_name: String, node: MethodDefNode) -> FuncInfo {
    return source.func_table.lookup(class_name + "_" + method_base_name(ref source, node));
}

func wir_declare_class_methods(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: ClassDefNode) -> Void {
    if (node.type_params is !null && node.type_params.length() != 0) { return; }
    let class_name: String = wir_class_name(source, node);
    let i: Int = 0;
    while (node.methods is !null && i < node.methods.length()) {
        let method_node: MethodDefNode = get_method_def_node(source.arena, node.methods[i]);
        if (method_node.type_params is null || method_node.type_params.length() == 0) {
            let info: FuncInfo = wir_method_info(ref source, class_name, method_node);
            if (!has_func(info)) {
                types.errors.append("Method '" + class_name + "." + method_base_name(ref source, method_node) + "' was not registered before WIR lowering");
            } else if (info.compiler_link_name is null || info.compiler_link_name.length() == 0) {
                wir_lower_function_decl(ref types, ref source, ref program, info);
            }
        }
        i++;
    }
}

func wir_lower_class_methods(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: ClassDefNode) -> Void {
    if (node.type_params is !null && node.type_params.length() != 0) { return; }
    let class_name: String = wir_class_name(source, node);
    let i: Int = 0;
    while (node.methods is !null && i < node.methods.length()) {
        let method_node: MethodDefNode = get_method_def_node(source.arena, node.methods[i]);
        if (method_node.type_params is null || method_node.type_params.length() == 0) {
            let info: FuncInfo = wir_method_info(ref source, class_name, method_node);
            if (has_func(info) && (info.ann_flags & FLAG_ANN_INTRINSIC) == 0 && (info.compiler_link_name is null || info.compiler_link_name.length() == 0)) {
                wir_lower_function_body(ref types, ref source, ref program, info, method_node.body);
            }
        }
        i++;
    }
}

func wir_emit_class_vtable(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: ClassDefNode) -> Void {
    if (node.type_params is !null && node.type_params.length() != 0) { return; }
    let info: StructInfo = source.struct_table.lookup(wir_class_name(source, node));
    if (!has_struct(info) || !info.is_class) { return; }
    let name: String = wir_class_vtable_name(info);
    if (wir_find_global(program, name) != NO_WIR_GLOBAL) { return; }

    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let entries: Vector(WirValueID) = [];
    let i: Int = 0;
    while (info.vtable is !null && i < info.vtable.length()) {
        let method_info: FuncInfo = info.vtable[i];
        let function_id: WirFuncID = wir_find_function(program, method_info.name);
        if (function_id == NO_WIR_FUNC) { function_id = wir_lower_function_decl(ref types, ref source, ref program, method_info); }
        if (function_id == NO_WIR_FUNC) {
            types.errors.append("Vtable entry '" + info.name + "." + method_info.base_name + "' has no WIR function");
            return;
        }
        entries.append(wir_const_address(ref program, raw_pointer, wir_function_value(program, function_id), 0L));
        i++;
    }
    let table_type: WirTypeID = wir_dispatch_table_type(ref types, ref program, entries.length());
    let initializer: WirValueID = wir_const_aggregate(ref program, table_type, entries);
    wir_add_global(ref program, name, table_type, initializer, WirLinkage.Internal, true);
}

func wir_emit_interface_tables(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: ClassDefNode) -> Void {
    if (node.type_params is !null && node.type_params.length() != 0) { return; }
    let info: StructInfo = source.struct_table.lookup(wir_class_name(source, node));
    if (!has_struct(info) || !info.is_class) { return; }
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let interface_index: Int = 0;
    while (info.interfaces is !null && interface_index < info.interfaces.length()) {
        let interface_type: TypeListNode = info.interfaces[interface_index];
        let interface_info: StructInfo = source.struct_id_map.lookup("" + interface_type.type);
        if (!has_struct(interface_info) || !interface_info.is_interface) {
            types.errors.append("Class '" + info.name + "' contains an invalid interface entry");
            return;
        }
        let name: String = wir_interface_table_name(info, interface_info);
        if (wir_find_global(program, name) == NO_WIR_GLOBAL) {
            let entries: Vector(WirValueID) = [];
            let method_index: Int = 0;
            while (interface_info.vtable is !null && method_index < interface_info.vtable.length()) {
                let required: MethodDefNode = interface_info.vtable[method_index];
                let implementation: FuncInfo = find_interface_implementation(ref source, info, interface_info, required);
                let function_id: WirFuncID = NO_WIR_FUNC;
                if (has_func(implementation)) { function_id = wir_find_function(program, implementation.name); }
                if (function_id == NO_WIR_FUNC && has_func(implementation)) { function_id = wir_lower_function_decl(ref types, ref source, ref program, implementation); }
                if (function_id == NO_WIR_FUNC) {
                    types.errors.append("Interface method '" + interface_info.name + "." + required.name_tok.value + "' has no WIR implementation");
                    return;
                }
                entries.append(wir_const_address(ref program, raw_pointer, wir_function_value(program, function_id), 0L));
                method_index++;
            }
            let table_type: WirTypeID = wir_dispatch_table_type(ref types, ref program, entries.length());
            wir_add_global(ref program, name, table_type, wir_const_aggregate(ref program, table_type, entries), WirLinkage.Internal, true);
        }
        interface_index++;
    }
}

func wir_declare_root_functions(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, root: BlockNode) -> Void {
    let i: Int = 0;
    while (i < root.stmts.length()) {
        let node: NodeID = root.stmts[i];
        let kind: Int = node_tag(node);
        if (kind == NODE_FUNC_DEF) {
            let definition: FunctionDefNode = get_func_def_node(source.arena, node);
            if (definition.type_params is null || definition.type_params.length() == 0) {
                let info: FuncInfo = wir_definition_info(ref source, definition);
                if (!has_func(info)) {
                    types.errors.append("Function '" + definition.name_tok.value + "' was not registered before WIR lowering");
                } else {
                    wir_lower_function_decl(ref types, ref source, ref program, info);
                }
            }
        } else if (kind == NODE_EXTERN_FUNC) {
            wir_declare_extern(ref types, ref source, ref program, get_extern_func_node(source.arena, node));
        } else if (kind == NODE_EXTERN_BLOCK) {
            let block: ExternBlockNode = get_extern_block_node(source.arena, node);
            let function_index: Int = 0;
            while (function_index < block.funcs.length()) {
                wir_declare_extern(ref types, ref source, ref program, get_extern_func_node(source.arena, block.funcs[function_index]));
                function_index++;
            }
        } else if (kind == NODE_CLASS_DEF) {
            let class_node: ClassDefNode = get_class_def_node(source.arena, node);
            wir_declare_class_methods(ref types, ref source, ref program, class_node);
            wir_emit_class_vtable(ref types, ref source, ref program, class_node);
            wir_emit_interface_tables(ref types, ref source, ref program, class_node);
        }
        i++;
    }
}

func wir_lower_root_items(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, root: BlockNode) -> Void {
    let i: Int = 0;
    while (i < root.stmts.length()) {
        let node: NodeID = root.stmts[i];
        let kind: Int = node_tag(node);
        if (kind == NODE_VAR_DECL) {
            wir_lower_global_decl(ref types, ref source, ref program, get_var_decl_node(source.arena, node));
        } else if (kind == NODE_FUNC_DEF) {
            let definition: FunctionDefNode = get_func_def_node(source.arena, node);
            if (definition.type_params is null || definition.type_params.length() == 0) {
                let info: FuncInfo = wir_definition_info(ref source, definition);
                if (has_func(info) && (info.ann_flags & FLAG_ANN_INTRINSIC) == 0) {
                    wir_lower_function_body(ref types, ref source, ref program, info, definition.body);
                }
            }
        } else if (kind == NODE_CLASS_DEF) {
            wir_lower_class_methods(ref types, ref source, ref program, get_class_def_node(source.arena, node));
        }
        i++;
    }
}

func wir_verify_lowering(ref types: WirTypeMap, program: WirModule) -> Void {
    if (types.errors.length() != 0) { return; }
    let verify_errors: Vector(String) = verify_wir(program);
    let i: Int = 0;
    while (i < verify_errors.length()) {
        types.errors.append(verify_errors[i]);
        i++;
    }
}

func wir_lower_program(ref source: Compiler, modules: Vector(ParsedModule), target: String, pointer_bits: Int) -> WirLoweringResult {
    let program: WirModule = new_wir_module(target, pointer_bits);
    let types: WirTypeMap = new_wir_type_map();

    let i: Int = 0;
    while (i < modules.length()) {
        let module: ParsedModule = modules[i];
        set_module_context(ref source, module);
        if (!has_node(module.ast) || node_tag(module.ast) != NODE_BLOCK) {
            types.errors.append("Module '" + module.path + "' has no root block");
        } else {
            wir_declare_root_functions(ref types, ref source, ref program, get_block_node(source.arena, module.ast));
        }
        i++;
    }

    i = 0;
    while (i < modules.length()) {
        let module: ParsedModule = modules[i];
        set_module_context(ref source, module);
        if (has_node(module.ast) && node_tag(module.ast) == NODE_BLOCK) {
            wir_lower_root_items(ref types, ref source, ref program, get_block_node(source.arena, module.ast));
        }
        i++;
    }

    wir_verify_lowering(ref types, program);
    return WirLoweringResult(program=program, errors=types.errors);
}

func wir_lower_module(ref source: Compiler, root_node: NodeID, target: String, pointer_bits: Int) -> WirLoweringResult {
    let program: WirModule = new_wir_module(target, pointer_bits);
    let types: WirTypeMap = new_wir_type_map();
    if (!has_node(root_node) || node_tag(root_node) != NODE_BLOCK) {
        types.errors.append("WIR module root is not a block");
        return WirLoweringResult(program=program, errors=types.errors);
    }

    let root: BlockNode = get_block_node(source.arena, root_node);
    wir_declare_root_functions(ref types, ref source, ref program, root);
    wir_lower_root_items(ref types, ref source, ref program, root);
    wir_verify_lowering(ref types, program);
    return WirLoweringResult(program=program, errors=types.errors);
}
