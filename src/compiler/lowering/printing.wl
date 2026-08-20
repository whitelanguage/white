// compiler/lowering/printing.wl
import * from "../../frontend/ast.wl"
import * from "../context.wl"
import * from "../../frontend/diagnostics.wl"
import * from "dictionary.wl"
import * from "numeric.wl"
import * from "casts.wl"
import * from "literals.wl"
import * from "ownership.wl"

func is_printable_type(c: Compiler, type_id: Int) -> Bool {
    type_id = get_repr_type(c, type_id);
    if (type_id == TYPE_POISON || is_fallible_type(c, type_id)) { return false; }
    if (type_id == TYPE_STRING || type_id == TYPE_CHAR || type_id == TYPE_ANY_ERROR ||
        type_id == TYPE_NULL || type_id == TYPE_NULLPTR || is_primitive_type(type_id) ||
        is_pointer_type(c, type_id) || type_id == TYPE_GENERIC_STRUCT || type_id == TYPE_GENERIC_CLASS) {
        return true;
    }
    if (type_id < 100) { return false; }
    return c.struct_id_map.lookup("" + type_id) is !null ||
           c.vector_base_map.lookup("" + type_id) is !null ||
           c.array_info_map.lookup("" + type_id) is !null;
}

func class_has_named_interface(c: Compiler, info: StructInfo, name: String) -> Bool {
    let current: StructInfo = info;
    while (current is !null) {
        let i: Int = 0;
        while (current.interfaces is !null && i < current.interfaces.length()) {
            let item: TypeListNode = current.interfaces[i];
            let interface_info: StructInfo = c.struct_id_map.lookup("" + item.type);
            if (interface_info is !null && interface_info.name == name) { return true; }
            i += 1;
        }

        if (current.parent_id == 0) { break; }
        current = c.struct_id_map.lookup("" + current.parent_id);
    }
    return false;
}

func interface_has_name(c: Compiler, info: StructInfo, name: String) -> Bool {
    if (info is null || !info.is_interface) { return false; }
    if (info.name == name) { return true; }

    let i: Int = 0;
    while (info.interfaces is !null && i < info.interfaces.length()) {
        let item: TypeListNode = info.interfaces[i];
        let parent: StructInfo = c.struct_id_map.lookup("" + item.type);
        if (parent is !null && parent.name == name) { return true; }
        i += 1;
    }
    return false;
}

func compile_interface_display(c: Compiler, reg: String, info: StructInfo, pos: Position) -> Bool {
    if (!interface_has_name(c, info, "formatting.Display")) { return false; }

    let method_index: Int = 0;
    let method_node: MethodDefNode = null;
    while (info.vtable is !null && method_index < info.vtable.length()) {
        let candidate: MethodDefNode = info.vtable[method_index];
        if (candidate.name_tok.value == "display") { method_node = candidate; break; }
        method_index += 1;
    }

    if (method_node is null) {
        throw_internal_compiler_error(pos, "Display method is missing from interface '" + info.name + "'.");
        return true;
    }

    let object: String = next_reg(c);
    let table: String = next_reg(c);
    c.output_file.write(c.indent + object + " = extractvalue { i8*, i8* } " + reg + ", 0\n");
    c.output_file.write(c.indent + table + " = extractvalue { i8*, i8* } " + reg + ", 1\n");

    let null_label: String = next_label(c);
    let value_label: String = next_label(c);
    let end_label: String = next_label(c);
    let is_null: String = next_reg(c);
    c.output_file.write(c.indent + is_null + " = icmp eq i8* " + object + ", null\n");
    c.output_file.write(c.indent + "br i1 " + is_null + ", label %" + null_label + ", label %" + value_label + "\n");

    c.output_file.write("\n" + null_label + ":\n");

    compile_print(c, "null", TYPE_NULL, pos, TYPE_NULL);

    c.output_file.write(c.indent + "br label %" + end_label + "\n");
    c.output_file.write("\n" + value_label + ":\n");

    let table_type: String = "[ " + info.vtable.length() + " x i8* ]";
    let typed_table: String = next_reg(c);
    c.output_file.write(c.indent + typed_table + " = bitcast i8* " + table + " to " + table_type + "*\n");

    let slot: String = next_reg(c);
    c.output_file.write(c.indent + slot + " = getelementptr inbounds " + table_type + ", " + table_type + "* " + typed_table + ", i32 0, i32 " + method_index + "\n");

    let method_raw: String = next_reg(c);
    c.output_file.write(c.indent + method_raw + " = load i8*, i8** " + slot + "\n");
    let method_ptr: String = next_reg(c);
    c.output_file.write(c.indent + method_ptr + " = bitcast i8* " + method_raw + " to " + interface_method_sig(c, info, method_node) + "\n");

    let text: String = next_reg(c);
    c.output_file.write(c.indent + text + " = call %struct.$String* " + method_ptr + "(i8* " + object + ")\n");

    compile_print(c, text, TYPE_STRING, pos, TYPE_STRING);
    emit_release_owned(c, CompileResult(reg=text, type=TYPE_STRING, owns_ref=true));

    c.output_file.write(c.indent + "br label %" + end_label + "\n");
    c.output_file.write("\n" + end_label + ":\n");

    return true;
}

func compile_display(c: Compiler, reg: String, info: StructInfo, pos: Position) -> Bool {
    if (!info.is_class || !class_has_named_interface(c, info, "formatting.Display")) { return false; }

    let method_index: Int = 0;
    let method_info: FuncInfo = null;
    while (info.vtable is !null && method_index < info.vtable.length()) {
        let candidate: FuncInfo = info.vtable[method_index];
        if (candidate.base_name == "display") {
            method_info = candidate;
            break;
        }
        method_index += 1;
    }

    if (method_info is null || method_info.ret_type != TYPE_STRING || method_info.arg_types.length() != 1) {
        throw_internal_compiler_error(pos, "Display implementation for '" + info.name + "' has an invalid signature.");
        return true;
    }

    queue_generic_class_method(c, info, method_info.base_name);

    let null_label: String = next_label(c);
    let value_label: String = next_label(c);
    let end_label: String = next_label(c);
    let is_null: String = next_reg(c);
    c.output_file.write(c.indent + is_null + " = icmp eq " + info.llvm_name + "* " + reg + ", null\n");
    c.output_file.write(c.indent + "br i1 " + is_null + ", label %" + null_label + ", label %" + value_label + "\n");

    c.output_file.write("\n" + null_label + ":\n");
    compile_print(c, "null", TYPE_NULL, pos, TYPE_NULL);
    c.output_file.write(c.indent + "br label %" + end_label + "\n");

    c.output_file.write("\n" + value_label + ":\n");
    let vptr_addr: String = next_reg(c);
    c.output_file.write(c.indent + vptr_addr + " = getelementptr inbounds " + info.llvm_name + ", " + info.llvm_name + "* " + reg + ", i32 0, i32 0\n");
    let vtable_raw: String = next_reg(c);
    c.output_file.write(c.indent + vtable_raw + " = load i8*, i8** " + vptr_addr + "\n");
    let vtable: String = next_reg(c);
    c.output_file.write(c.indent + vtable + " = bitcast i8* " + vtable_raw + " to " + class_vtable_type(c, info) + "*\n");
    let slot: String = next_reg(c);
    c.output_file.write(c.indent + slot + " = getelementptr inbounds " + class_vtable_type(c, info) + ", " + class_vtable_type(c, info) + "* " + vtable + ", i32 0, i32 " + method_index + "\n");

    let method_raw: String = next_reg(c);
    c.output_file.write(c.indent + method_raw + " = load i8*, i8** " + slot + "\n");
    let method_ptr: String = next_reg(c);

    let signature: String = get_func_sig_str(c, method_info);
    c.output_file.write(c.indent + method_ptr + " = bitcast i8* " + method_raw + " to " + signature + "\n");

    let text: String = next_reg(c);
    c.output_file.write(c.indent + text + " = call %struct.$String* " + method_ptr + "(" + info.llvm_name + "* " + reg + ")\n");

    compile_print(c, text, TYPE_STRING, pos, TYPE_STRING);
    emit_release_owned(c, CompileResult(reg=text, type=TYPE_STRING, owns_ref=true));

    c.output_file.write(c.indent + "br label %" + end_label + "\n");
    c.output_file.write("\n" + end_label + ":\n");

    return true;
}

func compile_print(c: Compiler, reg: String, type_id: Int, pos: Position, origin_id: Int) -> Void {
    type_id = get_repr_type(c, type_id);
    if (type_id == TYPE_POISON) { return; }
    if (is_fallible_type(c, type_id)) {
        throw_type_error(pos, "Fallible value must be handled with '?' before printing");
        return;
    }

    if (type_id == TYPE_INT128 || type_id == TYPE_UINT128) {
        let formatted: CompileResult = convert_to_string(c, CompileResult(reg=reg, type=type_id, origin_type=origin_id));
        compile_print(c, formatted.reg, TYPE_STRING, pos, TYPE_STRING);
        emit_release_owned(c, formatted);
        return;
    }

    if (type_id == TYPE_STRING) {
        let hook_raw_str: String = get_mangled_symbol(c, "print_bytes", pos);
        let label_null: String = next_label(c);
        let label_value: String = next_label(c);
        let label_end: String = next_label(c);
        let is_null: String = next_reg(c);

        c.output_file.write(c.indent + is_null + " = icmp eq %struct.$String* " + reg + ", null\n");
        c.output_file.write(c.indent + "br i1 " + is_null + ", label %" + label_null + ", label %" + label_value + "\n");

        c.output_file.write("\n" + label_null + ":\n");
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* null, i32 0)\n");
        c.output_file.write(c.indent + "br label %" + label_end + "\n");

        c.output_file.write("\n" + label_value + ":\n");
        let struct_reg: String = next_reg(c);
        let ptr_reg: String = next_reg(c);
        let len_field: String = next_reg(c);
        let len_reg: String = next_reg(c);
        c.output_file.write(c.indent + struct_reg + " = getelementptr inbounds %struct.$String, %struct.$String* " + reg + ", i32 0, i32 0\n");
        c.output_file.write(c.indent + ptr_reg + " = load i8*, i8** " + struct_reg + "\n");
        c.output_file.write(c.indent + len_field + " = getelementptr inbounds %struct.$String, %struct.$String* " + reg + ", i32 0, i32 1\n");
        c.output_file.write(c.indent + len_reg + " = load i32, i32* " + len_field + "\n");
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + ptr_reg + ", i32 " + len_reg + ")\n");
        c.output_file.write(c.indent + "br label %" + label_end + "\n");

        c.output_file.write("\n" + label_end + ":\n");
        return;
    }

    if (type_id == TYPE_CHAR) {
        let hook_char: String = get_mangled_symbol(c, "print_char", pos);
        c.output_file.write(c.indent + "call void @" + hook_char + "(i32 " + reg + ")\n");
        return;
    }

    if (type_id == TYPE_ANY_ERROR) {
        compile_print_error_internal(c, reg, pos);
        return;
    }

    if (type_id == TYPE_UINT64 || type_id == TYPE_UINTSIZE) {
        let formatted: CompileResult = convert_to_string(c, CompileResult(reg=reg, type=type_id, origin_type=origin_id));
        compile_print(c, formatted.reg, TYPE_STRING, pos, TYPE_STRING);
        emit_release_owned(c, formatted);
        return;
    }

    if (is_primitive_type(type_id)) {
        if (type_id == TYPE_INT || type_id == TYPE_INT8 || type_id == TYPE_INT16 || type_id == TYPE_UINT16) {
            let temp_res: CompileResult = CompileResult(reg=reg, type=type_id, origin_type=origin_id);
            if (type_id != TYPE_INT) { temp_res = promote_to_int(c, temp_res); }
            let hook_int: String = get_mangled_symbol(c, "print_int", pos);
            c.output_file.write(c.indent + "call void @" + hook_int + "(i32 " + temp_res.reg + ")\n");
            return;
        }
        if (type_id == TYPE_LONG || type_id == TYPE_UINT32 || type_id == TYPE_INTSIZE) {
            let temp_res: CompileResult = CompileResult(reg=reg, type=type_id, origin_type=origin_id);
            if (type_id != TYPE_LONG) { temp_res = promote_to_long(c, temp_res); }
            let hook_long: String = get_mangled_symbol(c, "print_long", pos);
            c.output_file.write(c.indent + "call void @" + hook_long + "(i64 " + temp_res.reg + ")\n");
            return;
        }
        if (type_id == TYPE_FLOAT || type_id == TYPE_FLOAT32) {
            let temp_res: CompileResult = CompileResult(reg=reg, type=type_id, origin_type=origin_id);
            if (type_id != TYPE_FLOAT) { temp_res = promote_to_float(c, temp_res); }
            let hook_float: String = get_mangled_symbol(c, "print_float", pos);
            c.output_file.write(c.indent + "call void @" + hook_float + "(double " + temp_res.reg + ")\n");
            return;
        }
        if (type_id == TYPE_BOOL) {
            let hook_bool: String = get_mangled_symbol(c, "print_bool", pos);
            c.output_file.write(c.indent + "call void @" + hook_bool + "(i1 " + reg + ")\n");
            return;
        }
        throw_type_error(pos, "Unsupported primitive type for printing.");
        return;
    }

    if (type_id == TYPE_NULL || type_id == TYPE_NULLPTR) {
        let hook_raw_str: String = get_mangled_symbol(c, "print_bytes", pos);
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([5 x i8], [5 x i8]* @.str_null, i32 0, i32 0), i32 4)\n");
        return;
    }

    if (is_pointer_type(c, type_id)) {
        let base_info: SymbolInfo = c.ptr_base_map.lookup("" + type_id);
        if (base_info is !null && base_info.type == TYPE_BYTE) {
            let hook_raw_str: String = get_mangled_symbol(c, "print_raw_string", pos);
            c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + reg + ")\n");
        } else {
            let hook_long: String = get_mangled_symbol(c, "print_long", pos);
            let p_to_i: String = next_reg(c);
            c.output_file.write(c.indent + p_to_i + " = ptrtoint i8* " + reg + " to i64\n");
            c.output_file.write(c.indent + "call void @" + hook_long + "(i64 " + p_to_i + ")\n");
        }
        return;
    }
    
    if (type_id == TYPE_GENERIC_STRUCT || type_id == TYPE_GENERIC_CLASS) {
        if (origin_id >= 100) {
            let s_info_real: StructInfo = c.struct_id_map.lookup("" + origin_id);
            if (s_info_real is !null) {
                let cast_reg: String = next_reg(c);
                c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + reg + " to " + s_info_real.llvm_name + "*\n");
                if (compile_display(c, cast_reg, s_info_real, pos)) { return; }
                compile_print_struct_internal(c, cast_reg, s_info_real, pos);
                return;
            }
        }
        let ptr_i64: String = next_reg(c);
        let hook_long: String = get_mangled_symbol(c, "print_long", pos);
        c.output_file.write(c.indent + ptr_i64 + " = ptrtoint i8* " + reg + " to i64\n");
        c.output_file.write(c.indent + "call void @" + hook_long + "(i64 " + ptr_i64 + ")\n");
        return;
    }
    
    if (type_id >= 100) {
        let s_info: StructInfo = c.struct_id_map.lookup("" + type_id);
        if (s_info is !null) {
            if (compile_interface_display(c, reg, s_info, pos)) { return; }
            if (compile_display(c, reg, s_info, pos)) { return; }
            if (s_info.name == "$Variant") {
                compile_print_variant_internal(c, reg, s_info, pos);
                return;
            }
            if (s_info.is_enum) {
                compile_print_enum_internal(c, reg, s_info, pos);
                return;
            }
            compile_print_struct_internal(c, reg, s_info, pos);
            return;
        }
        
        let v_info: SymbolInfo = c.vector_base_map.lookup("" + type_id);
        if (v_info is !null) {
            compile_print_vector_internal(c, reg, v_info, pos);
            return;
        }

        let arr_info: ArrayInfo = c.array_info_map.lookup("" + type_id);
        if (arr_info is !null) {
            compile_print_array_internal(c, reg, type_id, arr_info, pos);
            return;
        }
    }

    throw_type_error(pos, "Type " + get_type_name(c, type_id) + " cannot be printed.");
}

func compile_print_error_internal(c: Compiler, error_reg: String, pos: Position) -> Void {
    let domain: String = next_reg(c);
    let code: String = next_reg(c);
    let end_label: String = next_label(c);
    c.output_file.write(c.indent + domain + " = extractvalue { i64, i32 } " + error_reg + ", 0\n");
    c.output_file.write(c.indent + code + " = extractvalue { i64, i32 } " + error_reg + ", 1\n");

    let i: Int = 0;
    while (i < c.error_types.length()) {
        let info: StructInfo = c.error_types[i];
        let match_label: String = next_label(c);
        let next_type_label: String = next_label(c);
        let matches: String = next_reg(c);
        c.output_file.write(c.indent + matches + " = icmp eq i64 " + domain + ", " + type_fingerprint(c, info.type_id) + "\n");
        c.output_file.write(c.indent + "br i1 " + matches + ", label %" + match_label + ", label %" + next_type_label + "\n");

        c.output_file.write("\n" + match_label + ":\n");
        compile_print_enum_internal(c, code, info, pos);
        c.output_file.write(c.indent + "br label %" + end_label + "\n");

        c.output_file.write("\n" + next_type_label + ":\n");
        i += 1;
    }

    let hook_raw_str: String = get_mangled_symbol(c, "print_bytes", pos);
    let hook_int: String = get_mangled_symbol(c, "print_int", pos);
    let prefix: String = "Error(code=";
    let prefix_id: Int = register_string_constant(c, prefix);
    let prefix_ptr: String = get_string_ptr(prefix_id, prefix);
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + prefix_ptr + ", i32 " + prefix.length() + ")\n");
    c.output_file.write(c.indent + "call void @" + hook_int + "(i32 " + code + ")\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_close_paren, i32 0, i32 0), i32 1)\n");
    c.output_file.write(c.indent + "br label %" + end_label + "\n");

    c.output_file.write("\n" + end_label + ":\n");
}

func compile_print_enum_internal(c: Compiler, enum_reg: String, s_info: StructInfo, pos: Position) -> Void {
    let hook_raw_str: String = get_mangled_symbol(c, "print_bytes", pos);
    let default_label: String = next_label(c);
    let end_label: String = next_label(c);
    
    let fields: Vector(Struct) = s_info.fields;
    let len: Int = 0; if (fields is !null) { len = fields.length(); }
    
    c.output_file.write(c.indent + "switch i32 " + enum_reg + ", label %" + default_label + " [\n");
    
    let i: Int = 0;
    let labels: Vector(String) = [];
    while (i < len) {
        let f: FieldInfo = fields[i];
        let lbl: String = next_label(c);
        labels.append(lbl);
        c.output_file.write("    i32 " + f.offset + ", label %" + lbl + "\n");
        i += 1;
    }
    c.output_file.write("  ]\n");
    
    i = 0;
    while (i < len) {
        let f: FieldInfo = fields[i];
        let lbl: String = labels[i];
        c.output_file.write("\n" + lbl + ":\n");
        let name_str: String = s_info.name + "." + f.name;
        let id: Int = register_string_constant(c, name_str);
        let ptr_: String = get_string_ptr(id, name_str);
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + ptr_ + ", i32 " + name_str.length() + ")\n");
        c.output_file.write(c.indent + "br label %" + end_label + "\n");
        i += 1;
    }
    
    c.output_file.write("\n" + default_label + ":\n");
    let unk_str: String = s_info.name + "(<unknown>)";
    let unk_id: Int = register_string_constant(c, unk_str);
    let unk_ptr: String = get_string_ptr(unk_id, unk_str);
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + unk_ptr + ", i32 " + unk_str.length() + ")\n");
    c.output_file.write(c.indent + "br label %" + end_label + "\n");
    
    c.output_file.write("\n" + end_label + ":\n");
}

func compile_print_struct_internal(c: Compiler, obj_reg: String, s_info: StructInfo, pos: Position) -> Void {
    let hook_raw_str: String = get_mangled_symbol(c, "print_bytes", pos);
    let header: String = s_info.name + "(";
    let header_id: Int = register_string_constant(c, header);
    let header_ptr: String = get_string_ptr(header_id, header);
    
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + header_ptr + ", i32 " + header.length() + ")\n");

    let fields_vec: Vector(Struct) = s_info.fields;
    let f_len: Int = 0;
    if (fields_vec is !null) { f_len = fields_vec.length(); }
    let f_idx: Int = 0;
    
    while (f_idx < f_len) {
        let f_curr: FieldInfo = fields_vec[f_idx];
        if (f_curr.name == "_vptr") {
            f_idx += 1;
            continue;
        }
        let f_name_eq: String = f_curr.name + "=";
        let fn_id: Int = register_string_constant(c, f_name_eq);
        let fn_ptr: String = get_string_ptr(fn_id, f_name_eq);
    
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + fn_ptr + ", i32 " + f_name_eq.length() + ")\n");
        
        let f_ptr: String = next_reg(c);
        c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + obj_reg + ", i32 0, i32 " + f_curr.offset + "\n");
        let f_val_reg: String = next_reg(c);
        c.output_file.write(c.indent + f_val_reg + " = load " + f_curr.llvm_type + ", " + f_curr.llvm_type + "* " + f_ptr + "\n");
        compile_print(c, f_val_reg, f_curr.type, pos, f_curr.type); 

        f_idx += 1;
        if (f_idx < f_len) {
            c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([3 x i8], [3 x i8]* @.str_comma_space, i32 0, i32 0), i32 2)\n");
        }
    }
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_close_paren, i32 0, i32 0), i32 1)\n");
}

func compile_print_vector_internal(c: Compiler, vec_reg: String, v_info: SymbolInfo, pos: Position) -> Void {
    let hook_raw_str: String = get_mangled_symbol(c, "print_bytes", pos);
    let elem_type: Int = v_info.type;
    let elem_ty_str: String = get_llvm_type_str(c, elem_type);
    let struct_ty: String = get_vector_llvm_type(c, elem_type);
    let size_ty: String = get_size_llvm_type();

    let size_ptr: String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_reg + ", i32 0, i32 0\n");
    let size_val: String = next_reg(c);
    c.output_file.write(c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");
    
    let data_ptr_ptr: String = next_reg(c);
    c.output_file.write(c.indent + data_ptr_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_reg + ", i32 0, i32 2\n");
    let data_ptr: String = next_reg(c);
    c.output_file.write(c.indent + data_ptr + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_ptr_ptr + "\n");

    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_open_bracket, i32 0, i32 0), i32 1)\n");

    let label_cond: String = next_label(c);
    let label_body: String = next_label(c);
    let label_sep: String = next_label(c);
    let label_end: String = next_label(c);

    let idx_ptr: String = next_reg(c);
    c.output_file.write(c.indent + idx_ptr + " = alloca " + size_ty + "\n");
    c.output_file.write(c.indent + "store " + size_ty + " 0, " + size_ty + "* " + idx_ptr + "\n");
    c.output_file.write(c.indent + "br label %" + label_cond + "\n");

    c.output_file.write("\n" + label_cond + ":\n");
    let curr_idx: String = next_reg(c);
    c.output_file.write(c.indent + curr_idx + " = load " + size_ty + ", " + size_ty + "* " + idx_ptr + "\n");
    let cmp: String = next_reg(c);
    c.output_file.write(c.indent + cmp + " = icmp ult " + size_ty + " " + curr_idx + ", " + size_val + "\n");
    c.output_file.write(c.indent + "br i1 " + cmp + ", label %" + label_body + ", label %" + label_end + "\n");

    c.output_file.write("\n" + label_body + ":\n");
    let slot: String = next_reg(c);
    c.output_file.write(c.indent + slot + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", " + size_ty + " " + curr_idx + "\n");
    let val: String = next_reg(c);
    c.output_file.write(c.indent + val + " = load " + elem_ty_str + ", " + elem_ty_str + "* " + slot + "\n");
    
    compile_print(c, val, elem_type, pos, elem_type);

    let next_idx: String = next_reg(c);
    c.output_file.write(c.indent + next_idx + " = add " + size_ty + " " + curr_idx + ", 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + next_idx + ", " + size_ty + "* " + idx_ptr + "\n");
    
    let is_not_last: String = next_reg(c);
    c.output_file.write(c.indent + is_not_last + " = icmp ult " + size_ty + " " + next_idx + ", " + size_val + "\n");
    c.output_file.write(c.indent + "br i1 " + is_not_last + ", label %" + label_sep + ", label %" + label_cond + "\n");

    c.output_file.write("\n" + label_sep + ":\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([3 x i8], [3 x i8]* @.str_comma_space, i32 0, i32 0), i32 2)\n");
    c.output_file.write(c.indent + "br label %" + label_cond + "\n");

    c.output_file.write("\n" + label_end + ":\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_close_bracket, i32 0, i32 0), i32 1)\n");
}

func compile_print_array_internal(c: Compiler, arr_reg: String, type_id: Int, arr_info: ArrayInfo, pos: Position) -> Void {
    let hook_raw_str: String = get_mangled_symbol(c, "print_bytes", pos);
    let elem_type: Int = arr_info.base_type;
    let elem_ty_str: String = get_llvm_type_str(c, elem_type);

    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_open_bracket, i32 0, i32 0), i32 1)\n");

    let size_val: String = next_reg(c);
    let slice_parts: SliceParts = null;
    if (arr_info.size == -1) {
        slice_parts = emit_slice_parts(c, arr_reg, type_id, pos);
        let slice_length: String = emit_size_to_int(c, slice_parts.length);
        c.output_file.write(c.indent + size_val + " = add i32 0, " + slice_length + "\n");
    } else {
        c.output_file.write(c.indent + size_val + " = add i32 0, " + arr_info.size + "\n");
    }

    let data_ptr: String = "";
    if (arr_info.size == -1) {
        data_ptr = next_reg(c);
        c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + slice_parts.data + ", " + get_size_llvm_type() + " " + slice_parts.start + "\n");
    } else {
        data_ptr = next_reg(c);
        c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + arr_reg + ", i32 0, i32 0\n");
    }

    let label_cond: String = next_label(c);
    let label_body: String = next_label(c);
    let label_sep: String = next_label(c);
    let label_end: String = next_label(c);

    let idx_ptr: String = next_reg(c);
    c.output_file.write(c.indent + idx_ptr + " = alloca i32\n");
    c.output_file.write(c.indent + "store i32 0, i32* " + idx_ptr + "\n");
    c.output_file.write(c.indent + "br label %" + label_cond + "\n");

    c.output_file.write("\n" + label_cond + ":\n");
    let curr_idx: String = next_reg(c);
    c.output_file.write(c.indent + curr_idx + " = load i32, i32* " + idx_ptr + "\n");
    let cmp: String = next_reg(c);

    c.output_file.write(c.indent + cmp + " = icmp slt i32 " + curr_idx + ", " + size_val + "\n");
    c.output_file.write(c.indent + "br i1 " + cmp + ", label %" + label_body + ", label %" + label_end + "\n");

    c.output_file.write("\n" + label_body + ":\n");
    let slot_ptr: String = next_reg(c);

    c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", i32 " + curr_idx + "\n");
    
    let val_reg: String = "";
    if (c.array_info_map.lookup("" + elem_type) is !null) {
        val_reg = slot_ptr;
    } else {
        val_reg = next_reg(c);
        c.output_file.write(c.indent + val_reg + " = load " + elem_ty_str + ", " + elem_ty_str + "* " + slot_ptr + "\n");
    }
    
    compile_print(c, val_reg, elem_type, pos, elem_type);

    let next_idx: String = next_reg(c);
    c.output_file.write(c.indent + next_idx + " = add i32 " + curr_idx + ", 1\n");
    c.output_file.write(c.indent + "store i32 " + next_idx + ", i32* " + idx_ptr + "\n");
    
    let is_not_last: String = next_reg(c);
    c.output_file.write(c.indent + is_not_last + " = icmp slt i32 " + next_idx + ", " + size_val + "\n");
    c.output_file.write(c.indent + "br i1 " + is_not_last + ", label %" + label_sep + ", label %" + label_cond + "\n");

    c.output_file.write("\n" + label_sep + ":\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([3 x i8], [3 x i8]* @.str_comma_space, i32 0, i32 0), i32 2)\n");
    c.output_file.write(c.indent + "br label %" + label_cond + "\n");

    c.output_file.write("\n" + label_end + ":\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_close_bracket, i32 0, i32 0), i32 1)\n");
}

func compile_print_variant_internal(c: Compiler, variant_reg: String, v_info: StructInfo, pos: Position) -> Void {
    let hook_raw_str: String = get_mangled_symbol(c, "print_bytes", pos);
    let variant_llvm: String = v_info.llvm_name;

    let is_null: String = next_reg(c);
    c.output_file.write(c.indent + is_null + " = icmp eq " + variant_llvm + "* " + variant_reg + ", null\n");
    let label_null_print: String = "var_null_print_" + c.type_counter;
    let label_not_null: String = "var_not_null_" + c.type_counter;
    let label_end: String = "var_end_" + c.type_counter;
    c.type_counter += 1;

    c.output_file.write(c.indent + "br i1 " + is_null + ", label %" + label_null_print + ", label %" + label_not_null + "\n");

    c.output_file.write("\n" + label_null_print + ":\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([5 x i8], [5 x i8]* @.str_null, i32 0, i32 0), i32 4)\n");
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_not_null + ":\n");

    let type_id_ptr: String = next_reg(c);
    c.output_file.write(c.indent + type_id_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + variant_reg + ", i32 0, i32 0\n");
    let type_id_reg: String = next_reg(c);
    c.output_file.write(c.indent + type_id_reg + " = load i64, i64* " + type_id_ptr + "\n");

    let payload_low_ptr: String = next_reg(c);
    c.output_file.write(c.indent + payload_low_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + variant_reg + ", i32 0, i32 1\n");
    let payload_low: String = next_reg(c);
    c.output_file.write(c.indent + payload_low + " = load i64, i64* " + payload_low_ptr + "\n");
    let payload_high_ptr: String = next_reg(c);
    c.output_file.write(c.indent + payload_high_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + variant_reg + ", i32 0, i32 2\n");
    let payload_high: String = next_reg(c);
    c.output_file.write(c.indent + payload_high + " = load i64, i64* " + payload_high_ptr + "\n");

    let label_null: String = "var_null_" + c.type_counter;
    let label_int: String = "var_int_" + c.type_counter;
    let label_long: String = "var_long_" + c.type_counter;
    let label_float: String = "var_float_" + c.type_counter;
    let label_bool: String = "var_bool_" + c.type_counter;
    let label_string: String = "var_string_" + c.type_counter;
    let label_char: String = "var_char_" + c.type_counter;
    let label_int128: String = "var_int128_" + c.type_counter;
    let label_uint128: String = "var_uint128_" + c.type_counter;
    let label_default: String = "var_default_" + c.type_counter;
    c.type_counter += 1;

    c.output_file.write(c.indent + "switch i64 " + type_id_reg + ", label %" + label_default + " [\n");
    c.output_file.write("    i64 0, label %" + label_null + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_INT) + ", label %" + label_int + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_LONG) + ", label %" + label_long + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_FLOAT) + ", label %" + label_float + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_BOOL) + ", label %" + label_bool + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_STRING) + ", label %" + label_string + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_CHAR) + ", label %" + label_char + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_INT128) + ", label %" + label_int128 + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_UINT128) + ", label %" + label_uint128 + "\n");
    c.output_file.write("  ]\n");

    // null
    c.output_file.write("\n" + label_null + ":\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([5 x i8], [5 x i8]* @.str_null, i32 0, i32 0), i32 4)\n");
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_int + ":\n");
    let unboxed_int: String = next_reg(c);
    c.output_file.write(c.indent + unboxed_int + " = trunc i64 " + payload_low + " to i32\n");
    compile_print(c, unboxed_int, TYPE_INT, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_long + ":\n");
    compile_print(c, payload_low, TYPE_LONG, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_float + ":\n");
    let unboxed_float: String = next_reg(c);
    c.output_file.write(c.indent + unboxed_float + " = bitcast i64 " + payload_low + " to double\n");
    compile_print(c, unboxed_float, TYPE_FLOAT, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");
    
    c.output_file.write("\n" + label_bool + ":\n");
    let unboxed_bool: String = next_reg(c);
    c.output_file.write(c.indent + unboxed_bool + " = trunc i64 " + payload_low + " to i1\n");
    compile_print(c, unboxed_bool, TYPE_BOOL, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_string + ":\n");
    let unboxed_str: String = next_reg(c);
    c.output_file.write(c.indent + unboxed_str + " = inttoptr i64 " + payload_low + " to %struct.$String*\n");
    compile_print(c, unboxed_str, TYPE_STRING, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_char + ":\n");
    let unboxed_char: String = next_reg(c);
    c.output_file.write(c.indent + unboxed_char + " = trunc i64 " + payload_low + " to i32\n");
    compile_print(c, unboxed_char, TYPE_CHAR, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_int128 + ":\n");
    let unboxed_int128: String = combine_i128_words(c, payload_low, payload_high);
    compile_print(c, unboxed_int128, TYPE_INT128, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_uint128 + ":\n");
    let unboxed_uint128: String = combine_i128_words(c, payload_low, payload_high);
    compile_print(c, unboxed_uint128, TYPE_UINT128, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    // other object
    c.output_file.write("\n" + label_default + ":\n");
    let hook_long: String = get_mangled_symbol(c, "print_long", pos);
    c.output_file.write(c.indent + "call void @" + hook_long + "(i64 " + payload_low + ")\n");
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_end + ":\n");
}

