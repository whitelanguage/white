// compiler/analysis.wl

import * from "../frontend/ast.wl"
import * from "../frontend/arena.wl"
import * from "../frontend/diagnostics.wl"
import * from "context.wl"
import * from "validation.wl"
import check_class_initialization from "initialization.wl"

struct TypeAnalysisTarget(
    node: NodeID,
    module: ParsedModule,
    type_id: Int
)

func type_target_index(targets: Vector(TypeAnalysisTarget), type_id: Int) -> Int {
    let i: Int = 0;
    while (i < targets.length()) {
        if (targets[i].type_id == type_id) { return i; }
        i++;
    }
    return -1;
}

func type_is_pending(stack: Vector(Int), type_id: Int) -> Bool {
    let i: Int = 0;
    while (i < stack.length()) {
        if (stack[i] == type_id) { return true; }
        i++;
    }
    return false;
}

func extend_type_path(stack: Vector(Int), type_id: Int) -> Vector(Int) {
    let path: Vector(Int) = [];
    let i: Int = 0;
    while (i < stack.length()) {
        path.append(stack[i]);
        i++;
    }
    path.append(type_id);
    return path;
}

func value_struct_dependency(ref c: Compiler, type_id: Int) -> Int {
    let named: NamedTypeInfo = get_named_type(ref c, type_id);
    if (has_named_type(named)) { return value_struct_dependency(ref c, named.underlying_type); }

    let array: ArrayInfo = c.array_info_map.lookup("" + type_id);
    if (has_array_info(array)) {
        if (array.size < 0) { return 0; }
        return value_struct_dependency(ref c, array.base_type);
    }

    let fallible: SymbolInfo = c.fallible_base_map.lookup("" + type_id);
    if (has_symbol(fallible)) { return value_struct_dependency(ref c, fallible.type); }

    let info: StructInfo = c.struct_id_map.lookup("" + type_id);
    if (has_struct(info) && !info.is_class && !info.is_interface && !info.is_enum) { return info.type_id; }
    return 0;
}

func resolve_struct_target(ref c: Compiler, target: TypeAnalysisTarget, targets: Vector(TypeAnalysisTarget), stack: Vector(Int)) -> Bool {
    set_module_context(ref c, target.module);
    let node: StructDefNode = get_struct_def_node(c.arena, target.node);
    if (node.type_params is !null && node.type_params.length() > 0) { return true; }

    let struct_name: String = c.current_package_prefix + node.name_tok.value;
    let info: StructInfo = c.struct_table.lookup(struct_name);
    if (!has_struct(info)) {
        throw_type_error(node.pos, "Struct info missing for '" + struct_name + "'.");
        return false;
    }
    if ((info.ann_flags & FLAG_ANN_INTRINSIC) != 0 || info.fields is !null) { return true; }

    let path: Vector(Int) = extend_type_path(stack, info.type_id);

    let fields: Vector(Struct) = [];
    let names: Dict(String, StringConstant) = Dict();
    let parameters: Vector(ParamNode) = node.fields;
    let i: Int = 0;
    while (parameters is !null && i < parameters.length()) {
        let parameter: ParamNode = parameters[i];
        let name: String = parameter.name_tok.value;
        if (names.contains_key(name)) {
            throw_name_error(parameter.pos, "Field '" + name + "' is already defined in struct '" + struct_name + "'.");
            return false;
        }
        names.put(name, StringConstant(id=0, value=name));

        let type_id: Int = resolve_type(ref c, parameter.type_tok);
        if (type_id == TYPE_AUTO) {
            throw_type_error(parameter.pos, "Struct field '" + name + "' needs an explicit type.");
            return false;
        }
        if (type_id == TYPE_POISON) { return false; }
        let dependency_type: Int = value_struct_dependency(ref c, type_id);
        if (dependency_type != 0) {
            if (type_is_pending(path, dependency_type)) {
                throw_type_error(parameter.pos, "Struct '" + struct_name + "' contains itself by value through field '" + name + "'. Use a pointer for recursive storage.");
                return false;
            }
            let dependency_index: Int = type_target_index(targets, dependency_type);
            if (dependency_index >= 0) {
                if (!resolve_struct_target(ref c, targets[dependency_index], targets, path)) { return false; }
                set_module_context(ref c, target.module);
            }
        }
        if (value_layout_contains(ref c, type_id, info.type_id, [])) {
            throw_type_error(parameter.pos, "Struct '" + struct_name + "' contains itself by value through field '" + name + "'. Use a pointer for recursive storage.");
            return false;
        }

        fields.append(FieldInfo(name=name, type=type_id, llvm_type="", offset=i, is_const=false));
        i++;
    }

    info.fields = fields;
    store_struct(ref c, info);
    return true;
}

func find_interface_implementation(ref c: Compiler, class_info: StructInfo, interface_info: StructInfo, required: MethodDefNode) -> FuncInfo {
    let i: Int = 0;
    while (class_info.vtable is !null && i < class_info.vtable.length()) {
        let candidate: FuncInfo = class_info.vtable[i];
        if (candidate.base_name == required.name_tok.value) {
            let matches: Bool = candidate.ret_type == interface_method_type_for(ref c, interface_info, required.return_type, class_info.type_id);
            let parameters: Vector(ParamNode) = required.params;
            let parameter_count: Int = 0;
            if (parameters is !null) { parameter_count = parameters.length(); }
            let candidate_count: Int = 0;
            if (candidate.arg_types is !null) { candidate_count = candidate.arg_types.length(); }
            if (candidate_count != parameter_count + 1) { matches = false; }

            let parameter_index: Int = 0;
            while (matches && parameter_index < parameter_count) {
                let parameter: ParamNode = parameters[parameter_index];
                let expected_type: Int = interface_method_type_for(ref c, interface_info, parameter.type_tok, class_info.type_id);
                let actual: TypeListNode = candidate.arg_types[parameter_index + 1];
                if (actual.type != expected_type || actual.pass_mode != parameter.pass_mode) { matches = false; }
                parameter_index++;
            }
            if (matches) { return candidate; }
        }
        i++;
    }
    return FuncInfo();
}

func validate_class_interfaces(ref c: Compiler, info: StructInfo, pos: Position) -> Bool {
    let interface_index: Int = 0;
    while (info.interfaces is !null && interface_index < info.interfaces.length()) {
        let interface_type: TypeListNode = info.interfaces[interface_index];
        let interface_info: StructInfo = c.struct_id_map.lookup("" + interface_type.type);
        if (!has_struct(interface_info) || !interface_info.is_interface) {
            throw_type_error(pos, "Type " + get_type_name(ref c, interface_type.type) + " is not an interface.");
            return false;
        }

        let method_index: Int = 0;
        while (interface_info.vtable is !null && method_index < interface_info.vtable.length()) {
            let required: MethodDefNode = interface_info.vtable[method_index];
            if (!has_func(find_interface_implementation(ref c, info, interface_info, required))) {
                throw_name_error(pos, "Class '" + info.name + "' does not implement interface method '" + required.name_tok.value + "'.");
                return false;
            }
            method_index++;
        }
        interface_index++;
    }
    return true;
}

func resolve_class_target(ref c: Compiler, target: TypeAnalysisTarget, targets: Vector(TypeAnalysisTarget), stack: Vector(Int)) -> Bool {
    set_module_context(ref c, target.module);
    let node: ClassDefNode = get_class_def_node(c.arena, target.node);
    if (node.type_params is !null && node.type_params.length() > 0) { return true; }

    let class_name: String = c.current_package_prefix + node.name_tok.value;
    let info: StructInfo = c.struct_table.lookup(class_name);
    if (!has_struct(info) || !info.is_class) {
        throw_type_error(node.pos, "Class info missing for '" + class_name + "'.");
        return false;
    }
    if (info.fields is !null && info.vtable is !null && info.interfaces is !null) { return true; }

    let path: Vector(Int) = extend_type_path(stack, info.type_id);
    let parent_info: StructInfo = StructInfo();
    if (has_node(node.parent_tok)) {
        let parent_type: Int = resolve_type(ref c, node.parent_tok);
        parent_info = c.struct_id_map.lookup("" + parent_type);
        if (!has_struct(parent_info) || !parent_info.is_class) {
            throw_type_error(node.pos, "Type " + get_type_name(ref c, parent_type) + " is not a class.");
            return false;
        }
        if (type_is_pending(path, parent_type)) {
            throw_type_error(node.pos, "Class inheritance cycle involving '" + class_name + "'.");
            return false;
        }
        let parent_index: Int = type_target_index(targets, parent_type);
        if (parent_index >= 0) {
            if (!resolve_class_target(ref c, targets[parent_index], targets, path)) { return false; }
            set_module_context(ref c, target.module);
            parent_info = c.struct_id_map.lookup("" + parent_type);
        }
        info.parent_id = parent_type;
    }

    let interfaces: Vector(Struct) = [];
    if (has_struct(parent_info)) {
        let inherited_index: Int = 0;
        while (parent_info.interfaces is !null && inherited_index < parent_info.interfaces.length()) {
            let inherited: TypeListNode = parent_info.interfaces[inherited_index];
            if (!add_interface_type(ref c, interfaces, inherited.type, node.pos)) { return false; }
            inherited_index++;
        }
    }
    let declared_index: Int = 0;
    while (node.interfaces is !null && declared_index < node.interfaces.length()) {
        if (!add_interface(ref c, interfaces, node.interfaces[declared_index], node.pos)) { return false; }
        declared_index++;
    }
    info.interfaces = interfaces;

    check_class_initialization(ref c, class_name, node, parent_info);

    let fields: Vector(Struct) = [];
    let methods: Vector(Struct) = [];
    let names: Dict(String, StringConstant) = Dict();
    let offset: Int = 0;
    if (has_struct(parent_info)) {
        let i: Int = 0;
        while (parent_info.fields is !null && i < parent_info.fields.length()) {
            let field: FieldInfo = parent_info.fields[i];
            fields.append(FieldInfo(name=field.name, type=field.type, llvm_type="", offset=field.offset, is_const=field.is_const));
            names.put(field.name, StringConstant(id=0, value=field.name));
            offset++;
            i++;
        }
        i = 0;
        while (parent_info.vtable is !null && i < parent_info.vtable.length()) {
            methods.append(parent_info.vtable[i]);
            i++;
        }
    } else {
        fields.append(FieldInfo(name="_vptr", type=TYPE_VOID, llvm_type="", offset=0, is_const=true));
        names.put("_vptr", StringConstant(id=0, value="_vptr"));
        offset = 1;
    }

    let field_index: Int = 0;
    while (node.fields is !null && field_index < node.fields.length()) {
        let declaration: VarDeclareNode = get_var_decl_node(c.arena, node.fields[field_index]);
        let field_name: String = declaration.name_tok.value;
        if (names.contains_key(field_name)) {
            throw_name_error(declaration.pos, "Field '" + field_name + "' is already defined in class '" + class_name + "'.");
            return false;
        }
        if (has_func(find_method(methods, field_name))) {
            throw_name_error(declaration.pos, "Class '" + class_name + "' cannot use '" + field_name + "' as both a field and a method.");
            return false;
        }

        let field_type: Int = resolve_type(ref c, declaration.type_node);
        if (field_type == TYPE_AUTO) {
            if (!has_node(declaration.value)) {
                throw_type_error(declaration.pos, "Field '" + field_name + "' needs an explicit type when it has no initializer.");
                return false;
            }
            field_type = get_expr_type(ref c, declaration.value);
            if (field_type == 0 || field_type == TYPE_AUTO || field_type == TYPE_POISON) {
                throw_type_error(declaration.pos, "Cannot infer the type of class field '" + field_name + "'.");
                return false;
            }
        }
        names.put(field_name, StringConstant(id=0, value=field_name));
        fields.append(FieldInfo(name=field_name, type=field_type, llvm_type="", offset=offset, is_const=declaration.is_const));
        offset++;
        field_index++;
    }

    let method_index: Int = 0;
    while (node.methods is !null && method_index < node.methods.length()) {
        let method_node: MethodDefNode = get_method_def_node(c.arena, node.methods[method_index]);
        let method_name: String = method_base_name(ref c, method_node);
        if (!method_name.starts_with("$") && names.contains_key(method_name)) {
            throw_name_error(method_node.pos, "Class '" + class_name + "' cannot use '" + method_name + "' as both a field and a method.");
            return false;
        }
        if ((method_node.type_params is null || method_node.type_params.length() == 0) && method_name != "$init" && method_name != "$field_init") {
            let method_info: FuncInfo = c.func_table.lookup(class_name + "_" + method_name);
            if (!has_func(method_info)) {
                throw_internal_compiler_error(method_node.pos, "Method '" + class_name + "_" + method_name + "' was not registered.");
                return false;
            }
            if (method_info.compiler_link_name is null || method_info.compiler_link_name.length() == 0) {
                let inherited_index: Int = 0;
                let overridden: Bool = false;
                while (inherited_index < methods.length()) {
                    let inherited: FuncInfo = methods[inherited_index];
                    if (inherited.base_name == method_name) {
                        if (!same_method_signature(inherited, method_info)) {
                            throw_type_error(method_node.pos, "Override of '" + method_name + "' does not match the parent method signature");
                            return false;
                        }
                        methods[inherited_index] = method_info;
                        overridden = true;
                        break;
                    }
                    inherited_index++;
                }
                if (!overridden) { methods.append(method_info); }
            }
        }
        method_index++;
    }

    info.fields = fields;
    info.vtable = methods;
    store_struct(ref c, info);
    return validate_class_interfaces(ref c, info, node.pos);
}

func analyze_declarations(ref c: Compiler) -> Void {
    let struct_targets: Vector(TypeAnalysisTarget) = [];
    let class_targets: Vector(TypeAnalysisTarget) = [];
    let module_index: Int = 0;
    while (module_index < c.all_modules.length()) {
        let module: ParsedModule = c.all_modules[module_index];
        set_module_context(ref c, module);
        let root: BlockNode = get_block_node(c.arena, module.ast);
        let i: Int = 0;
        while (root.stmts is !null && i < root.stmts.length()) {
            let node: NodeID = root.stmts[i];
            if (node_tag(node) == NODE_STRUCT_DEF) {
                let definition: StructDefNode = get_struct_def_node(c.arena, node);
                if (definition.type_params is null || definition.type_params.length() == 0) {
                    let info: StructInfo = c.struct_table.lookup(module.prefix + definition.name_tok.value);
                    if (has_struct(info) && (info.ann_flags & FLAG_ANN_INTRINSIC) == 0) {
                        struct_targets.append(TypeAnalysisTarget(node=node, module=module, type_id=info.type_id));
                    }
                }
            } else if (node_tag(node) == NODE_CLASS_DEF) {
                let definition: ClassDefNode = get_class_def_node(c.arena, node);
                if (definition.type_params is null || definition.type_params.length() == 0) {
                    let info: StructInfo = c.struct_table.lookup(module.prefix + definition.name_tok.value);
                    if (has_struct(info)) {
                        class_targets.append(TypeAnalysisTarget(node=node, module=module, type_id=info.type_id));
                    }
                }
            }
            i++;
        }
        module_index++;
    }

    let i: Int = 0;
    while (i < struct_targets.length()) {
        let target: TypeAnalysisTarget = struct_targets[i];
        if (!resolve_struct_target(ref c, target, struct_targets, [])) { return; }
        i++;
    }
    i = 0;
    while (i < class_targets.length()) {
        let target: TypeAnalysisTarget = class_targets[i];
        if (!resolve_class_target(ref c, target, class_targets, [])) { return; }
        i++;
    }
}
