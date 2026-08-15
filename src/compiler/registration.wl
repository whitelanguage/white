// compiler/registration.wl
import * from "../frontend/ast.wl"
import * from "context.wl"
import * from "../frontend/diagnostics.wl"
import * from "lowering/dictionary.wl"
import * from "validation.wl"

func pre_register_structs(c: Compiler, node: Struct) -> Void {
    let block: BlockNode = node;
    let stmts: Vector(Struct) = block.stmts;
    let len: Int = 0;
    if (stmts is !null) { len = stmts.length(); }
    let i: Int = 0;
    
    while (i < len) {
        let base: BaseNode = stmts[i];
        if (base.type == NODE_STRUCT_DEF) {
            let n: StructDefNode = stmts[i];
            let raw_name: String = n.name_tok.value;
            let s_name: String = c.current_package_prefix + raw_name;

            if (n.type_params is !null && n.type_params.length() > 0) {
                if (c.generic_structs.lookup(s_name) is !null || c.struct_table.lookup(s_name) is !null) {
                    throw_name_error(n.pos, "Type '" + s_name + "' is already defined");
                    i += 1;
                    continue;
                }
                c.generic_structs.put(s_name, GenericTemplate(name=s_name, node=n, type_params=n.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                i += 1;
                continue;
            }

            // for dict.wl
            let sys_anns: SystemAnnResult = consume_annotations(n.annotations, raw_name);
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
            if (c.struct_table.lookup(s_name) is !null || c.generic_structs.lookup(s_name) is !null) {
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
            
        } else if (base.type == NODE_CLASS_DEF) {
            let c_node: ClassDefNode = stmts[i];
            let raw_name: String = c_node.name_tok.value;
            let c_name: String = c.current_package_prefix + raw_name;
            if (c_node.type_params is !null && c_node.type_params.length() > 0) {
                if (c.generic_structs.lookup(c_name) is !null || (c.struct_table.lookup(c_name) is !null && c_name != "dict.Dict")) {
                    throw_name_error(c_node.pos, "Type '" + c_name + "' is already defined");
                    i += 1;
                    continue;
                }

                c.generic_structs.put(c_name, GenericTemplate(name=c_name, node=c_node, type_params=c_node.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                i++;
                continue;
            }
            if (c.struct_table.lookup(c_name) is !null || (c.generic_structs.lookup(c_name) is !null && c_name != "dict.Dict")) {
                throw_name_error(c_node.pos, "Type '" + c_name + "' is already defined");
                i += 1;
                continue;
            }
            let sys_anns: SystemAnnResult = consume_annotations(c_node.annotations, raw_name);
            let new_id: Int = c.type_counter;
            c.type_counter += 1;
            let info: StructInfo = StructInfo(
                name=c_name, 
                type_id=new_id, 
                fields=null, 
                llvm_name="%class." + c_name, 
                init_body=c_node, 
                is_class=true, 
                vtable_name="@vtable." + c_name, 
                parent_id=0, 
                vtable=null,
                ann_flags=sys_anns.ann_flags,
                compiler_link_name=sys_anns.compiler_link_name,
                is_enum=false,
                is_error=false,
                is_interface=false,
                interfaces=c_node.interfaces
            );
            c.struct_table.put(c_name, info);
            c.struct_id_map.put("" + new_id, info);
        } else if (base.type == NODE_INTERFACE_DEF) {
            let i_node: InterfaceDefNode = stmts[i];
            let raw_name: String = i_node.name_tok.value;
            let i_name: String = c.current_package_prefix + raw_name;
            if (c.struct_table.lookup(i_name) is !null || c.generic_structs.lookup(i_name) is !null) {
                throw_name_error(i_node.pos, "Type '" + i_name + "' is already defined");
                i += 1;
                continue;
            }
            if (i_node.type_params is !null && i_node.type_params.length() > 0) {
                c.generic_structs.put(i_name, GenericTemplate(name=i_name, node=i_node, type_params=i_node.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                i++;
                continue;
            }
            let method_names: Dict(String, StringConstant) = Dict();
            let method_index: Int = 0;
            while (i_node.methods is !null && method_index < i_node.methods.length()) {
                let iface_method: MethodDefNode = i_node.methods[method_index];
                let method_name: String = iface_method.name_tok.value;
                if (iface_method.type_params is !null && iface_method.type_params.length() > 0) {
                    throw_type_error(iface_method.pos, "Interface methods cannot declare type parameters.");
                    break;
                }
                if (method_names.contains_key(method_name)) { throw_name_error(iface_method.pos, "method '" + method_name + "' is already declared in interface '" + i_name + "'"); break; }
                method_names.put(method_name, StringConstant(id=0, value=method_name));
                check_duplicate_params(iface_method.params, "interface method '" + method_name + "'", iface_method.pos);
                method_index += 1;
            }
            let sys_anns: SystemAnnResult = consume_annotations(null, raw_name);
            let new_id: Int = c.type_counter;
            c.type_counter += 1;
            let info: StructInfo = StructInfo(
                name=i_name, 
                type_id=new_id, 
                fields=null, 
                llvm_name="{ i8*, i8* }", 
                init_body=null, 
                is_class=false, 
                vtable_name="", 
                parent_id=0, 
                vtable=i_node.methods,
                ann_flags=sys_anns.ann_flags,
                compiler_link_name=sys_anns.compiler_link_name,
                is_enum=false,
                is_error=false,
                is_interface=true,
                interfaces=null
            );
            c.struct_table.put(i_name, info);
            c.struct_id_map.put("" + new_id, info);
        } else if (base.type == NODE_ENUM_DEF) {
            let e_node: EnumDefNode = stmts[i];
            let raw_name: String = e_node.name_tok.value;
            let e_name: String = c.current_package_prefix + raw_name;
            if (c.struct_table.lookup(e_name) is !null) { throw_name_error(e_node.pos, "Type '" + e_name + "' is already defined"); i += 1; continue; }
            let sys_anns: SystemAnnResult = consume_annotations(e_node.annotations, raw_name);
            let new_id: Int = c.type_counter;
            c.type_counter += 1;
            
            let info: StructInfo = StructInfo(
                name=e_name, 
                type_id=new_id, 
                fields=[], 
                llvm_name="i32", 
                init_body=null, 
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
}
func pre_register_globals(c: Compiler, node: Struct) -> Void {
    let block: BlockNode = node;
    let stmts: Vector(Struct) = block.stmts;
    let len: Int = 0;
    if (stmts is !null) { len = stmts.length(); }
    let i: Int = 0;
    
    while (i < len) {
        let base: BaseNode = stmts[i];
        if (base.type == NODE_VAR_DECL) {
            let var_decl: VarDeclareNode = stmts[i];
            let var_name: String = var_decl.name_tok.value;
            let full_var_name: String = var_name;
            if (c.current_package_prefix != "") {
                full_var_name = c.current_package_prefix + var_name;
            }
            if (c.global_symbol_table.lookup(full_var_name) is !null) {
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
func pre_register_funcs(c: Compiler, node: Struct) -> Void {
    let block: BlockNode = node;
    let stmts: Vector(Struct) = block.stmts;
    let len: Int = 0;
    if (stmts is !null) { len = stmts.length(); }
    let i: Int = 0;
    
    while (i < len) {
        let base: BaseNode = stmts[i];
        if (base.type == NODE_FUNC_DEF) {
            let f_node: FunctionDefNode = stmts[i];
            let raw_name: String = f_node.name_tok.value;

            if (f_node.type_params is !null && f_node.type_params.length() > 0) {
                let template_name: String = c.current_package_prefix + raw_name;
                if (c.generic_funcs.lookup(template_name) is !null || c.func_table.lookup(template_name) is !null) {
                    throw_name_error(f_node.pos, "Function '" + template_name + "' is already defined.");
                    return;
                }
                c.generic_funcs.put(template_name, GenericTemplate(name=template_name, node=f_node, type_params=f_node.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                i += 1;
                continue;
            }
            
            let ret_type_id: Int = resolve_type(c, f_node.ret_type_tok);
            if (ret_type_id == TYPE_AUTO) {
                throw_type_error(f_node.pos, "Auto return type deduction is not supported yet.");
                return;
            }
            let arg_types: Vector(Struct) = [];
            let arg_names: Vector(String) = [];
            
            let params: Vector(Struct) = f_node.params;
            if (!check_duplicate_params(params, "function '" + raw_name + "'", f_node.pos)) { return; }
            let p_len: Int = 0; if (params is !null) { p_len = params.length(); }
            let p_idx: Int = 0;
            
            while (p_idx < p_len) {
                let p: ParamNode = params[p_idx];
                let p_id: Int = resolve_type(c, p.type_tok);
                if (p_id == TYPE_AUTO) {
                    throw_type_error(p.pos, "Auto cannot be used in function parameters.");
                    return;
                }
                arg_types.append(TypeListNode(type=p_id));
                arg_names.append(p.name_tok.value);
                p_idx += 1;
            }

            if (raw_name == "main") {
                let valid_main: Bool = ret_type_id == TYPE_INT && p_len == 0;
                if (ret_type_id == TYPE_INT && p_len == 2) {
                    let first_arg: TypeListNode = arg_types[0];
                    let second_arg: TypeListNode = arg_types[1];
                    let pointer_base: SymbolInfo = c.ptr_base_map.lookup("" + second_arg.type);
                    if (first_arg.type == TYPE_INT && pointer_base is !null && pointer_base.type == TYPE_STRING) { valid_main = true; }
                }
                if (!valid_main) { throw_type_error(f_node.pos, "function 'main' must be 'func main() -> Int' or 'func main(argc: Int, ptr argv: String) -> Int'"); return; }
            }

            let sys_anns: SystemAnnResult = consume_annotations(f_node.annotations, raw_name);
            if ((sys_anns.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
                if ((raw_name != "size_of" && raw_name != "align_of") || sys_anns.intrinsic_name != raw_name) {
                    throw_internal_compiler_error(f_node.pos, "Unknown intrinsic function '" + sys_anns.intrinsic_name + "'.");
                    return;
                }
                if (p_len != 0 || ret_type_id != TYPE_UINTSIZE) {
                    throw_internal_compiler_error(f_node.pos, "Intrinsic '" + raw_name + "' must be declared as func " + raw_name + "() -> UIntSize.");
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

            if (c.func_table.lookup(func_key) is !null || c.generic_funcs.lookup(func_key) is !null) {
                throw_name_error(f_node.pos, "Function '" + func_key + "' is already defined.");
                return;
            }

            let f_info: FuncInfo = FuncInfo(name=llvm_func_name, base_name=raw_name, ret_type=ret_type_id, arg_types=arg_types, arg_names=arg_names, is_varargs=false, ann_flags=sys_anns.ann_flags, compiler_link_name=sys_anns.compiler_link_name, mutates_self=false);
            c.func_table.put(func_key, f_info);

            if ((sys_anns.ann_flags & FLAG_ANN_COMP_LINK) != 0) {
                c.compiler_link.put(sys_anns.compiler_link_name, func_key);
            }

        } else if (base.type == NODE_CLASS_DEF) {
            let c_node: ClassDefNode = stmts[i];
            if (c_node.type_params is !null && c_node.type_params.length() > 0) {
                i += 1;
                continue;
            }

            let raw_name: String = c_node.name_tok.value;
            let c_name: String = c.current_package_prefix + raw_name;
            let m_vec: Vector(Struct) = c_node.methods;
            let m_len: Int = 0; if (m_vec is !null) { m_len = m_vec.length(); }

            let c_info: StructInfo = c.struct_table.lookup(c_name);
            let class_type_id: Int = c_info.type_id;

            let m_idx: Int = 0;
            while (m_idx < m_len) {
                let m_node: MethodDefNode = m_vec[m_idx];
                let m_raw_name: String = method_base_name(c, m_node);

                if (m_node.type_params is !null && m_node.type_params.length() > 0) {
                    let method_key: String = c_name + "_" + m_raw_name;
                    if (c.generic_methods.lookup(method_key) is !null || c.func_table.lookup(method_key) is !null) {
                        throw_name_error(m_node.pos, "Method '" + method_key + "' is already defined.");
                        return;
                    }
                    c.generic_methods.put(method_key, GenericTemplate(name=method_key, node=m_node, type_params=m_node.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                    m_idx++;
                    continue;
                }

                let ret_id: Int = resolve_type(c, m_node.return_type);
                if (ret_id == TYPE_AUTO) { 
                    throw_type_error(m_node.pos, "Auto return type deduction is not supported in methods."); 
                    return; 
                }
                if (m_node.name_tok.value == "$type") {
                    let target_id: Int = ret_id;
                    if (is_fallible_type(c, target_id)) {
                        target_id = get_inner_fallible_type(c, target_id);
                    }
                    if (!is_conversion_target(target_id)) {
                        throw_type_error(m_node.pos, "Conversion target " + get_type_name(c, target_id) + " is not a built-in value type");
                    }
                }
                let arg_types: Vector(Struct) = [];
                let arg_names: Vector(String) = ["self"];

                arg_types.append(TypeListNode(type=class_type_id));
                
                let p_vec: Vector(Struct) = m_node.params;
                if (!check_duplicate_params(p_vec, "method '" + m_raw_name + "'", m_node.pos)) { return; }
                let p_len: Int = 0; if (p_vec is !null) { p_len = p_vec.length(); }
                let p_idx: Int = 0;
                while (p_idx < p_len) {
                    let p: ParamNode = p_vec[p_idx];
                    let p_type: Int = resolve_type(c, p.type_tok);
                    if (p_type == TYPE_AUTO) { 
                        throw_type_error(p.pos, "Auto cannot be used in method parameters."); 
                        return; 
                    }
                    arg_types.append(TypeListNode(type=p_type));
                    arg_names.append(p.name_tok.value);
                    p_idx += 1;
                }

                let m_key: String = c_name + "_" + m_raw_name;
                let m_llvm_name: String = mangle_wl_name(c, c_name + ".", m_raw_name, arg_types);
                
                if (c.func_table.lookup(m_key) is !null || c.generic_methods.lookup(m_key) is !null) {
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

                let f_info: FuncInfo = FuncInfo(name=m_llvm_name, base_name=m_raw_name, ret_type=ret_id, arg_types=arg_types, arg_names=arg_names, is_varargs=false, mutates_self=method_mutates_self(m_node.body));
                c.func_table.put(m_key, f_info);
                m_idx += 1;
            }
        }
        i += 1;
    }
}
