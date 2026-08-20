// compiler/registration.wl
import * from "../frontend/ast.wl"
import * from "../frontend/arena.wl"
import * from "context.wl"
import * from "../frontend/diagnostics.wl"
import * from "lowering/dictionary.wl"
import * from "validation.wl"

func is_builtin_type_name(name: String) -> Bool {
    return get_builtin_cast_target(name) != 0 || name == "Void" || name == "Auto" ||
           name == "Struct" || name == "Class" || name == "Function" ||
           name == "Method" || name == "Enum";
}

func reserve_named_types(c: Compiler, node: NodeID) -> Void {
    let block: BlockNode = get_block_node(c.arena, node);
    let stmts: Vector(NodeID) = block.stmts;
    let i: Int = 0;
    while (stmts is !null && i < stmts.length()) {
        if (node_tag(stmts[i]) == NODE_TYPE_DECL) {
            let decl: TypeDeclNode = get_type_decl_node(c.arena, stmts[i]);
            let raw_name: String = decl.name_tok.value;
            let name: String = c.current_package_prefix + raw_name;
            if (is_builtin_type_name(raw_name) || has_named_type(c.named_types.lookup(name)) ||
                has_struct(c.struct_table.lookup(name)) || has_template(c.generic_structs.lookup(name))) {
                throw_name_error(decl.pos, "Type '" + name + "' is already defined.");
                i += 1;
                continue;
            }

            let type_id: Int = TYPE_POISON;
            if (!decl.is_alias) {
                type_id = c.type_counter;
                c.type_counter += 1;
            }
            let info: NamedTypeInfo = NamedTypeInfo(name=name, type_id=type_id, underlying_type=TYPE_POISON, is_alias=decl.is_alias, target_node=decl.target_type, pos=decl.pos, resolving=false, resolved=false);
            c.named_types.put(name, info);
            if (!decl.is_alias) {
                c.named_type_ids.put("" + type_id, info);
            }
        }
        i += 1;
    }
}

func resolve_named_types(c: Compiler, node: NodeID) -> Void {
    let block: BlockNode = get_block_node(c.arena, node);
    let stmts: Vector(NodeID) = block.stmts;
    let i: Int = 0;
    while (stmts is !null && i < stmts.length()) {
        if (node_tag(stmts[i]) == NODE_TYPE_DECL) {
            let decl: TypeDeclNode = get_type_decl_node(c.arena, stmts[i]);
            let info: NamedTypeInfo = c.named_types.lookup(c.current_package_prefix + decl.name_tok.value);
            resolve_named_type(c, info);
        }
        i += 1;
    }
}

func append_interface_method(methods: Vector(Struct), names: Dict(String, StringConstant), method_node: MethodDefNode, owner: String) -> Bool {
    let name: String = method_node.name_tok.value;
    if (names.contains_key(name)) {
        let i: Int = 0;
        while (i < methods.length()) {
            let existing: MethodDefNode = methods[i];
            if (existing.name_tok.value == name && existing.pos.fn == method_node.pos.fn && 
                existing.pos.ln == method_node.pos.ln && existing.pos.col == method_node.pos.col) {
                return true;
            }
            i += 1;
        }
        throw_name_error(method_node.pos, "Method '" + name + "' is inherited more than once by interface '" + owner + "'.");
        return false;
    }
    names.put(name, StringConstant(id=0, value=name));
    methods.append(method_node);
    return true;
}

func resolve_interface_info(c: Compiler, info: StructInfo, stack: Vector(Struct), pos: Position) -> Bool {
    let i: Int = 0;
    while (i < stack.length()) {
        let item: TypeListNode = stack[i];
        if (item.type == info.type_id) {
            throw_type_error(pos, "Interface inheritance cycle involving '" + info.name + "'.");
            return false;
        }
        i += 1;
    }

    if (info.interfaces is !null) { return true; }

    stack.append(TypeListNode(type=info.type_id));
    info.interfaces = [];
    let node: InterfaceDefNode = get_interface_def_node(c.arena, info.init_body);
    let methods: Vector(Struct) = [];
    let names: Dict(String, StringConstant) = Dict();

    i = 0;
    while (node.interfaces is !null && i < node.interfaces.length()) {
        let parent_id: Int = resolve_type(c, node.interfaces[i]);
        let parent: StructInfo = c.struct_id_map.lookup("" + parent_id);
        if (!has_struct(parent) || !parent.is_interface) {
            throw_type_error(pos, "Interface '" + info.name + "' can only inherit from another interface.");
            stack.drop();
            return false;
        }
        if (!resolve_interface_info(c, parent, stack, pos)) {
            stack.drop();
            return false;
        }
        parent = c.struct_id_map.lookup("" + parent_id);
        if (!add_interface_type(c, info.interfaces, parent_id, pos)) {
            stack.drop();
            return false;
        }
        let method_index: Int = 0;
        while (parent.vtable is !null && method_index < parent.vtable.length()) {
            let inherited: MethodDefNode = parent.vtable[method_index];
            if (!append_interface_method(methods, names, inherited, info.name)) {
                stack.drop();
                return false;
            }
            method_index += 1;
        }
        i += 1;
    }

    i = 0;
    while (node.methods is !null && i < node.methods.length()) {
        let declared: MethodDefNode = get_method_def_node(c.arena, node.methods[i]);
        if (!append_interface_method(methods, names, declared, info.name)) {
            stack.drop();
            return false;
        }
        i += 1;
    }
    info.vtable = methods;
    store_struct(c, info);
    stack.drop();
    return true;
}

func pre_register_structs(c: Compiler, node: NodeID) -> Void {
    let block: BlockNode = get_block_node(c.arena, node);
    let stmts: Vector(NodeID) = block.stmts;
    let len: Int = 0;
    if (stmts is !null) { len = stmts.length(); }
    let i: Int = 0;
    
    while (i < len) {
        let base: Int = node_tag(stmts[i]);
        if (base == NODE_STRUCT_DEF) {
            let n: StructDefNode = get_struct_def_node(c.arena, stmts[i]);
            let raw_name: String = n.name_tok.value;
            let s_name: String = c.current_package_prefix + raw_name;

            if (n.type_params is !null && n.type_params.length() > 0) {
                if (has_template(c.generic_structs.lookup(s_name)) || has_struct(c.struct_table.lookup(s_name)) || has_named_type(c.named_types.lookup(s_name))) {
                    throw_name_error(n.pos, "Type '" + s_name + "' is already defined");
                    i += 1;
                    continue;
                }
                c.generic_structs.put(s_name, GenericTemplate(name=s_name, node=stmts[i], type_params=n.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                i += 1;
                continue;
            }

            // for dict.wl
            let sys_anns: SystemAnnResult = consume_annotations(c, n.annotations, raw_name);
            if ((sys_anns.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
                if (c.current_package_prefix != "dict." && c.current_package_prefix != "") {
                    throw_internal_compiler_error(n.pos, "@CompilerIntrinsic is restricted to compiler internal libraries.");
                    return; 
                }

                if (raw_name == "Variant") {
                    let intrinsic_info: StructInfo = c.struct_table.lookup("$Variant");
                    c.struct_table.put(s_name, intrinsic_info); 
                    i += 1;
                    continue; 
                } else {
                    throw_internal_compiler_error(n.pos, "Unknown intrinsic struct '" + raw_name + "'.");
                    return;
                }
            }
            if (has_struct(c.struct_table.lookup(s_name)) || has_template(c.generic_structs.lookup(s_name)) || has_named_type(c.named_types.lookup(s_name))) {
                throw_name_error(n.pos, "Type '" + s_name + "' is already defined");
                i += 1;
                continue;
            }

            let new_id: Int = c.type_counter;
            c.type_counter += 1;
            let info: StructInfo = StructInfo(
                name=s_name, 
                type_id=new_id, 
                fields=null, 
                llvm_name="%struct." + s_name, 
                init_body=n.body, is_class=false, 
                vtable_name="", 
                parent_id=0, 
                vtable=null,
                ann_flags=sys_anns.ann_flags,
                compiler_link_name=sys_anns.compiler_link_name,
                is_enum=false,
                is_error=false,
                is_interface=false,
                interfaces=null
            );
            c.struct_table.put(s_name, info);
            c.struct_id_map.put("" + new_id, info);
            
        } else if (base == NODE_CLASS_DEF) {
            let c_node: ClassDefNode = get_class_def_node(c.arena, stmts[i]);
            let raw_name: String = c_node.name_tok.value;
            let c_name: String = c.current_package_prefix + raw_name;
            if (c_node.type_params is !null && c_node.type_params.length() > 0) {
                if (has_template(c.generic_structs.lookup(c_name)) || has_named_type(c.named_types.lookup(c_name)) || (has_struct(c.struct_table.lookup(c_name)) && c_name != "dict.Dict")) {
                    throw_name_error(c_node.pos, "Type '" + c_name + "' is already defined");
                    i += 1;
                    continue;
                }

                c.generic_structs.put(c_name, GenericTemplate(name=c_name, node=stmts[i], type_params=c_node.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                i++;
                continue;
            }
            if (has_struct(c.struct_table.lookup(c_name)) || has_named_type(c.named_types.lookup(c_name)) || (has_template(c.generic_structs.lookup(c_name)) && c_name != "dict.Dict")) {
                throw_name_error(c_node.pos, "Type '" + c_name + "' is already defined");
                i += 1;
                continue;
            }
            let sys_anns: SystemAnnResult = consume_annotations(c, c_node.annotations, raw_name);
            let new_id: Int = c.type_counter;
            c.type_counter += 1;
            let info: StructInfo = StructInfo(
                name=c_name, 
                type_id=new_id, 
                fields=null, 
                llvm_name="%class." + c_name, 
                init_body=stmts[i], 
                is_class=true, 
                vtable_name="@vtable." + c_name, 
                parent_id=0, 
                vtable=null,
                ann_flags=sys_anns.ann_flags,
                compiler_link_name=sys_anns.compiler_link_name,
                is_enum=false,
                is_error=false,
                is_interface=false,
                interfaces=null
            );
            c.struct_table.put(c_name, info);
            c.struct_id_map.put("" + new_id, info);
        } else if (base == NODE_INTERFACE_DEF) {
            let i_node: InterfaceDefNode = get_interface_def_node(c.arena, stmts[i]);
            let raw_name: String = i_node.name_tok.value;
            let i_name: String = c.current_package_prefix + raw_name;
            if (has_struct(c.struct_table.lookup(i_name)) || has_template(c.generic_structs.lookup(i_name)) || has_named_type(c.named_types.lookup(i_name))) {
                throw_name_error(i_node.pos, "Type '" + i_name + "' is already defined");
                i += 1;
                continue;
            }
            if (i_node.type_params is !null && i_node.type_params.length() > 0) {
                c.generic_structs.put(i_name, GenericTemplate(name=i_name, node=stmts[i], type_params=i_node.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                i++;
                continue;
            }
            let method_names: Dict(String, StringConstant) = Dict();
            let method_index: Int = 0;
            while (i_node.methods is !null && method_index < i_node.methods.length()) {
                let iface_method: MethodDefNode = get_method_def_node(c.arena, i_node.methods[method_index]);
                let method_name: String = iface_method.name_tok.value;
                if (iface_method.type_params is !null && iface_method.type_params.length() > 0) {
                    throw_type_error(iface_method.pos, "Interface methods cannot declare type parameters.");
                    break;
                }
                if (method_names.contains_key(method_name)) { throw_name_error(iface_method.pos, "method '" + method_name + "' is already declared in interface '" + i_name + "'"); break; }
                method_names.put(method_name, StringConstant(id=0, value=method_name));
                check_duplicate_params(iface_method.params, "interface method '" + method_name + "'", iface_method.pos);
                if (variadic_param_index(iface_method.params) > 0) {
                    throw_type_error(iface_method.pos, "Interface methods cannot declare variadic parameters.");
                    break;
                }
                method_index += 1;
            }
            let sys_anns: SystemAnnResult = consume_annotations(c, i_node.annotations, raw_name);
            if ((sys_anns.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
                if (raw_name != "__Printable") {
                    throw_internal_compiler_error(i_node.pos, "Unknown intrinsic interface '" + raw_name + "'.");
                    return;
                }
            }
            let new_id: Int = c.type_counter;
            c.type_counter += 1;
            let info: StructInfo = StructInfo(
                name=i_name, 
                type_id=new_id, 
                fields=null, 
                llvm_name="{ i8*, i8* }", 
                init_body=stmts[i], 
                is_class=false, 
                vtable_name="", 
                parent_id=0, 
                vtable=[],
                ann_flags=sys_anns.ann_flags,
                compiler_link_name=sys_anns.compiler_link_name,
                is_enum=false,
                is_error=false,
                is_interface=true,
                interfaces=null
            );
            c.struct_table.put(i_name, info);
            c.struct_id_map.put("" + new_id, info);
        } else if (base == NODE_ENUM_DEF) {
            let e_node: EnumDefNode = get_enum_def_node(c.arena, stmts[i]);
            let raw_name: String = e_node.name_tok.value;
            let e_name: String = c.current_package_prefix + raw_name;
            if (has_struct(c.struct_table.lookup(e_name)) || 
                has_named_type(c.named_types.lookup(e_name))) {
                throw_name_error(e_node.pos, "Type '" + e_name + "' is already defined");
                i += 1;
                continue;
            }
            let sys_anns: SystemAnnResult = consume_annotations(c, e_node.annotations, raw_name);
            let new_id: Int = c.type_counter;
            c.type_counter += 1;
            
            let info: StructInfo = StructInfo(
                name=e_name, 
                type_id=new_id, 
                fields=[], 
                llvm_name="i32", 
                init_body=NO_NODE, 
                is_class=false, 
                vtable_name="", 
                parent_id=0, 
                vtable=null,
                ann_flags=sys_anns.ann_flags,
                compiler_link_name=sys_anns.compiler_link_name,
                is_enum=true,
                is_error=e_node.is_error || sys_anns.compiler_link_name == "Error",
                is_interface=false,
                interfaces=null
            );
            c.struct_table.put(e_name, info);
            c.struct_id_map.put("" + new_id, info);
            if (info.is_error) {
                c.error_types.append(info);
            }
        }
        i += 1;
    }

    i = 0;
    while (i < len) {
        let base: Int = node_tag(stmts[i]);
        if (base == NODE_INTERFACE_DEF) {
            let node: InterfaceDefNode = get_interface_def_node(c.arena, stmts[i]);
            if (node.type_params is null || node.type_params.length() == 0) {
                let info: StructInfo = c.struct_table.lookup(c.current_package_prefix + node.name_tok.value);
                if (has_struct(info) && !resolve_interface_info(c, info, [], node.pos)) { return; }
            }
        }
        i += 1;
    }
}
func pre_register_globals(c: Compiler, node: NodeID) -> Void {
    let block: BlockNode = get_block_node(c.arena, node);
    let stmts: Vector(NodeID) = block.stmts;
    let len: Int = 0;
    if (stmts is !null) { len = stmts.length(); }
    let i: Int = 0;
    
    while (i < len) {
        let base: Int = node_tag(stmts[i]);
        if (base == NODE_VAR_DECL) {
            let var_decl: VarDeclareNode = get_var_decl_node(c.arena, stmts[i]);
            let var_name: String = var_decl.name_tok.value;
            let full_var_name: String = var_name;
            if (c.current_package_prefix != "") {
                full_var_name = c.current_package_prefix + var_name;
            }
            if (has_symbol(c.global_symbol_table.lookup(full_var_name))) {
                throw_name_error(var_decl.pos, "Global '" + full_var_name + "' is already defined");
                i += 1;
                continue;
            }
            // keep the declared type visible while module imports are bound
            let declared_type: Int = resolve_type(c, var_decl.type_node);
            c.global_symbol_table.put(full_var_name, SymbolInfo(reg="poison", type=declared_type, origin_type=declared_type, is_const=var_decl.is_const));
        }
        i += 1;
    }
}
func pre_register_funcs(c: Compiler, node: NodeID) -> Void {
    let block: BlockNode = get_block_node(c.arena, node);
    let stmts: Vector(NodeID) = block.stmts;
    let len: Int = 0;
    if (stmts is !null) { len = stmts.length(); }
    let i: Int = 0;
    
    while (i < len) {
        let base: Int = node_tag(stmts[i]);
        if (base == NODE_FUNC_DEF) {
            let f_node: FunctionDefNode = get_func_def_node(c.arena, stmts[i]);
            let raw_name: String = f_node.name_tok.value;

            if (f_node.type_params is !null && f_node.type_params.length() > 0) {
                let template_name: String = c.current_package_prefix + raw_name;
                if (has_template(c.generic_funcs.lookup(template_name)) || has_func(c.func_table.lookup(template_name))) {
                    throw_name_error(f_node.pos, "Function '" + template_name + "' is already defined.");
                    return;
                }
                c.generic_funcs.put(template_name, GenericTemplate(name=template_name, node=stmts[i], type_params=f_node.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                i += 1;
                continue;
            }
            
            let ret_type_id: Int = resolve_type(c, f_node.ret_type_tok);
            if (ret_type_id == TYPE_POISON) {
                i++;
                continue;
            }
            if (ret_type_id == TYPE_AUTO) {
                throw_type_error(f_node.pos, "Auto return type deduction is not supported yet.");
                return;
            }
            let arg_types: Vector(Struct) = [];
            let arg_names: Vector(String) = [];
            
            let params: Vector(ParamNode) = f_node.params;
            if (!check_duplicate_params(params, "function '" + raw_name + "'", f_node.pos)) { return; }
            let p_len: Int = 0; if (params is !null) { p_len = params.length(); }
            let p_idx: Int = 0;
            
            while (p_idx < p_len) {
                let p: ParamNode = params[p_idx];
                let p_id: Int = callable_param_type(c, p);
                if (p_id == TYPE_POISON) {
                    break;
                }
                if (p_id == TYPE_AUTO) {
                    throw_type_error(p.pos, "Auto cannot be used in function parameters.");
                    return;
                }
                arg_types.append(TypeListNode(type=p_id));
                arg_names.append(p.name_tok.value);
                p_idx += 1;
            }
            if (p_idx < p_len) {
                i++;
                continue;
            }

            if (raw_name == "main") {
                let valid_main: Bool = ret_type_id == TYPE_INT && p_len == 0;
                if (ret_type_id == TYPE_INT && p_len == 2) {
                    let first_arg: TypeListNode = arg_types[0];
                    let second_arg: TypeListNode = arg_types[1];
                    let pointer_base: SymbolInfo = c.ptr_base_map.lookup("" + second_arg.type);
                    if (first_arg.type == TYPE_INT && has_symbol(pointer_base) && 
                        pointer_base.type == TYPE_STRING) {
                        valid_main = true;
                    }
                }
                if (!valid_main) { throw_type_error(f_node.pos, "function 'main' must be 'func main() -> Int' or 'func main(argc: Int, ptr argv: String) -> Int'"); return; }
            }

            let sys_anns: SystemAnnResult = consume_annotations(c, f_node.annotations, raw_name);
            if ((sys_anns.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
                let layout_intrinsic: Bool = (raw_name == "size_of" || raw_name == "align_of") && sys_anns.intrinsic_name == raw_name;
                let print_intrinsic: Bool = raw_name == "print" &&
                                            (sys_anns.intrinsic_name == "print" || sys_anns.intrinsic_name.length() == 0);
                if (!layout_intrinsic && !print_intrinsic) {
                    throw_internal_compiler_error(f_node.pos, "Unknown intrinsic function '" + sys_anns.intrinsic_name + "'.");
                    return;
                }
                if (layout_intrinsic && (p_len != 0 || ret_type_id != TYPE_UINTSIZE)) {
                    throw_internal_compiler_error(f_node.pos, "Intrinsic '" + raw_name + "' must be declared as func " + raw_name + "() -> UIntSize.");
                    return;
                }
                if (print_intrinsic && (p_len != 3 || variadic_param_index(params) != 1 || ret_type_id != TYPE_VOID)) {
                    throw_internal_compiler_error(f_node.pos, "Intrinsic 'print' has an invalid standard library declaration.");
                    return;
                }
            }
            let func_key: String = raw_name;
            if (raw_name != "main") {
                func_key = c.current_package_prefix + raw_name;
            }

            let llvm_func_name: String = func_key;
            if ((sys_anns.ann_flags & FLAG_ANN_EXPORT) != 0 || raw_name == "main") {
                llvm_func_name = raw_name;
            } else {
                llvm_func_name = mangle_wl_name(c, c.current_package_prefix, raw_name, arg_types);
            }

            if (has_func(c.func_table.lookup(func_key)) || has_template(c.generic_funcs.lookup(func_key))) {
                throw_name_error(f_node.pos, "Function '" + func_key + "' is already defined.");
                return;
            }

            let f_info: FuncInfo = FuncInfo(name=llvm_func_name, base_name=raw_name, ret_type=ret_type_id, arg_types=arg_types, arg_names=arg_names, is_varargs=false, ann_flags=sys_anns.ann_flags, compiler_link_name=sys_anns.compiler_link_name, mutates_self=false, variadic_param=variadic_param_index(params), default_args=param_defaults(params));
            if ((sys_anns.ann_flags & FLAG_ANN_COMP_LINK) != 0 && f_info.variadic_param > 0) {
                throw_type_error(f_node.pos, "CompilerLink functions cannot declare variadic parameters.");
                return;
            }
            c.func_table.put(func_key, f_info);

            if ((sys_anns.ann_flags & FLAG_ANN_COMP_LINK) != 0) {
                c.compiler_link.put(sys_anns.compiler_link_name, func_key);
            }

        } else if (base == NODE_CLASS_DEF) {
            let c_node: ClassDefNode = get_class_def_node(c.arena, stmts[i]);
            if (c_node.type_params is !null && c_node.type_params.length() > 0) {
                i += 1;
                continue;
            }

            let raw_name: String = c_node.name_tok.value;
            let c_name: String = c.current_package_prefix + raw_name;
            let m_vec: Vector(NodeID) = c_node.methods;
            let m_len: Int = 0; if (m_vec is !null) { m_len = m_vec.length(); }

            let c_info: StructInfo = c.struct_table.lookup(c_name);
            let class_type_id: Int = c_info.type_id;

            let m_idx: Int = 0;
            while (m_idx < m_len) {
                let m_node: MethodDefNode = get_method_def_node(c.arena, m_vec[m_idx]);
                let m_raw_name: String = method_base_name(c, m_node);

                if (m_node.type_params is !null && m_node.type_params.length() > 0) {
                    let method_key: String = c_name + "_" + m_raw_name;
                    if (has_template(c.generic_methods.lookup(method_key)) || has_func(c.func_table.lookup(method_key))) {
                        throw_name_error(m_node.pos, "Method '" + method_key + "' is already defined.");
                        return;
                    }
                    c.generic_methods.put(method_key, GenericTemplate(name=method_key, node=m_vec[m_idx], type_params=m_node.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                    m_idx++;
                    continue;
                }

                let ret_id: Int = resolve_type(c, m_node.return_type);
                if (ret_id == TYPE_POISON) {
                    m_idx++;
                    continue;
                }
                if (ret_id == TYPE_AUTO) { 
                    throw_type_error(m_node.pos, "Auto return type deduction is not supported in methods."); 
                    return; 
                }
                if (m_node.name_tok.value == "$type") {
                    let target_id: Int = ret_id;
                    if (is_fallible_type(c, target_id)) {
                        target_id = get_inner_fallible_type(c, target_id);
                    }
                    if (!is_conversion_target(c, target_id)) {
                        throw_type_error(m_node.pos, "Conversion target " + get_type_name(c, target_id) + " is not a built-in value type");
                    }
                }
                let arg_types: Vector(Struct) = [];
                let arg_names: Vector(String) = ["self"];

                arg_types.append(TypeListNode(type=class_type_id));
                
                let p_vec: Vector(ParamNode) = m_node.params;
                if (!check_duplicate_params(p_vec, "method '" + m_raw_name + "'", m_node.pos)) { return; }
                let p_len: Int = 0; if (p_vec is !null) { p_len = p_vec.length(); }
                let p_idx: Int = 0;
                while (p_idx < p_len) {
                    let p: ParamNode = p_vec[p_idx];
                    let p_type: Int = callable_param_type(c, p);
                    if (p_type == TYPE_POISON) {
                        break;
                    }
                    if (p_type == TYPE_AUTO) { 
                        throw_type_error(p.pos, "Auto cannot be used in method parameters."); 
                        return; 
                    }
                    arg_types.append(TypeListNode(type=p_type));
                    arg_names.append(p.name_tok.value);
                    p_idx += 1;
                }
                if (p_idx < p_len) {
                    m_idx++;
                    continue;
                }

                let m_key: String = c_name + "_" + m_raw_name;
                let m_llvm_name: String = mangle_wl_name(c, c_name + ".", m_raw_name, arg_types);
                
                if (has_func(c.func_table.lookup(m_key)) || has_template(c.generic_methods.lookup(m_key))) {
                    if (m_node.name_tok.value == "$type") {
                        let target_id: Int = ret_id;
                        if (is_fallible_type(c, target_id)) {
                            target_id = get_inner_fallible_type(c, target_id);
                        }
                        throw_name_error(m_node.pos, "class '" + c_name + "' already defines a conversion to " + get_type_name(c, target_id));
                    } else {
                        throw_name_error(m_node.pos, "method '" + m_key + "' is already defined.");
                    }
                    return;
                }

                let f_info: FuncInfo = FuncInfo(name=m_llvm_name, base_name=m_raw_name, ret_type=ret_id, arg_types=arg_types, arg_names=arg_names, is_varargs=false, mutates_self=method_mutates_self(c, m_node.body), variadic_param=variadic_param_index(p_vec), default_args=param_defaults(p_vec));
                c.func_table.put(m_key, f_info);
                m_idx += 1;
            }
        }
        i += 1;
    }
}
