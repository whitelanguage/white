// compiler/lowering/ownership.wl
import Dict from "dict"
import * from "../../frontend/ast.wl"
import * from "../context.wl"
import * from "../../frontend/diagnostics.wl"
import * from "../validation.wl"
import * from "dictionary.wl"
import * from "literals.wl"
import * from "../target.wl"

func enter_scope(c: Compiler) -> Void {
    let new_scope: Scope = Scope(table=Dict(), parent=c.symbol_table, gc_vars=[], depth=c.scope_depth + 1);
    c.symbol_table = new_scope;
    c.scope_depth += 1;
}
func exit_scope(c: Compiler) -> Void {
    let curr_scope: Scope = c.symbol_table;

    let gc_vec: Vector(Struct) = curr_scope.gc_vars;
    let gc_len: Int = 0; if (gc_vec is !null) { gc_len = gc_vec.length(); }
    let gc_idx: Int = 0;
    while (gc_idx < gc_len) {
        let curr_gc: GCTracker = gc_vec[gc_idx];
        emit_drop_slot(c, curr_gc.reg, curr_gc.type);
        gc_idx += 1;
    }

    if (c.symbol_table.parent is !null) {
        c.symbol_table = c.symbol_table.parent;
    }
    c.scope_depth -= 1;
}
func cleanup_all_scopes(c: Compiler) -> Void {
    let curr: Scope = c.symbol_table;
    while (curr is !null) { 
        let gc_vec: Vector(Struct) = curr.gc_vars;
        let gc_len: Int = 0; if (gc_vec is !null) { gc_len = gc_vec.length(); }
        let gc_idx: Int = 0;
        while (gc_idx < gc_len) {
            let gc_node: GCTracker = gc_vec[gc_idx];
            emit_drop_slot(c, gc_node.reg, gc_node.type);
            gc_idx += 1;
        }
        curr = curr.parent;
    }
}

func cleanup_scopes_until(c: Compiler, target_scope: Scope) -> Void {
    let curr: Scope = c.symbol_table;
    while (curr is !null && curr.depth > target_scope.depth) { 
        let gc_vec: Vector(Struct) = curr.gc_vars;
        let gc_len: Int = 0; if (gc_vec is !null) { gc_len = gc_vec.length(); }
        let gc_idx: Int = 0;
        while (gc_idx < gc_len) {
            let gc_node: GCTracker = gc_vec[gc_idx];
            emit_drop_slot(c, gc_node.reg, gc_node.type);
            gc_idx += 1;
        }
        curr = curr.parent;
    }
}


func emit_retain(c: Compiler, reg: String, type_id: Int) -> Void {
// strong cycles remain the caller's responsibility until weak references are added

    if (!is_ref_type(c, type_id)) { return; }
    
    let s_info: StructInfo = c.struct_id_map.lookup("" + type_id);
    if (s_info is !null && s_info.is_interface) {
        let obj_ptr: String = next_reg(c);
        c.output_file.write(c.indent + obj_ptr + " = extractvalue { i8*, i8* } " + reg + ", 0\n");
        c.output_file.write(c.indent + "call void @__wl_retain(i8* " + obj_ptr + ")\n");
        return;
    }

    // arc hooks use an erased pointer; interface values keep the object in field zero
    let cast_reg: String = next_reg(c);
    let src_ty: String = get_llvm_type_str(c, type_id);
    if (src_ty == "i8*") {
        c.output_file.write(c.indent + "call void @__wl_retain(i8* " + reg + ")\n");
        return;
    }
    c.output_file.write(c.indent + cast_reg + " = bitcast " + src_ty + " " + reg + " to i8*\n");
    c.output_file.write(c.indent + "call void @__wl_retain(i8* " + cast_reg + ")\n");
}

func emit_release(c: Compiler, reg: String, type_id: Int) -> Void {
    if (!is_ref_type(c, type_id)) { return; }

    let s_info: StructInfo = c.struct_id_map.lookup("" + type_id);
    if (s_info is !null && s_info.is_interface) {
        let obj_ptr: String = next_reg(c);
        c.output_file.write(c.indent + obj_ptr + " = extractvalue { i8*, i8* } " + reg + ", 0\n");
        c.output_file.write(c.indent + "call void @__wl_release(i8* " + obj_ptr + ")\n");
        return;
    }

    let cast_reg: String = next_reg(c);
    let src_ty: String = get_llvm_type_str(c, type_id);
    if (src_ty == "i8*") {
        c.output_file.write(c.indent + "call void @__wl_release(i8* " + reg + ")\n");
        return;
    }
    c.output_file.write(c.indent + cast_reg + " = bitcast " + src_ty + " " + reg + " to i8*\n");
    c.output_file.write(c.indent + "call void @__wl_release(i8* " + cast_reg + ")\n");
}

func emit_retain_value(c: Compiler, reg: String, type_id: Int) -> Void {
    if (is_ref_type(c, type_id)) {
        emit_retain(c, reg, type_id);
        return;
    }
    if (is_fallible_type(c, type_id) && needs_drop(c, type_id)) {
        let llvm_ty: String = get_llvm_type_str(c, type_id);
        let slot: String = next_reg(c);
        c.output_file.write(c.indent + slot + " = alloca " + llvm_ty + "\n");
        c.output_file.write(c.indent + "store " + llvm_ty + " " + reg + ", " + llvm_ty + "* " + slot + "\n");
        emit_retain_slot(c, slot, type_id);
    }
}

func emit_drop_value(c: Compiler, reg: String, type_id: Int) -> Void {
    if (is_ref_type(c, type_id)) {
        emit_release(c, reg, type_id);
        return;
    }
    if (is_fallible_type(c, type_id) && needs_drop(c, type_id)) {
        let llvm_ty: String = get_llvm_type_str(c, type_id);
        let slot: String = next_reg(c);
        c.output_file.write(c.indent + slot + " = alloca " + llvm_ty + "\n");
        c.output_file.write(c.indent + "store " + llvm_ty + " " + reg + ", " + llvm_ty + "* " + slot + "\n");
        emit_drop_slot(c, slot, type_id);
    }
}

func emit_release_owned(c: Compiler, value: CompileResult) -> Void {
    if (value is null || !value.owns_ref) { return; }
    if (is_void_ptr(c, value.type) && is_ref_type(c, value.origin_type)) {
        c.output_file.write(c.indent + "call void @__wl_release(i8* " + value.reg + ")\n");
        return;
    }
    emit_drop_value(c, value.reg, value.type);
}

func emit_release_owned_args(c: Compiler, values: Vector(Struct)) -> Void {
    let i: Int = 0;
    while (i < values.length()) {
        let value: CompileResult = values[i];
        emit_release_owned(c, value);
        i += 1;
    }
}

func emit_alloc_check(c: Compiler, ptr_reg: String) -> Void {
    let failed: String = next_reg(c);
    c.output_file.write(c.indent + failed + " = icmp eq i8* " + ptr_reg + ", null\n");
    let fail_label: String = next_label(c);
    let ok_label: String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + failed + ", label %" + fail_label + ", label %" + ok_label + "\n");
    c.output_file.write("\n" + fail_label + ":\n");
    c.output_file.write(c.indent + "call void @__wl_oom()\n");
    c.output_file.write(c.indent + "unreachable\n");
    c.output_file.write("\n" + ok_label + ":\n");
}

func emit_alloc_obj(c: Compiler, payload_size_reg: String, type_id_str: String, dest_llvm_type: String) -> String {
    let header_size: Int = 16;
    if (type_id_str == "" + TYPE_STRING) { header_size = 8; }
    let size_ty: String = get_size_llvm_type();

    let total_size: String = next_reg(c);
    c.output_file.write(c.indent + total_size + " = add " + size_ty + " " + payload_size_reg + ", " + header_size + "\n");
    
    let raw_mem: String = next_reg(c);
    let alloc_hook: String = get_mangled_symbol(c, "memory_alloc", null);
    c.output_file.write(c.indent + raw_mem + " = call i8* @" + alloc_hook + "(" + size_ty + " " + total_size + ")\n");
    emit_alloc_check(c, raw_mem);

    let header_mem: String = raw_mem;
    if (header_size == 16) {
        let drop_slot: String = next_reg(c);
        c.output_file.write(c.indent + drop_slot + " = bitcast i8* " + raw_mem + " to i8**\n");
        let drop_fn: String = next_reg(c);
        c.output_file.write(c.indent + drop_fn + " = bitcast void (i8*)* @__wl_drop." + type_id_str + " to i8*\n");
        c.output_file.write(c.indent + "store i8* " + drop_fn + ", i8** " + drop_slot + "\n");

        header_mem = next_reg(c);
        c.output_file.write(c.indent + header_mem + " = getelementptr inbounds i8, i8* " + raw_mem + ", i32 8\n");
    }
    
    let rc_ptr: String = next_reg(c);
    c.output_file.write(c.indent + rc_ptr + " = bitcast i8* " + header_mem + " to i32*\n");
    c.output_file.write(c.indent + "store i32 0, i32* " + rc_ptr + "\n");
    
    let type_ptr_i8: String = next_reg(c);
    c.output_file.write(c.indent + type_ptr_i8 + " = getelementptr inbounds i8, i8* " + header_mem + ", i32 4\n");
    let type_ptr: String = next_reg(c);
    c.output_file.write(c.indent + type_ptr + " = bitcast i8* " + type_ptr_i8 + " to i32*\n");
    c.output_file.write(c.indent + "store i32 " + type_id_str + ", i32* " + type_ptr + "\n");
    
    let payload_i8: String = next_reg(c);
    c.output_file.write(c.indent + payload_i8 + " = getelementptr inbounds i8, i8* " + header_mem + ", i32 8\n");
    
    if (dest_llvm_type == "i8*") {
        return payload_i8; 
    }
    
    let final_ptr: String = next_reg(c);
    c.output_file.write(c.indent + final_ptr + " = bitcast i8* " + payload_i8 + " to " + dest_llvm_type + "\n");
    return final_ptr;
}

func emit_alloc_closure(c: Compiler, type_id: Int) -> String {
    let closure: String = emit_alloc_obj(c, "" + closure_payload_size(), "" + TYPE_GENERIC_FUNCTION, "i8*");
    let tag_bytes: String = next_reg(c);
    let tag_slot: String = next_reg(c);
    c.output_file.write(c.indent + tag_bytes + " = getelementptr inbounds i8, i8* " + closure + ", i32 -4\n");
    c.output_file.write(c.indent + tag_slot + " = bitcast i8* " + tag_bytes + " to i32*\n");
    c.output_file.write(c.indent + "store i32 " + type_id + ", i32* " + tag_slot + "\n");
    return closure;
}

func erased_struct_compatible(c: Compiler, actual: Int, expected: Int) -> Bool {
    if (actual == expected) { return true; }

    let actual_info: StructInfo = c.struct_id_map.lookup("" + actual);
    let expected_info: StructInfo = c.struct_id_map.lookup("" + expected);
    if (actual_info is null || expected_info is null || 
        actual_info.is_class || expected_info.is_class || 
        actual_info.is_enum || expected_info.is_enum || 
        actual_info.is_interface || expected_info.is_interface) {
        return false;
    }

    let actual_count: Int = 0;
    let expected_count: Int = 0;
    if (actual_info.fields is !null) {
        actual_count = actual_info.fields.length();
    }

    if (expected_info.fields is !null) {
        expected_count = expected_info.fields.length();
    }

    if (expected_count != 1 || expected_count > actual_count) { return false; }

    let index: Int = 0;
    while (index < expected_count) {
        let actual_field: FieldInfo = actual_info.fields[index];
        let expected_field: FieldInfo = expected_info.fields[index];
        if (actual_field.type != expected_field.type) { return false; }
        index += 1;
    }
    return true;
}

func emit_erased_type_check(c: Compiler, value: String, expected: Int, pos: Position) -> Void {
    let matches: String = next_reg(c);
    let success: String = next_label(c);
    let failure: String = next_label(c);
    let helper: String = "@__wl_erased_accept_" + expected;
    c.erased_checks.put("" + expected, StringConstant(id=expected, value=helper));
    c.output_file.write(c.indent + matches + " = call i1 " + helper + "(i8* " + value + ")\n");
    c.output_file.write(c.indent + "br i1 " + matches + ", label %" + success + ", label %" + failure + "\n");
    c.output_file.write("\n" + failure + ":\n");
    emit_runtime_error(c, pos, "Erased value has the wrong concrete type");
    c.output_file.write("\n" + success + ":\n");
}

func hoist_allocas(c: Compiler, node: Struct) -> Void {
// keep local storage in the entry block so loops do not grow the native stack
    if (node is null) {
        return;
    }

    let base: BaseNode = node;
    if (base.type == NODE_BLOCK) {
        let block: BlockNode = node;
        let old_scope: Scope = c.hoist_scope;
        c.hoist_scope = Scope(parent=old_scope, table=Dict(), gc_vars=[], depth=0);

        let stmts: Vector(Struct) = block.stmts;
        let len: Int = 0;
        if (stmts is !null) { len = stmts.length(); }
        let i: Int = 0;
        while (i < len) {
            hoist_allocas(c, stmts[i]);
            i += 1;
        }

        c.hoist_scope = old_scope;
    } else if (base.type == NODE_IF) {
        let if_n: IfNode = node;
        hoist_allocas(c, if_n.body);
        hoist_allocas(c, if_n.else_body);
    } else if (base.type == NODE_WHILE) {
        let w_n: WhileNode = node;
        hoist_allocas(c, w_n.body);
    } else if (base.type == NODE_FOR) {
        let f_n: ForNode = node;
        hoist_allocas(c, f_n.init);
        hoist_allocas(c, f_n.body);
    } else if (base.type == NODE_CATCH) {
        let c_node: CatchNode = node;
        let err_reg: String = next_reg(c);
        c_node.alloc_id = c.alloc_regs.length();
        c.alloc_regs.append(err_reg);
        c.output_file.write(c.indent + err_reg + " = alloca { i64, i32 }\n");
        
        hoist_allocas(c, c_node.stmt);
        hoist_allocas(c, c_node.body);
    } else if (base.type == NODE_VAR_DECL) {
        let v_node: VarDeclareNode = node;
        if (c.scope_depth > 0) {
            let target_type_id: Int = resolve_type(c, v_node.type_node);

            if (target_type_id == TYPE_AUTO) {
                target_type_id = get_expr_type(c, v_node.value);
                if (target_type_id == TYPE_POISON) { return; }
                if (target_type_id == 0 || target_type_id == TYPE_AUTO) {
                    throw_type_error(v_node.pos, "Failed to statically infer type for 'Auto'. Please specify type explicitly.");
                    return;
                }
            }

            if (c.hoist_scope is !null) {
                c.hoist_scope.table.put(v_node.name_tok.value, SymbolInfo(reg="", type=target_type_id, origin_type=target_type_id, is_const=v_node.is_const));
            }

            let var_reg: String = next_reg(c);
            v_node.alloc_id = c.alloc_regs.length();
            c.alloc_regs.append(var_reg);
            
            let llvm_ty_str: String = get_llvm_type_str(c, target_type_id);
            c.output_file.write(c.indent + var_reg + " = alloca " + llvm_ty_str + "\n");
            if (needs_drop(c, target_type_id)) {
                c.output_file.write(c.indent + "store " + llvm_ty_str + " zeroinitializer, " + llvm_ty_str + "* " + var_reg + "\n");
            }
        }
    }
}

func emit_runtime_error(c: Compiler, pos: Position, msg: String) -> Void {
    let hook_raw_str: String = get_mangled_symbol(c, "print_bytes", null);
    let hook_int: String = get_mangled_symbol(c, "print_int", null);

    if (hook_raw_str is !null && hook_int is !null) {
        let header_1: String = "RuntimeError: " + msg + "\n    at " + pos.fn + ":";
        let header_1_id: Int = register_string_constant(c, header_1);
        let header_1_ptr: String = get_string_ptr(header_1_id, header_1);

        let header_2: String = ":";
        let header_2_id: Int = register_string_constant(c, header_2);
        let header_2_ptr: String = get_string_ptr(header_2_id, header_2);

        let header_3: String = "\n\n";
        let header_3_id: Int = register_string_constant(c, header_3);
        let header_3_ptr: String = get_string_ptr(header_3_id, header_3);

        let ln: Int = pos.ln + 1;
        let col: Int = pos.col + 1;

        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + header_1_ptr + ", i32 " + header_1.length() + ")\n");
        c.output_file.write(c.indent + "call void @" + hook_int + "(i32 " + ln + ")\n");
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + header_2_ptr + ", i32 " + header_2.length() + ")\n");
        c.output_file.write(c.indent + "call void @" + hook_int + "(i32 " + col + ")\n");
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + header_3_ptr + ", i32 " + header_3.length() + ")\n");

        let full_text: String = pos.text;
        if (c.emit_source_context && full_text.length() > 0) {
            let current_ln: Int = 0;
            let scan_idx: Int = 0;
            let len: Int = full_text.length();
            let line_start_idx: Int = 0;

            while (scan_idx < len) {
                if (current_ln == pos.ln) { line_start_idx = scan_idx; break; }
                if (full_text[scan_idx] == '\n') { current_ln += 1; }
                scan_idx += 1;
            }

            let line_end_idx: Int = line_start_idx;
            while (line_end_idx < len) {
                let ch: Char = full_text[line_end_idx];
                if (ch == '\n' || ch == '\r') { break; }
                line_end_idx += 1;
            }

            let raw_line: String = full_text.slice(line_start_idx, line_end_idx);
            let code_content: String = "    " + raw_line + "\n";
        
            let code_id: Int = register_string_constant(c, code_content);
            let code_ptr: String = get_string_ptr(code_id, code_content);
            c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + code_ptr + ", i32 " + code_content.length() + ")\n");

            let err_len: Int = 1;
            let line_len: Int = raw_line.length();
            if (pos.col < line_len) {
                let ch: Char = raw_line[pos.col];
                if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_' || (ch >= '0' && ch <= '9')) {
                    let cur: Int = pos.col + 1;
                    while (cur < line_len) {
                        let c2: Char = raw_line[cur];
                        if ((c2 >= 'A' && c2 <= 'Z') || (c2 >= 'a' && c2 <= 'z') || c2 == '_' || (c2 >= '0' && c2 <= '9')) {
                            cur += 1;
                        } else {
                            break;
                        }
                    }
                    err_len = cur - pos.col;
                }
            }

            let arrow_str: String = "    ";
            let k: Int = 0;
            while (k < pos.col) {
                arrow_str += " ";
                k += 1;
            }
            let j: Int = 0;
            while (j < err_len) {
                arrow_str += "^";
                j += 1;
            }
            arrow_str += "\n";
            let arrow_id: Int = register_string_constant(c, arrow_str);
            let arrow_ptr: String = get_string_ptr(arrow_id, arrow_str);
            c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + arrow_ptr + ", i32 " + arrow_str.length() + ")\n");
        }
    }

    let exit_hook: String = get_mangled_symbol(c, "process_exit", pos);
    c.output_file.write(c.indent + "call void @" + exit_hook + "(i32 1)\n");
    c.output_file.write(c.indent + "unreachable\n");
}

func emit_pointer_null_check(c: Compiler, ptr_reg: String, type_id: Int, pos: Position) -> Void {
    let ptr_ty: String = get_llvm_type_str(c, type_id);
    let is_null: String = next_reg(c);
    c.output_file.write(c.indent + is_null + " = icmp eq " + ptr_ty + " " + ptr_reg + ", null\n");
    let fail_label: String = next_label(c);
    let ok_label: String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + is_null + ", label %" + fail_label + ", label %" + ok_label + "\n");
    c.output_file.write("\n" + fail_label + ":\n");
    emit_runtime_error(c, pos, "Null pointer dereference");
    c.output_file.write("\n" + ok_label + ":\n");
}

func emit_size_to_int(c: Compiler, value: String) -> String {
    let size_ty: String = get_size_llvm_type();
    if (size_ty == "i32") { return value; }
    let result: String = next_reg(c);
    c.output_file.write(c.indent + result + " = trunc " + size_ty + " " + value + " to i32\n");
    return result;
}

func emit_int_to_size(c: Compiler, value: String, signed: Bool) -> String {
    let size_ty: String = get_size_llvm_type();
    if (size_ty == "i32") { return value; }
    let result: String = next_reg(c);
    let op: String = "zext";
    if signed { op = "sext"; }
    c.output_file.write(c.indent + result + " = " + op + " i32 " + value + " to " + size_ty + "\n");
    return result;
}


func emit_vector_bounds_check(c: Compiler, vec_reg: String, idx_reg: String, struct_ty: String, pos: Position) -> Void {
    let size_ty: String = get_size_llvm_type();
    let size_ptr: String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_reg + ", i32 0, i32 0\n");
    let size_val: String = next_reg(c);
    c.output_file.write(c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");

    let size_index: String = emit_int_to_size(c, idx_reg, true);

    let cmp_reg: String = next_reg(c);
    c.output_file.write(c.indent + cmp_reg + " = icmp uge " + size_ty + " " + size_index + ", " + size_val + "\n");

    let fail_label: String = "bounds_fail_" + c.type_counter;
    let ok_label: String = "bounds_ok_" + c.type_counter;
    c.type_counter += 1;
    
    c.output_file.write(c.indent + "br i1 " + cmp_reg + ", label %" + fail_label + ", label %" + ok_label + "\n");

    c.output_file.write("\n" + fail_label + ":\n");
    emit_runtime_error(c, pos, "Index out of bounds");

    c.output_file.write("\n" + ok_label + ":\n");
}

func emit_array_bounds_check(c: Compiler, idx_reg: String, len_val: String, pos: Position) -> Void {
    let cmp1: String = next_reg(c);
    c.output_file.write(c.indent + cmp1 + " = icmp slt i32 " + idx_reg + ", 0\n");
    let cmp2: String = next_reg(c);
    c.output_file.write(c.indent + cmp2 + " = icmp sge i32 " + idx_reg + ", " + len_val + "\n");
    
    let or1: String = next_reg(c);
    c.output_file.write(c.indent + or1 + " = or i1 " + cmp1 + ", " + cmp2 + "\n");
    
    let fail_lbl: String = "arr_fail_" + c.type_counter;
    let ok_lbl: String = "arr_ok_" + c.type_counter;
    c.type_counter += 1;

    c.output_file.write(c.indent + "br i1 " + or1 + ", label %" + fail_lbl + ", label %" + ok_lbl + "\n");
    c.output_file.write("\n" + fail_lbl + ":\n");
    emit_runtime_error(c, pos, "Index out of bounds.");
    c.output_file.write("\n" + ok_lbl + ":\n");
}

func emit_slice_bounds_check(c: Compiler, start_reg: String, end_reg: String, len_val: String, pos: Position) -> Void {
    let cmp1: String = next_reg(c);
    c.output_file.write(c.indent + cmp1 + " = icmp slt i32 " + start_reg + ", 0\n");
    let cmp2: String = next_reg(c);
    c.output_file.write(c.indent + cmp2 + " = icmp sgt i32 " + start_reg + ", " + end_reg + "\n");
    let cmp3: String = next_reg(c);
    c.output_file.write(c.indent + cmp3 + " = icmp sgt i32 " + end_reg + ", " + len_val + "\n");
    
    let or1: String = next_reg(c);
    c.output_file.write(c.indent + or1 + " = or i1 " + cmp1 + ", " + cmp2 + "\n");
    let or2: String = next_reg(c);
    c.output_file.write(c.indent + or2 + " = or i1 " + or1 + ", " + cmp3 + "\n");
    
    let fail_lbl: String = "slice_fail_" + c.type_counter;
    let ok_lbl: String = "slice_ok_" + c.type_counter;
    c.type_counter += 1;
    
    c.output_file.write(c.indent + "br i1 " + or2 + ", label %" + fail_lbl + ", label %" + ok_lbl + "\n");
    c.output_file.write("\n" + fail_lbl + ":\n");
    emit_runtime_error(c, pos, "Slice boundaries out of range.");
    c.output_file.write("\n" + ok_lbl + ":\n");
}

func emit_slice_parts(c: Compiler, slice_reg: String, slice_type: Int, pos: Position) -> SliceParts {
    let arr_info: ArrayInfo = c.array_info_map.lookup("" + slice_type);
    let elem_ty: String = get_llvm_type_str(c, arr_info.base_type);
    let slice_ty: String = arr_info.llvm_name;
    let size_ty: String = get_size_llvm_type();
    emit_pointer_null_check(c, slice_reg, slice_type, pos);

    let start_slot: String = next_reg(c);
    c.output_file.write(c.indent + start_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 0\n");
    let start: String = next_reg(c);
    c.output_file.write(c.indent + start + " = load " + size_ty + ", " + size_ty + "* " + start_slot + "\n");

    let len_slot: String = next_reg(c);
    c.output_file.write(c.indent + len_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 1\n");
    let length: String = next_reg(c);
    c.output_file.write(c.indent + length + " = load " + size_ty + ", " + size_ty + "* " + len_slot + "\n");

    let owner_slot: String = next_reg(c);
    c.output_file.write(c.indent + owner_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 2\n");
    let owner: String = next_reg(c);
    c.output_file.write(c.indent + owner + " = load i8*, i8** " + owner_slot + "\n");

    let data_slot_slot: String = next_reg(c);
    c.output_file.write(c.indent + data_slot_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 3\n");
    let data_slot: String = next_reg(c);
    c.output_file.write(c.indent + data_slot + " = load " + elem_ty + "**, " + elem_ty + "*** " + data_slot_slot + "\n");

    let size_slot_slot: String = next_reg(c);
    c.output_file.write(c.indent + size_slot_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 4\n");
    let size_slot: String = next_reg(c);
    c.output_file.write(c.indent + size_slot + " = load " + size_ty + "*, " + size_ty + "** " + size_slot_slot + "\n");
    let owner_size: String = next_reg(c);
    c.output_file.write(c.indent + owner_size + " = load " + size_ty + ", " + size_ty + "* " + size_slot + "\n");

    let slice_end: String = next_reg(c);
    c.output_file.write(c.indent + slice_end + " = add " + size_ty + " " + start + ", " + length + "\n");
    let invalid: String = next_reg(c);
    c.output_file.write(c.indent + invalid + " = icmp ugt " + size_ty + " " + slice_end + ", " + owner_size + "\n");
    let fail_label: String = next_label(c);
    let ok_label: String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + invalid + ", label %" + fail_label + ", label %" + ok_label + "\n");
    c.output_file.write("\n" + fail_label + ":\n");
    emit_runtime_error(c, pos, "Slice backing storage was shortened");
    c.output_file.write("\n" + ok_label + ":\n");

    let data: String = next_reg(c);
    c.output_file.write(c.indent + data + " = load " + elem_ty + "*, " + elem_ty + "** " + data_slot + "\n");
    return SliceParts(start=start, length=length, owner=owner, data_slot=data_slot, size_slot=size_slot, data=data);
}

func emit_make_slice(c: Compiler, elem_type: Int, owner: String, data_slot: String, size_slot: String, start: String, length: String) -> CompileResult {
    let slice_type: Int = get_slice_type_id(c, elem_type);
    let arr_info: ArrayInfo = c.array_info_map.lookup("" + slice_type);
    let elem_ty: String = get_llvm_type_str(c, elem_type);
    let slice_ty: String = arr_info.llvm_name;
    let size_ty: String = get_size_llvm_type();

    let size_ptr: String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr " + slice_ty + ", " + slice_ty + "* null, i32 1\n");
    let size: String = next_reg(c);
    c.output_file.write(c.indent + size + " = ptrtoint " + slice_ty + "* " + size_ptr + " to " + size_ty + "\n");
    let result: String = emit_alloc_obj(c, size, "" + slice_type, slice_ty + "*");

    let start_slot: String = next_reg(c);
    c.output_file.write(c.indent + start_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 0\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + start + ", " + size_ty + "* " + start_slot + "\n");
    let len_slot: String = next_reg(c);
    c.output_file.write(c.indent + len_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + length + ", " + size_ty + "* " + len_slot + "\n");
    let owner_slot: String = next_reg(c);
    c.output_file.write(c.indent + owner_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 2\n");
    c.output_file.write(c.indent + "store i8* " + owner + ", i8** " + owner_slot + "\n");
    let data_slot_slot: String = next_reg(c);
    c.output_file.write(c.indent + data_slot_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 3\n");
    c.output_file.write(c.indent + "store " + elem_ty + "** " + data_slot + ", " + elem_ty + "*** " + data_slot_slot + "\n");
    let size_slot_slot: String = next_reg(c);
    c.output_file.write(c.indent + size_slot_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 4\n");
    c.output_file.write(c.indent + "store " + size_ty + "* " + size_slot + ", " + size_ty + "** " + size_slot_slot + "\n");
    c.output_file.write(c.indent + "call void @__wl_retain(i8* " + owner + ")\n");
    return CompileResult(reg=result, type=slice_type);
}

func emit_slice_copy(c: Compiler, elem_type: Int, source: String, start_i32: String, length_i32: String, pos: Position) -> CompileResult {
    let elem_ty: String = get_llvm_type_str(c, elem_type);
    let vec_type: Int = get_vector_type_id(c, elem_type);
    let vec_ty: String = get_vector_llvm_type(c, elem_type);
    let size_ty: String = get_size_llvm_type();

    let vec_size_ptr: String = next_reg(c);
    c.output_file.write(c.indent + vec_size_ptr + " = getelementptr " + vec_ty + ", " + vec_ty + "* null, i32 1\n");
    let vec_size: String = next_reg(c);
    c.output_file.write(c.indent + vec_size + " = ptrtoint " + vec_ty + "* " + vec_size_ptr + " to " + size_ty + "\n");
    let owner_ptr: String = emit_alloc_obj(c, vec_size, "" + vec_type, vec_ty + "*");

    let length: String = emit_int_to_size(c, length_i32, false);
    let start: String = emit_int_to_size(c, start_i32, false);
    let is_empty: String = next_reg(c);
    c.output_file.write(c.indent + is_empty + " = icmp eq " + size_ty + " " + length + ", 0\n");
    let alloc_count: String = next_reg(c);
    c.output_file.write(c.indent + alloc_count + " = select i1 " + is_empty + ", " + size_ty + " 1, " + size_ty + " " + length + "\n");

    let elem_size: Int = get_type_size_bytes(c, elem_type);
    let max_capacity: Long = vector_capacity_limit(elem_size);
    let overflow: String = next_reg(c);
    c.output_file.write(c.indent + overflow + " = icmp ugt " + size_ty + " " + alloc_count + ", " + max_capacity + "\n");
    let fail_label: String = next_label(c);
    let alloc_label: String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + overflow + ", label %" + fail_label + ", label %" + alloc_label + "\n");
    c.output_file.write("\n" + fail_label + ":\n");
    c.output_file.write(c.indent + "call void @__wl_oom()\n");
    c.output_file.write(c.indent + "unreachable\n");
    c.output_file.write("\n" + alloc_label + ":\n");

    let bytes: String = next_reg(c);
    c.output_file.write(c.indent + bytes + " = mul " + size_ty + " " + alloc_count + ", " + elem_size + "\n");
    let alloc_hook: String = get_mangled_symbol(c, "memory_alloc", pos);
    let raw_data: String = next_reg(c);
    c.output_file.write(c.indent + raw_data + " = call i8* @" + alloc_hook + "(" + size_ty + " " + bytes + ")\n");
    emit_alloc_check(c, raw_data);
    let data: String = next_reg(c);
    c.output_file.write(c.indent + data + " = bitcast i8* " + raw_data + " to " + elem_ty + "*\n");

    let size_slot: String = next_reg(c);
    c.output_file.write(c.indent + size_slot + " = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* " + owner_ptr + ", i32 0, i32 0\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + length + ", " + size_ty + "* " + size_slot + "\n");
    let cap_slot: String = next_reg(c);
    c.output_file.write(c.indent + cap_slot + " = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* " + owner_ptr + ", i32 0, i32 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + length + ", " + size_ty + "* " + cap_slot + "\n");
    let data_slot: String = next_reg(c);
    c.output_file.write(c.indent + data_slot + " = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* " + owner_ptr + ", i32 0, i32 2\n");
    c.output_file.write(c.indent + "store " + elem_ty + "* " + data + ", " + elem_ty + "** " + data_slot + "\n");

    let index: String = next_reg(c);
    c.output_file.write(c.indent + index + " = alloca " + size_ty + "\n");
    c.output_file.write(c.indent + "store " + size_ty + " 0, " + size_ty + "* " + index + "\n");
    let loop_cond: String = next_label(c);
    let loop_body: String = next_label(c);
    let loop_end: String = next_label(c);
    c.output_file.write(c.indent + "br label %" + loop_cond + "\n");
    c.output_file.write("\n" + loop_cond + ":\n");
    let i: String = next_reg(c);
    c.output_file.write(c.indent + i + " = load " + size_ty + ", " + size_ty + "* " + index + "\n");
    let more: String = next_reg(c);
    c.output_file.write(c.indent + more + " = icmp ult " + size_ty + " " + i + ", " + length + "\n");
    c.output_file.write(c.indent + "br i1 " + more + ", label %" + loop_body + ", label %" + loop_end + "\n");
    c.output_file.write("\n" + loop_body + ":\n");
    let source_index: String = next_reg(c);
    c.output_file.write(c.indent + source_index + " = add " + size_ty + " " + start + ", " + i + "\n");
    let source_slot: String = next_reg(c);
    c.output_file.write(c.indent + source_slot + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + source + ", " + size_ty + " " + source_index + "\n");
    let value: String = next_reg(c);
    c.output_file.write(c.indent + value + " = load " + elem_ty + ", " + elem_ty + "* " + source_slot + "\n");
    let dest_slot: String = next_reg(c);
    c.output_file.write(c.indent + dest_slot + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + data + ", " + size_ty + " " + i + "\n");
    c.output_file.write(c.indent + "store " + elem_ty + " " + value + ", " + elem_ty + "* " + dest_slot + "\n");
    if (needs_drop(c, elem_type)) { emit_retain_slot(c, dest_slot, elem_type); }
    let next: String = next_reg(c);
    c.output_file.write(c.indent + next + " = add " + size_ty + " " + i + ", 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + next + ", " + size_ty + "* " + index + "\n");
    c.output_file.write(c.indent + "br label %" + loop_cond + "\n");
    c.output_file.write("\n" + loop_end + ":\n");

    let owner: String = next_reg(c);
    c.output_file.write(c.indent + owner + " = bitcast " + vec_ty + "* " + owner_ptr + " to i8*\n");
    return emit_make_slice(c, elem_type, owner, data_slot, size_slot, "0", length);
}

func emit_drop_slot(c: Compiler, ptr_reg: String, type_id: Int) -> Void {
    if (is_fallible_type(c, type_id)) {
        let inner_type: Int = get_inner_fallible_type(c, type_id);
        if (!needs_drop(c, inner_type)) { return; }

        let fallible_ty: String = get_llvm_type_str(c, type_id);
        let err_ptr: String = next_reg(c);
        c.output_file.write(c.indent + err_ptr + " = getelementptr inbounds " + fallible_ty + ", " + fallible_ty + "* " + ptr_reg + ", i32 0, i32 0\n");
        let is_err: String = next_reg(c);
        c.output_file.write(c.indent + is_err + " = load i1, i1* " + err_ptr + "\n");
        let drop_label: String = next_label(c);
        let done_label: String = next_label(c);
        c.output_file.write(c.indent + "br i1 " + is_err + ", label %" + done_label + ", label %" + drop_label + "\n");
        c.output_file.write("\n" + drop_label + ":\n");
        let value_ptr: String = next_reg(c);
        c.output_file.write(c.indent + value_ptr + " = getelementptr inbounds " + fallible_ty + ", " + fallible_ty + "* " + ptr_reg + ", i32 0, i32 2\n");
        emit_drop_slot(c, value_ptr, inner_type);
        c.output_file.write(c.indent + "br label %" + done_label + "\n");
        c.output_file.write("\n" + done_label + ":\n");
        return;
    }

    let arr_info: ArrayInfo = c.array_info_map.lookup("" + type_id);
    if (arr_info is !null && arr_info.size >= 0) {
        let i: Int = 0;
        while (i < arr_info.size) {
            let elem_ptr: String = next_reg(c);
            c.output_file.write(c.indent + elem_ptr + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + ptr_reg + ", i32 0, i32 " + i + "\n");
            emit_drop_slot(c, elem_ptr, arr_info.base_type);
            i += 1;
        }
        return;
    }

    if (!is_ref_type(c, type_id)) { return; }
    let llvm_ty: String = get_llvm_type_str(c, type_id);
    let value: String = next_reg(c);
    c.output_file.write(c.indent + value + " = load " + llvm_ty + ", " + llvm_ty + "* " + ptr_reg + "\n");
    emit_release(c, value, type_id);
}

func emit_retain_slot(c: Compiler, ptr_reg: String, type_id: Int) -> Void {
    if (is_fallible_type(c, type_id)) {
        let inner_type: Int = get_inner_fallible_type(c, type_id);
        if (!needs_drop(c, inner_type)) { return; }

        let fallible_ty: String = get_llvm_type_str(c, type_id);
        let err_ptr: String = next_reg(c);
        c.output_file.write(c.indent + err_ptr + " = getelementptr inbounds " + fallible_ty + ", " + fallible_ty + "* " + ptr_reg + ", i32 0, i32 0\n");
        let is_err: String = next_reg(c);
        c.output_file.write(c.indent + is_err + " = load i1, i1* " + err_ptr + "\n");
        let retain_label: String = next_label(c);
        let done_label: String = next_label(c);
        c.output_file.write(c.indent + "br i1 " + is_err + ", label %" + done_label + ", label %" + retain_label + "\n");
        c.output_file.write("\n" + retain_label + ":\n");
        let value_ptr: String = next_reg(c);
        c.output_file.write(c.indent + value_ptr + " = getelementptr inbounds " + fallible_ty + ", " + fallible_ty + "* " + ptr_reg + ", i32 0, i32 2\n");
        emit_retain_slot(c, value_ptr, inner_type);
        c.output_file.write(c.indent + "br label %" + done_label + "\n");
        c.output_file.write("\n" + done_label + ":\n");
        return;
    }

    let arr_info: ArrayInfo = c.array_info_map.lookup("" + type_id);
    if (arr_info is !null && arr_info.size >= 0) {
        let i: Int = 0;
        while (i < arr_info.size) {
            let elem_ptr: String = next_reg(c);
            c.output_file.write(c.indent + elem_ptr + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + ptr_reg + ", i32 0, i32 " + i + "\n");
            emit_retain_slot(c, elem_ptr, arr_info.base_type);
            i += 1;
        }
        return;
    }

    if (!is_ref_type(c, type_id)) { return; }
    let llvm_ty: String = get_llvm_type_str(c, type_id);
    let value: String = next_reg(c);
    c.output_file.write(c.indent + value + " = load " + llvm_ty + ", " + llvm_ty + "* " + ptr_reg + "\n");
    emit_retain(c, value, type_id);
}

func emit_type_drop(c: Compiler, type_id: Int) -> Void {
// one drop thunk per concrete type lets containers destroy erased elements safely

    let free_hook: String = get_mangled_symbol(c, "memory_free", null);
    c.output_file.write("define internal void @__wl_drop." + type_id + "(i8* %ptr) {\n");
    c.output_file.write("entry:\n");

    if (type_id == TYPE_GENERIC_FUNCTION) {
        c.output_file.write("  %env.addr = getelementptr inbounds i8, i8* %ptr, i32 " + closure_env_offset() + "\n");
        c.output_file.write("  %env.slot = bitcast i8* %env.addr to i8**\n");
        c.output_file.write("  %env = load i8*, i8** %env.slot\n");
        c.output_file.write("  call void @__wl_release(i8* %env)\n");
        c.output_file.write("  ret void\n");
        c.output_file.write("}\n\n");
        return;
    }

    let arr_info: ArrayInfo = c.array_info_map.lookup("" + type_id);
    if (arr_info is !null && arr_info.size == -1) {
        let slice_ty: String = arr_info.llvm_name;
        c.output_file.write("  %slice = bitcast i8* %ptr to " + slice_ty + "*\n");
        c.output_file.write("  %owner.slot = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* %slice, i32 0, i32 2\n");
        c.output_file.write("  %owner = load i8*, i8** %owner.slot\n");
        c.output_file.write("  call void @__wl_release(i8* %owner)\n");
        c.output_file.write("  ret void\n");
        c.output_file.write("}\n\n");
        return;
    }

    let variant_info: StructInfo = c.struct_table.lookup("$Variant");
    if (variant_info is !null && type_id == variant_info.type_id) {
        c.output_file.write("  %box = bitcast i8* %ptr to %struct.$Variant*\n");
        c.output_file.write("  %tag.slot = getelementptr inbounds %struct.$Variant, %struct.$Variant* %box, i32 0, i32 0\n");
        c.output_file.write("  %tag = load i64, i64* %tag.slot\n");
        c.output_file.write("  switch i64 %tag, label %done [\n");

        let ref_cases: String = "";
        let seen_refs: Dict(String, StringConstant) = Dict();
        let ref_id: Int = 1;
        while (ref_id < c.type_counter) {
            if (is_ref_type(c, ref_id) && ref_id != type_id) {
                ref_cases = append_variant_ref_case(c, ref_cases, seen_refs, ref_id);
            }
            ref_id += 1;
        }
        c.output_file.write(ref_cases);
        c.output_file.write("  ]\n");
        c.output_file.write("release:\n");
        c.output_file.write("  %payload.slot = getelementptr inbounds %struct.$Variant, %struct.$Variant* %box, i32 0, i32 1\n");
        c.output_file.write("  %payload = load i64, i64* %payload.slot\n");
        c.output_file.write("  %value = inttoptr i64 %payload to i8*\n");
        c.output_file.write("  call void @__wl_release(i8* %value)\n");
        c.output_file.write("  br label %done\n");
        c.output_file.write("done:\n");
        c.output_file.write("  ret void\n");
        c.output_file.write("}\n\n");
        return;
    }

    let vec_info: SymbolInfo = c.vector_base_map.lookup("" + type_id);
    if (vec_info is !null) {
        let elem_type: Int = vec_info.type;
        let elem_ty: String = get_llvm_type_str(c, elem_type);
        let vec_ty: String = get_vector_llvm_type(c, elem_type);
        let size_ty: String = get_size_llvm_type();
        c.output_file.write("  %vec = bitcast i8* %ptr to " + vec_ty + "*\n");
        c.output_file.write("  %size.slot = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* %vec, i32 0, i32 0\n");
        c.output_file.write("  %size = load " + size_ty + ", " + size_ty + "* %size.slot\n");
        c.output_file.write("  %data.slot = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* %vec, i32 0, i32 2\n");
        c.output_file.write("  %data = load " + elem_ty + "*, " + elem_ty + "** %data.slot\n");

        if (needs_drop(c, elem_type)) {
            c.output_file.write("  %index = alloca " + size_ty + "\n");
            c.output_file.write("  store " + size_ty + " 0, " + size_ty + "* %index\n");
            c.output_file.write("  br label %loop.cond\n");
            c.output_file.write("loop.cond:\n");
            c.output_file.write("  %i = load " + size_ty + ", " + size_ty + "* %index\n");
            c.output_file.write("  %more = icmp ult " + size_ty + " %i, %size\n");
            c.output_file.write("  br i1 %more, label %loop.body, label %loop.end\n");
            c.output_file.write("loop.body:\n");
            c.output_file.write("  %slot = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* %data, " + size_ty + " %i\n");
            emit_drop_slot(c, "%slot", elem_type);
            c.output_file.write("  %next = add " + size_ty + " %i, 1\n");
            c.output_file.write("  store " + size_ty + " %next, " + size_ty + "* %index\n");
            c.output_file.write("  br label %loop.cond\n");
            c.output_file.write("loop.end:\n");
        }

        c.output_file.write("  %data.raw = bitcast " + elem_ty + "* %data to i8*\n");
        c.output_file.write("  call void @" + free_hook + "(i8* %data.raw)\n");
        c.output_file.write("  ret void\n");
        c.output_file.write("}\n\n");
        return;
    }

    let s_info: StructInfo = c.struct_id_map.lookup("" + type_id);
    if (s_info is !null) {
        if (s_info.is_class) {
            let methods: Vector(Struct) = s_info.vtable;
            let method_len: Int = 0; if (methods is !null) { method_len = methods.length(); }
            let method_i: Int = 0;
            let deinit: FuncInfo = null;
            while (method_i < method_len) {
                let method_info: FuncInfo = methods[method_i];
                if (method_info.base_name == "$deinit") {
                    deinit = method_info;
                    break;
                }
                method_i += 1;
            }
            if (deinit is !null) {
                let self_arg: TypeListNode = deinit.arg_types[0];
                let self_ty: String = get_llvm_type_str(c, self_arg.type);
                let deinit_ret: String = get_llvm_type_str(c, deinit.ret_type);
                c.output_file.write("  %self = bitcast i8* %ptr to " + self_ty + "\n");
                c.output_file.write("  call " + deinit_ret + " @" + deinit.name + "(" + self_ty + " %self)\n");
            }
        }

        c.output_file.write("  %object = bitcast i8* %ptr to " + s_info.llvm_name + "*\n");
        let fields: Vector(Struct) = s_info.fields;
        let field_len: Int = 0; if (fields is !null) { field_len = fields.length(); }
        let field_i: Int = 0;
        while (field_i < field_len) {
            let field: FieldInfo = fields[field_i];
            if (field.name != "_vptr" && needs_drop(c, field.type)) {
                let field_ptr: String = next_reg(c);
                c.output_file.write(c.indent + field_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* %object, i32 0, i32 " + field.offset + "\n");
                emit_drop_slot(c, field_ptr, field.type);
            }
            field_i += 1;
        }
    }

    c.output_file.write("  ret void\n");
    c.output_file.write("}\n\n");
}

func compile_arc_hooks(c: Compiler) -> Void {
    let free_hook: String = get_mangled_symbol(c, "memory_free", null);
    let exit_hook: String = get_mangled_symbol(c, "process_exit", null);

    c.output_file.write("define internal void @__wl_oom() noreturn {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  call void @" + exit_hook + "(i32 1)\n");
    c.output_file.write("  unreachable\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define internal void @__wl_retain(i8* %ptr) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %is.null = icmp eq i8* %ptr, null\n");
    c.output_file.write("  br i1 %is.null, label %done, label %work\n");
    c.output_file.write("work:\n");
    c.output_file.write("  %base = getelementptr i8, i8* %ptr, i32 -8\n");
    c.output_file.write("  %rc.ptr = bitcast i8* %base to i32*\n");
    c.output_file.write("  %rc = load atomic i32, i32* %rc.ptr monotonic, align 4\n");
    c.output_file.write("  %is.static = icmp eq i32 %rc, -1\n");
    c.output_file.write("  br i1 %is.static, label %done, label %retain\n");
    c.output_file.write("retain:\n");
    c.output_file.write("  %old = atomicrmw add i32* %rc.ptr, i32 1 monotonic\n");
    c.output_file.write("  %invalid = icmp slt i32 %old, 0\n");
    c.output_file.write("  br i1 %invalid, label %trap, label %done\n");
    c.output_file.write("trap:\n");
    c.output_file.write("  call void @llvm.trap()\n");
    c.output_file.write("  unreachable\n");
    c.output_file.write("done:\n");
    c.output_file.write("  ret void\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define internal void @__wl_release(i8* %ptr) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %is.null = icmp eq i8* %ptr, null\n");
    c.output_file.write("  br i1 %is.null, label %done, label %work\n");
    c.output_file.write("work:\n");
    c.output_file.write("  %base = getelementptr i8, i8* %ptr, i32 -8\n");
    c.output_file.write("  %rc.ptr = bitcast i8* %base to i32*\n");
    c.output_file.write("  %rc = load atomic i32, i32* %rc.ptr monotonic, align 4\n");
    c.output_file.write("  %is.static = icmp eq i32 %rc, -1\n");
    c.output_file.write("  br i1 %is.static, label %done, label %release\n");
    c.output_file.write("release:\n");
    c.output_file.write("  %old = atomicrmw sub i32* %rc.ptr, i32 1 acq_rel\n");
    c.output_file.write("  %invalid = icmp sle i32 %old, 0\n");
    c.output_file.write("  br i1 %invalid, label %trap, label %check.last\n");
    c.output_file.write("trap:\n");
    c.output_file.write("  call void @llvm.trap()\n");
    c.output_file.write("  unreachable\n");
    c.output_file.write("check.last:\n");
    c.output_file.write("  %is.last = icmp eq i32 %old, 1\n");
    c.output_file.write("  br i1 %is.last, label %destroy, label %done\n");
    c.output_file.write("destroy:\n");
    c.output_file.write("  %tag.addr = getelementptr inbounds i8, i8* %base, i32 4\n");
    c.output_file.write("  %tag.ptr = bitcast i8* %tag.addr to i32*\n");
    c.output_file.write("  %tag = load i32, i32* %tag.ptr\n");
    c.output_file.write("  %is.dynamic = icmp ne i32 %tag, " + TYPE_STRING + "\n");
    c.output_file.write("  br i1 %is.dynamic, label %destroy.dynamic, label %destroy.legacy\n");
    c.output_file.write("destroy.dynamic:\n");
    c.output_file.write("  %raw = getelementptr inbounds i8, i8* %base, i32 -8\n");
    c.output_file.write("  %drop.slot = bitcast i8* %raw to i8**\n");
    c.output_file.write("  %drop.raw = load i8*, i8** %drop.slot\n");
    c.output_file.write("  %drop = bitcast i8* %drop.raw to void (i8*)*\n");
    c.output_file.write("  call void %drop(i8* %ptr)\n");
    c.output_file.write("  call void @" + free_hook + "(i8* %raw)\n");
    c.output_file.write("  br label %done\n");
    c.output_file.write("destroy.legacy:\n");
    c.output_file.write("  call void @" + free_hook + "(i8* %base)\n");
    c.output_file.write("  br label %done\n");
    c.output_file.write("done:\n");
    c.output_file.write("  ret void\n");
    c.output_file.write("}\n\n");

    emit_type_drop(c, TYPE_GENERIC_FUNCTION);

    let variant_info: StructInfo = c.struct_table.lookup("$Variant");
    if (variant_info is !null) { emit_type_drop(c, variant_info.type_id); }

    let type_id: Int = 100;
    while (type_id < c.type_counter) {
        let should_emit: Bool = false;
        let arr_info: ArrayInfo = c.array_info_map.lookup("" + type_id);
        if (arr_info is !null && arr_info.size == -1) { should_emit = true; }
        if (c.vector_base_map.lookup("" + type_id) is !null) { should_emit = true; }

        let s_info: StructInfo = c.struct_id_map.lookup("" + type_id);
        if (s_info is !null && !s_info.is_enum && !s_info.is_interface) {
            if (variant_info is null || type_id != variant_info.type_id) { should_emit = true; }
        }

        if should_emit { emit_type_drop(c, type_id); }
        type_id += 1;
    }
}

func emit_erased_check_helpers(c: Compiler) -> Void {
    let slot: Int = 0;
    while (slot < c.erased_checks.capacity) {
        if (c.erased_checks.hashes[slot] >= 2) {
            let entry: StringConstant = c.erased_checks.values[slot];
            let expected: Int = entry.id;
            c.output_file.write("define internal i1 " + entry.value + "(i8* %value) {\n");
            c.output_file.write("entry:\n");
            c.output_file.write("  %is_null = icmp eq i8* %value, null\n");
            c.output_file.write("  br i1 %is_null, label %accept, label %inspect\n");
            c.output_file.write("inspect:\n");
            c.output_file.write("  %tag_bytes = getelementptr i8, i8* %value, i32 -4\n");
            c.output_file.write("  %tag_slot = bitcast i8* %tag_bytes to i32*\n");
            c.output_file.write("  %tag = load i32, i32* %tag_slot\n");
            c.output_file.write("  switch i32 %tag, label %reject [\n");

                let candidate: Int = 100;
                while (candidate < c.type_counter) {
                    let accepted: Bool = candidate == expected;
                    if (!accepted) {
                        accepted = callable_types_compatible(c, candidate, expected);
                    }
        
                    let expected_info: StructInfo = c.struct_id_map.lookup("" + expected);
                if (!accepted && expected_info is !null && expected_info.is_class) {
                    accepted = is_subclass(c, candidate, expected);
                }
                if (!accepted && expected_info is !null && !expected_info.is_class) {
                    accepted = erased_struct_compatible(c, candidate, expected);
                }
                if accepted {
                    c.output_file.write("    i32 " + candidate + ", label %accept\n");
                }
                candidate += 1;
            }
            c.output_file.write("  ]\n");
            c.output_file.write("accept:\n");
            c.output_file.write("  ret i1 true\n");
            c.output_file.write("reject:\n");
            c.output_file.write("  ret i1 false\n");
            c.output_file.write("}\n\n");
        }
        slot += 1;
    }
}

func vector_capacity_limit(elem_size: Int) -> Long {
    let limit: Long = 2147483647L;
    if (get_target_pointer_bits() == 32) {
        let address_limit: Long = 4294967295L / Long(elem_size);
        if (address_limit < limit) { limit = address_limit; }
    }
    return limit;
}
