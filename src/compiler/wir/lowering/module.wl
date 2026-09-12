// compiler/wir/lowering/module.wl
import * from "../model.wl"
import * from "../builder.wl"
import * from "../verify.wl"
import * from "types.wl"
import * from "declarations.wl"
import * from "globals.wl"
import * from "functions.wl"
import * from "ownership_runtime.wl"
import * from "target_runtime.wl"
import * from "../../context.wl"
import find_interface_implementation from "../../analysis.wl"
import eval_const_long from "../../constants.wl"
import select_target from "../../target.wl"
import register_extern_library from "../../validation.wl"
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
    if (has_func(info)) { return info; }

    let return_type: Int = resolve_type(ref source, node.ret_type_tok);
    if (return_type == TYPE_AUTO || return_type == TYPE_POISON) { return FuncInfo(); }
    let argument_types: Vector(Struct) = [];
    let argument_names: Vector(String) = [];
    let i: Int = 0;
    while (node.params is !null && i < node.params.length()) {
        let parameter: ParamNode = node.params[i];
        let parameter_type: Int = resolve_type(ref source, parameter.type_tok);
        if (parameter_type == TYPE_AUTO || parameter_type == TYPE_POISON || parameter.pass_mode == PARAM_REF) { return FuncInfo(); }
        argument_types.append(TypeListNode(type=parameter_type, pass_mode=PARAM_VALUE));
        argument_names.append(parameter.name_tok.value);
        i++;
    }
    info = FuncInfo(name=node.name_tok.value, base_name=node.name_tok.value, ret_type=return_type, arg_types=argument_types, arg_names=argument_names, is_varargs=node.is_varargs, abi_name=node.abi_name, mutates_self=false);
    source.func_table.put(key, info);
    return info;
}

func wir_declare_extern(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: ExternFuncNode) -> Void {
    register_extern_library(ref source, node.link_name, node.pos);
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

func wir_register_enum(ref types: WirTypeMap, ref source: Compiler, node: EnumDefNode) -> Void {
    let name: String = source.current_package_prefix + node.name_tok.value;
    let info: StructInfo = source.struct_table.lookup(name);
    if (!has_struct(info) || !info.is_enum) {
        types.errors.append("Enum '" + name + "' was not registered before WIR lowering");
        return;
    }

    let record_fields: Bool = info.fields is null || info.fields.length() == 0;
    let value: Long = 0L;
    let i: Int = 0;
    while (node.fields is !null && i < node.fields.length()) {
        let field: EnumFieldNode = node.fields[i];
        if (has_node(field.value)) { value = eval_const_long(ref source, field.value, field.pos); }
        if (value < -2147483648L || value > 2147483647L) {
            types.errors.append("Enum member '" + name + "." + field.name_tok.value + "' is outside the Int range");
            return;
        }
        types.enum_values.put(name + "." + field.name_tok.value, WirEnumValue(source_type=info.type_id, value=value));
        if record_fields {
            info.fields.append(FieldInfo(name=field.name_tok.value, type=info.type_id, llvm_type="i32", offset=Int(value), is_const=true));
        }
        value++;
        i++;
    }
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

func wir_queue_method_body(ref source: Compiler, fallback: StructInfo, method_info: FuncInfo) -> Void {
    let owner: StructInfo = fallback;
    if (method_info.arg_types is !null && method_info.arg_types.length() != 0) {
        let receiver: TypeListNode = method_info.arg_types[0];
        let declared: StructInfo = source.struct_id_map.lookup("" + get_repr_type(ref source, receiver.type));
        if (has_struct(declared) && declared.is_class) { owner = declared; }
    }
    queue_generic_class_method(ref source, owner, method_info.base_name);
}

func wir_declare_concrete_class(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: StructInfo) -> Void {
    let i: Int = 0;
    while (info.vtable is !null && i < info.vtable.length()) {
        let method_info: FuncInfo = info.vtable[i];
        if ((method_info.compiler_link_name is null || method_info.compiler_link_name.length() == 0) && wir_find_function(program, method_info.name) == NO_WIR_FUNC) {
            wir_queue_method_body(ref source, info, method_info);
            wir_lower_function_decl(ref types, ref source, ref program, method_info);
        }
        i++;
    }
    let special_names: Vector(String) = ["$init", "$deinit"];
    i = 0;
    while (i < special_names.length()) {
        let method_info: FuncInfo = source.func_table.lookup(info.name + "_" + special_names[i]);
        if (has_func(method_info) && (method_info.compiler_link_name is null || method_info.compiler_link_name.length() == 0) && wir_find_function(program, method_info.name) == NO_WIR_FUNC) {
            wir_lower_function_decl(ref types, ref source, ref program, method_info);
        }
        i++;
    }
}

func wir_emit_class_vtable_info(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: StructInfo) -> Void {
    if (!has_struct(info) || !info.is_class) { return; }
    let name: String = wir_class_vtable_name(info);
    let global_id: WirGlobalID = wir_find_global(program, name);

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
    if (global_id == NO_WIR_GLOBAL) {
        wir_add_global(ref program, name, table_type, initializer, WirLinkage.Internal, true);
    } else {
        program.arena.globals[wir_id_index(UInt32(global_id))].initializer = initializer;
    }
}

func wir_emit_class_vtable(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: ClassDefNode) -> Void {
    if (node.type_params is !null && node.type_params.length() != 0) { return; }
    wir_emit_class_vtable_info(ref types, ref source, ref program, source.struct_table.lookup(wir_class_name(source, node)));
}

func wir_emit_interface_tables_info(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: StructInfo) -> Void {
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
                if (has_func(implementation)) { wir_queue_method_body(ref source, info, implementation); }
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

func wir_emit_interface_tables(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: ClassDefNode) -> Void {
    if (node.type_params is !null && node.type_params.length() != 0) { return; }
    wir_emit_interface_tables_info(ref types, ref source, ref program, source.struct_table.lookup(wir_class_name(source, node)));
}

func wir_declare_generic_classes(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule) -> Void {
    let i: Int = 0;
    while (source.generic_class_worklist is !null && i < source.generic_class_worklist.length()) {
        let instance: GenericClassInstance = source.generic_class_worklist[i];
        let info: StructInfo = source.struct_id_map.lookup("" + instance.type_id);
        let previous_bindings: Dict(String, SymbolInfo) = source.generic_bindings;
        let previous: GenericTemplate = use_generic_context(ref source, instance.template, instance.bindings);
        wir_declare_concrete_class(ref types, ref source, ref program, info);
        wir_emit_class_vtable_info(ref types, ref source, ref program, info);
        wir_emit_interface_tables_info(ref types, ref source, ref program, info);
        restore_generic_context(ref source, previous, previous_bindings);
        i++;
    }
}

func wir_refresh_generic_vtables(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule) -> Void {
    let i: Int = 0;
    while (source.generic_class_worklist is !null && i < source.generic_class_worklist.length()) {
        let instance: GenericClassInstance = source.generic_class_worklist[i];
        let info: StructInfo = source.struct_id_map.lookup("" + instance.type_id);
        let previous_bindings: Dict(String, SymbolInfo) = source.generic_bindings;
        let previous: GenericTemplate = use_generic_context(ref source, instance.template, instance.bindings);
        wir_emit_class_vtable_info(ref types, ref source, ref program, info);
        wir_emit_interface_tables_info(ref types, ref source, ref program, info);
        restore_generic_context(ref source, previous, previous_bindings);
        i++;
    }
}

func wir_lower_generic_methods(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule) -> Void {
    let i: Int = 0;
    while (source.generic_method_worklist is !null && i < source.generic_method_worklist.length()) {
        let instance: GenericMethodInstance = source.generic_method_worklist[i];
        let method_node: MethodDefNode = get_method_def_node(source.arena, instance.template.node);
        let previous_bindings: Dict(String, SymbolInfo) = source.generic_bindings;
        let previous: GenericTemplate = use_generic_context(ref source, instance.template, instance.bindings);
        let previous_key: String = source.generic_method_key;
        let previous_depth: Int = source.generic_depth;
        source.generic_method_key = instance.func_key;
        source.generic_depth = instance.depth;
        let method_info: FuncInfo = source.func_table.lookup(instance.func_key);
        if (has_func(method_info) && (method_info.ann_flags & FLAG_ANN_INTRINSIC) == 0 && (method_info.compiler_link_name is null || method_info.compiler_link_name.length() == 0)) {
            let function_id: WirFuncID = wir_find_function(program, method_info.name);
            let has_body: Bool = false;
            if (function_id != NO_WIR_FUNC) {
                let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
                has_body = function.blocks.length() != 0;
            }
            if (!has_body) { wir_lower_function_body(ref types, ref source, ref program, method_info, method_node.body); }
        }
        source.generic_depth = previous_depth;
        source.generic_method_key = previous_key;
        restore_generic_context(ref source, previous, previous_bindings);
        i++;
    }
}

func wir_lower_generic_functions(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule) -> Void {
    let i: Int = 0;
    while (source.generic_worklist is !null && i < source.generic_worklist.length()) {
        let instance: GenericFuncInstance = source.generic_worklist[i];
        let function_node: FunctionDefNode = get_func_def_node(source.arena, instance.template.node);
        let previous_bindings: Dict(String, SymbolInfo) = source.generic_bindings;
        let previous: GenericTemplate = use_generic_context(ref source, instance.template, instance.bindings);
        let previous_key: String = source.generic_func_key;
        let previous_depth: Int = source.generic_depth;
        source.generic_func_key = instance.func_key;
        source.generic_depth = instance.depth;
        let info: FuncInfo = source.func_table.lookup(instance.func_key);
        if (has_func(info)) {
            let function_id: WirFuncID = wir_find_function(program, info.name);
            if (function_id == NO_WIR_FUNC) { function_id = wir_lower_function_decl(ref types, ref source, ref program, info); }
            let has_body: Bool = false;
            if (function_id != NO_WIR_FUNC) {
                let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
                has_body = function.blocks.length() != 0;
            }
            if (!has_body) { wir_lower_function_body(ref types, ref source, ref program, info, function_node.body); }
        }
        source.generic_depth = previous_depth;
        source.generic_func_key = previous_key;
        restore_generic_context(ref source, previous, previous_bindings);
        i++;
    }
}

func wir_lower_generic_instances(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule) -> Void {
    while true {
        let class_count: Int = 0;
        let function_count: Int = 0;
        let method_count: Int = 0;
        if (source.generic_class_worklist is !null) { class_count = source.generic_class_worklist.length(); }
        if (source.generic_worklist is !null) { function_count = source.generic_worklist.length(); }
        if (source.generic_method_worklist is !null) { method_count = source.generic_method_worklist.length(); }
        wir_declare_generic_classes(ref types, ref source, ref program);
        wir_lower_generic_functions(ref types, ref source, ref program);
        wir_lower_generic_methods(ref types, ref source, ref program);
        let next_class_count: Int = 0;
        let next_function_count: Int = 0;
        let next_method_count: Int = 0;
        if (source.generic_class_worklist is !null) { next_class_count = source.generic_class_worklist.length(); }
        if (source.generic_worklist is !null) { next_function_count = source.generic_worklist.length(); }
        if (source.generic_method_worklist is !null) { next_method_count = source.generic_method_worklist.length(); }
        if (class_count == next_class_count && function_count == next_function_count && method_count == next_method_count) { break; }
    }
}

func wir_declare_root_items(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, root: BlockNode) -> Void {
    let i: Int = 0;
    while (i < root.stmts.length()) {
        let node: NodeID = root.stmts[i];
        let kind: Int = node_tag(node);
        if (kind == NODE_ENUM_DEF) {
            wir_register_enum(ref types, ref source, get_enum_def_node(source.arena, node));
        } else if (kind == NODE_FUNC_DEF) {
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

func wir_emit_required_runtime(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule) -> Void {
    if (!wir_module_uses_opcode(program, WirOpcode.Retain) && !wir_module_uses_opcode(program, WirOpcode.Release)) { return; }
    let deallocator: FuncInfo = wir_compiler_link_function(ref source, "memory_free");
    if (!has_func(deallocator)) { return; }
    let deallocator_id: WirFuncID = wir_find_function(program, deallocator.name);
    if (deallocator_id == NO_WIR_FUNC) { deallocator_id = wir_lower_function_decl(ref types, ref source, ref program, deallocator); }
    if (deallocator_id == NO_WIR_FUNC) {
        types.errors.append("ARC could not lower the memory_free compiler link");
        return;
    }
    wir_emit_ownership_runtime(ref program, deallocator_id, TYPE_STRING);
}

func wir_lower_program(ref source: Compiler, modules: Vector(ParsedModule), target: String, pointer_bits: Int) -> WirLoweringResult {
    let program: WirModule = new_wir_module(target, pointer_bits);
    program.is_shared = source.is_shared;
    let types: WirTypeMap = new_wir_type_map();
    if (!select_target(target)) {
        types.errors.append("Unsupported WIR target '" + target + "'");
        return WirLoweringResult(program=program, errors=types.errors);
    }

    let i: Int = 0;
    while (i < modules.length()) {
        let module: ParsedModule = modules[i];
        set_module_context(ref source, module);
        if (!has_node(module.ast) || node_tag(module.ast) != NODE_BLOCK) {
            types.errors.append("Module '" + module.path + "' has no root block");
        } else {
            wir_declare_root_items(ref types, ref source, ref program, get_block_node(source.arena, module.ast));
        }
        i++;
    }

    wir_declare_generic_classes(ref types, ref source, ref program);

    i = 0;
    while (i < modules.length()) {
        let module: ParsedModule = modules[i];
        set_module_context(ref source, module);
        if (has_node(module.ast) && node_tag(module.ast) == NODE_BLOCK) {
            wir_lower_root_items(ref types, ref source, ref program, get_block_node(source.arena, module.ast));
        }
        i++;
    }

    wir_lower_generic_instances(ref types, ref source, ref program);
    wir_refresh_generic_vtables(ref types, ref source, ref program);

    wir_emit_required_runtime(ref types, ref source, ref program);
    wir_emit_target_runtime(ref source, ref program, types.errors);
    wir_verify_lowering(ref types, program);
    return WirLoweringResult(program=program, errors=types.errors);
}

func wir_lower_module(ref source: Compiler, root_node: NodeID, target: String, pointer_bits: Int) -> WirLoweringResult {
    let program: WirModule = new_wir_module(target, pointer_bits);
    let types: WirTypeMap = new_wir_type_map();
    if (!select_target(target)) {
        types.errors.append("Unsupported WIR target '" + target + "'");
        return WirLoweringResult(program=program, errors=types.errors);
    }
    if (!has_node(root_node) || node_tag(root_node) != NODE_BLOCK) {
        types.errors.append("WIR module root is not a block");
        return WirLoweringResult(program=program, errors=types.errors);
    }

    let root: BlockNode = get_block_node(source.arena, root_node);
    wir_declare_root_items(ref types, ref source, ref program, root);
    wir_lower_root_items(ref types, ref source, ref program, root);
    wir_emit_required_runtime(ref types, ref source, ref program);
    wir_emit_target_runtime(ref source, ref program, types.errors);
    wir_verify_lowering(ref types, program);
    return WirLoweringResult(program=program, errors=types.errors);
}
