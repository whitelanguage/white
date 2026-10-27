// src/compiler/lowering/ownership.wl
import Dict from "dict"
import * from "../../frontend/ast.wl"
import * from "../../frontend/arena.wl"
import * from "../context.wl"
import * from "unions.wl"
import * from "../../frontend/diagnostics.wl"
import * from "../validation.wl"
import * from "dictionary.wl"
import * from "literals.wl"
import * from "../target.wl"


func enter_scope(ref c: Compiler) -> Void {
    let parent: Int = c.scope_stack.length();
    c.scope_stack.append(c.symbol_table);
    let new_scope: Scope = Scope(table=Dict(), parent=parent, gc_vars=[], depth=c.scope_depth + 1);
    c.symbol_table = new_scope;
    c.scope_depth += 1;
}
func exit_scope(ref c: Compiler) -> Void {
    let curr_scope: Scope = c.symbol_table;

    let gc_vec: Vector(Struct) = curr_scope.gc_vars;
    let gc_len: Int = gc_vec.length();
    let gc_idx: Int = 0;
    while (gc_idx < gc_len) {
        let curr_gc: GCTracker = gc_vec[gc_idx];
        emit_drop_slot(ref c, curr_gc.reg, curr_gc.type);
        gc_idx += 1;
    }

    if (c.symbol_table.parent >= 0) { c.symbol_table = c.scope_stack[c.symbol_table.parent]; }
    c.scope_depth -= 1;
}
func cleanup_all_scopes(ref c: Compiler) -> Void {
    let curr: Scope = c.symbol_table;
    while true {
        let gc_vec: Vector(Struct) = curr.gc_vars;
        let gc_len: Int = gc_vec.length();
        let gc_idx: Int = 0;
        while (gc_idx < gc_len) {
            let gc_node: GCTracker = gc_vec[gc_idx];
            emit_drop_slot(ref c, gc_node.reg, gc_node.type);
            gc_idx += 1;
        }
        if (curr.parent < 0) {
            break;
        }
        curr = c.scope_stack[curr.parent];
    }
}

func cleanup_scopes_until(ref c: Compiler, target_scope: Scope) -> Void {
    let curr: Scope = c.symbol_table;
    while (curr.depth > target_scope.depth) {
        let gc_vec: Vector(Struct) = curr.gc_vars;
        let gc_len: Int = gc_vec.length();
        let gc_idx: Int = 0;
        while (gc_idx < gc_len) {
            let gc_node: GCTracker = gc_vec[gc_idx];
            emit_drop_slot(ref c, gc_node.reg, gc_node.type);
            gc_idx += 1;
        }
        if (curr.parent < 0) {
            break;
        }
        curr = c.scope_stack[curr.parent];
    }
}

func emit_retain(ref c: Compiler, reg: String, type_id: Int) -> Void {
// strong cycles remain the caller's responsibility until weak references are added

    if (!is_ref_type(ref c, type_id)) { return; }

    let s_info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if ((s_info is !null) && s_info.is_interface) {
        let obj_ptr: String = next_reg(ref c);
        write_ir(ref c, c.indent + obj_ptr + " = extractvalue { i8*, i8* } " + reg + ", 0\n");
        write_ir(ref c, c.indent + "call void @__wl_retain(i8* " + obj_ptr + ")\n");

        return;
    }

    // arc hooks use an erased pointer, interface values keep the object in field zero
    let cast_reg: String = next_reg(ref c);
    let src_ty: String = get_llvm_type_str(ref c, type_id);
    if (src_ty == "i8*") {
        write_ir(ref c, c.indent + "call void @__wl_retain(i8* " + reg + ")\n");

        return;
    }

    write_ir(ref c, c.indent + cast_reg + " = bitcast " + src_ty + " " + reg + " to i8*\n");
    write_ir(ref c, c.indent + "call void @__wl_retain(i8* " + cast_reg + ")\n");
}

func emit_release(ref c: Compiler, reg: String, type_id: Int) -> Void {
    if (!is_ref_type(ref c, type_id)) {
        return;
    }

    let s_info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if ((s_info is !null) && s_info.is_interface) {
        let obj_ptr: String = next_reg(ref c);
        write_ir(ref c, c.indent + obj_ptr + " = extractvalue { i8*, i8* } " + reg + ", 0\n");
        write_ir(ref c, c.indent + "call void @__wl_release(i8* " + obj_ptr + ")\n");

        return;
    }

    let cast_reg: String = next_reg(ref c);
    let src_ty: String = get_llvm_type_str(ref c, type_id);
    if (src_ty == "i8*") {
        write_ir(ref c, c.indent + "call void @__wl_release(i8* " + reg + ")\n");

        return;
    }

    write_ir(ref c, c.indent + cast_reg + " = bitcast " + src_ty + " " + reg + " to i8*\n");
    write_ir(ref c, c.indent + "call void @__wl_release(i8* " + cast_reg + ")\n");
}

func emit_retain_value(ref c: Compiler, reg: String, type_id: Int) -> Void {
    if (is_ref_type(ref c, type_id)) {
        emit_retain(ref c, reg, type_id);
        return;
    }
    if (needs_drop(ref c, type_id)) {
        let llvm_ty: String = get_llvm_type_str(ref c, type_id);
        let slot: String = next_reg(ref c);
        write_ir(ref c, c.indent + slot + " = alloca " + llvm_ty + "\n");
        write_ir(ref c, c.indent + "store " + llvm_ty + " " + reg + ", " + llvm_ty + "* " + slot + "\n");

        emit_retain_slot(ref c, slot, type_id);
    }
}

func emit_drop_value(ref c: Compiler, reg: String, type_id: Int) -> Void {
    if (is_ref_type(ref c, type_id)) {
        emit_release(ref c, reg, type_id);
        return;
    }
    if (needs_drop(ref c, type_id)) {
        let llvm_ty: String = get_llvm_type_str(ref c, type_id);
        let slot: String = next_reg(ref c);
        write_ir(ref c, c.indent + slot + " = alloca " + llvm_ty + "\n");
        write_ir(ref c, c.indent + "store " + llvm_ty + " " + reg + ", " + llvm_ty + "* " + slot + "\n");

        emit_drop_slot(ref c, slot, type_id);
    }
}

func emit_release_owned(ref c: Compiler, value: CompileResult) -> Void {
    if (!has_result(value) || !value.owns_ref) {
        return;
    }
    if (is_void_ptr(ref c, value.type) && is_ref_type(ref c, value.origin_type)) {
        write_ir(ref c, c.indent + "call void @__wl_release(i8* " + value.reg + ")\n");

        return;
    }
    emit_drop_value(ref c, value.reg, value.type);
}

func emit_release_owned_args(ref c: Compiler, values: Vector(Struct)) -> Void {
    let i: Int = 0;
    while (i < values.length()) {
        let value: CompileResult = values[i];
        emit_release_owned(ref c, value);
        i += 1;
    }
}

func emit_alloc_check(ref c: Compiler, ptr_reg: String) -> Void {
    let failed: String = next_reg(ref c);
    write_ir(ref c, c.indent + failed + " = icmp eq i8* " + ptr_reg + ", null\n");

    let fail_label: String = next_label(ref c);
    let ok_label: String = next_label(ref c);

    write_ir(ref c, c.indent + "br i1 " + failed + ", label %" + fail_label + ", label %" + ok_label + "\n");
    write_ir(ref c, "\n" + fail_label + ":\n");
    write_ir(ref c, c.indent + "call void @__wl_oom()\n");
    write_ir(ref c, c.indent + "unreachable\n");
    write_ir(ref c, "\n" + ok_label + ":\n");
}

func emit_alloc_obj(ref c: Compiler, payload_size_reg: String, type_id_str: String, dest_llvm_type: String) -> String {
    let header_size: Int = 16;
    if (type_id_str == "" + TYPE_STRING) { header_size = 8; }
    let size_ty: String = get_size_llvm_type();

    let total_size: String = next_reg(ref c);
    write_ir(ref c, c.indent + total_size + " = add " + size_ty + " " + payload_size_reg + ", " + header_size + "\n");

    let raw_mem: String = next_reg(ref c);
    let alloc_hook: String = get_mangled_symbol(ref c, "memory_alloc", no_position());

    write_ir(ref c, c.indent + raw_mem + " = call i8* @" + alloc_hook + "(" + size_ty + " " + total_size + ")\n");

    emit_alloc_check(ref c, raw_mem);

    let header_mem: String = raw_mem;
    if (header_size == 16) {
        let drop_slot: String = next_reg(ref c);
        write_ir(ref c, c.indent + drop_slot + " = bitcast i8* " + raw_mem + " to i8**\n");

        let drop_fn: String = next_reg(ref c);
        write_ir(ref c, c.indent + drop_fn + " = bitcast void (i8*)* @__wl_drop." + type_id_str + " to i8*\n");
        write_ir(ref c, c.indent + "store i8* " + drop_fn + ", i8** " + drop_slot + "\n");

        header_mem = next_reg(ref c);
        write_ir(ref c, c.indent + header_mem + " = getelementptr inbounds i8, i8* " + raw_mem + ", i32 8\n");
    }

    let rc_ptr: String = next_reg(ref c);
    write_ir(ref c, c.indent + rc_ptr + " = bitcast i8* " + header_mem + " to i32*\n");
    write_ir(ref c, c.indent + "store i32 0, i32* " + rc_ptr + "\n");

    let type_ptr_i8: String = next_reg(ref c);
    write_ir(ref c, c.indent + type_ptr_i8 + " = getelementptr inbounds i8, i8* " + header_mem + ", i32 4\n");

    let type_ptr: String = next_reg(ref c);
    write_ir(ref c, c.indent + type_ptr + " = bitcast i8* " + type_ptr_i8 + " to i32*\n");
    write_ir(ref c, c.indent + "store i32 " + type_id_str + ", i32* " + type_ptr + "\n");

    let payload_i8: String = next_reg(ref c);
    write_ir(ref c, c.indent + payload_i8 + " = getelementptr inbounds i8, i8* " + header_mem + ", i32 8\n");

    if (dest_llvm_type == "i8*") { return payload_i8; }

    let final_ptr: String = next_reg(ref c);
    write_ir(ref c, c.indent + final_ptr + " = bitcast i8* " + payload_i8 + " to " + dest_llvm_type + "\n");

    return final_ptr;
}

func emit_alloc_closure(ref c: Compiler, type_id: Int) -> String {
    let closure: String = emit_alloc_obj(ref c, "" + closure_payload_size(), "" + TYPE_GENERIC_FUNCTION, "i8*");
    let tag_bytes: String = next_reg(ref c);
    let tag_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + tag_bytes + " = getelementptr inbounds i8, i8* " + closure + ", i32 -4\n");
    write_ir(ref c, c.indent + tag_slot + " = bitcast i8* " + tag_bytes + " to i32*\n");
    write_ir(ref c, c.indent + "store i32 " + type_id + ", i32* " + tag_slot + "\n");

    return closure;
}

func erased_struct_matches(actual: Int, expected: Int) -> Bool {
    return actual == expected;
}

func emit_erased_type_check(ref c: Compiler, value: String, expected: Int, pos: Position) -> Void {
    let matches: String = next_reg(ref c);
    let success: String = next_label(ref c);
    let failure: String = next_label(ref c);
    let helper: String = "@__wl_erased_accept_" + expected;
    c.erased_checks.put("" + expected, StringConstant(id=expected, value=helper));

    write_ir(ref c, c.indent + matches + " = call i1 " + helper + "(i8* " + value + ")\n");
    write_ir(ref c, c.indent + "br i1 " + matches + ", label %" + success + ", label %" + failure + "\n");
    write_ir(ref c, "\n" + failure + ":\n");

    emit_runtime_error(ref c, pos, "Erased value has the wrong concrete type");

    write_ir(ref c, "\n" + success + ":\n");
}

func hoist_allocas(ref c: Compiler, node: NodeID) -> Void {
// keep local storage in the entry block so loops do not grow the native stack
    if (!has_node(node)) {
        return;
    }

    let base: Int = node_tag(node);
    if (base == NODE_BLOCK) {
        let block: BlockNode = get_block_node(ref c.arena, node);
        let old_scope: Scope = c.hoist_scope;
        let parent: Int = c.hoist_scope_stack.length();
        c.hoist_scope_stack.append(old_scope);
        c.hoist_scope = Scope(parent=parent, table=Dict(), gc_vars=[], depth=old_scope.depth + 1);

        let stmts: Vector(NodeID) = block.stmts;
        let len: Int = stmts.length();
        let i: Int = 0;
        while (i < len) {
            hoist_allocas(ref c, stmts[i]);
            i += 1;
        }

        c.hoist_scope = old_scope;
    } else if (base == NODE_IF) {
        let if_n: IfNode = get_if_node(ref c.arena, node);
        hoist_allocas(ref c, if_n.body);
        hoist_allocas(ref c, if_n.else_body);
    } else if (base == NODE_WHILE) {
        let w_n: WhileNode = get_while_node(ref c.arena, node);
        hoist_allocas(ref c, w_n.body);
    } else if (base == NODE_FOR) {
        let f_n: ForNode = get_for_node(ref c.arena, node);
        hoist_allocas(ref c, f_n.init);
        hoist_allocas(ref c, f_n.body);
    } else if (base == NODE_CATCH) {
        let c_node: CatchNode = get_catch_node(ref c.arena, node);
        let err_reg: String = next_reg(ref c);
        c_node.alloc_id = c.alloc_regs.length();
        c.alloc_regs.append(err_reg);
        c.arena.catch_nodes[node_slot(node)] = c_node;

        write_ir(ref c, c.indent + err_reg + " = alloca { i64, i32 }\n");

        hoist_allocas(ref c, c_node.stmt);
        hoist_allocas(ref c, c_node.body);
    } else if (base == NODE_VAR_DECL) {
        let v_node: VarDeclareNode = get_var_decl_node(ref c.arena, node);
        if (c.scope_depth > 0) {
            let target_type_id: Int = resolve_type(ref c, v_node.type_node);

            if (target_type_id == TYPE_AUTO) {
                target_type_id = get_expr_type(ref c, v_node.value);
                // flow checks are not available during this walk, infer the read at its declaration.
                // the final alloca pass still moves the resulting slot into entry.
                v_node.alloc_id = -1;
                c.arena.var_decl_nodes[node_slot(node)] = v_node;
                if (target_type_id != TYPE_POISON && target_type_id != 0 && target_type_id != TYPE_AUTO && c.hoist_scope.table is !null) {
                    scope_put(c.hoist_scope, v_node.name_tok.value, SymbolInfo(reg="", type=target_type_id, origin_type=target_type_id, is_const=v_node.is_const, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
                }
                return;
            }

            // compile_var_decl reports the declaration error, no storage exists for Void.
            if (target_type_id == TYPE_VOID || target_type_id == TYPE_POISON) {
                return;
            }

            if (c.hoist_scope.table is !null) {
                scope_put(c.hoist_scope, v_node.name_tok.value, SymbolInfo(reg="", type=target_type_id, origin_type=target_type_id, is_const=v_node.is_const, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
            }

            let var_reg: String = next_reg(ref c);
            v_node.alloc_id = c.alloc_regs.length();
            c.alloc_regs.append(var_reg);
            c.arena.var_decl_nodes[node_slot(node)] = v_node;

            let llvm_ty_str: String = get_llvm_type_str(ref c, target_type_id);

            write_ir(ref c, c.indent + var_reg + " = alloca " + llvm_ty_str + "\n");

            if (needs_drop(ref c, target_type_id)) {
                write_ir(ref c, c.indent + "store " + llvm_ty_str + " zeroinitializer, " + llvm_ty_str + "* " + var_reg + "\n");
            }
        }
    }
}

func emit_runtime_error(ref c: Compiler, pos: Position, msg: String) -> Void {
    let hook_raw_str: String = get_mangled_symbol(ref c, "print_bytes", no_position());
    let hook_int: String = get_mangled_symbol(ref c, "print_int", no_position());

    if (hook_raw_str is !null && hook_int is !null) {
        let header_1: String = "RuntimeError: " + msg + "\n    at " + pos.fn + ":";
        let header_1_id: Int = register_string_constant(ref c, header_1);
        let header_1_ptr: String = get_string_ptr(header_1_id, header_1);

        let header_2: String = ":";
        let header_2_id: Int = register_string_constant(ref c, header_2);
        let header_2_ptr: String = get_string_ptr(header_2_id, header_2);

        let header_3: String = "\n\n";
        let header_3_id: Int = register_string_constant(ref c, header_3);
        let header_3_ptr: String = get_string_ptr(header_3_id, header_3);

        let ln: Int = pos.ln + 1;
        let col: Int = pos.col + 1;

        write_ir(ref c, c.indent + "call void @" + hook_raw_str + "(i8* " + header_1_ptr + ", i32 " + header_1.length() + ")\n");
        write_ir(ref c, c.indent + "call void @" + hook_int + "(i32 " + ln + ")\n");
        write_ir(ref c, c.indent + "call void @" + hook_raw_str + "(i8* " + header_2_ptr + ", i32 " + header_2.length() + ")\n");
        write_ir(ref c, c.indent + "call void @" + hook_int + "(i32 " + col + ")\n");
        write_ir(ref c, c.indent + "call void @" + hook_raw_str + "(i8* " + header_3_ptr + ", i32 " + header_3.length() + ")\n");

        let full_text: String = pos.text;
        if (c.emit_source_context && full_text.length() > 0) {
            let current_ln: Int = 0;
            let scan_idx: Int = 0;
            let len: Int = full_text.length();
            let line_start_idx: Int = 0;

            while (scan_idx < len) {
                if (current_ln == pos.ln) {
                    line_start_idx = scan_idx;
                    break;
                }
                if (full_text[scan_idx] == '\n') { current_ln += 1; }
                scan_idx += 1;
            }

            let line_end_idx: Int = line_start_idx;
            while (line_end_idx < len) {
                let ch: Char = full_text[line_end_idx];
                if (ch == '\n' || ch == '\r') {
                    break;
                }
                line_end_idx += 1;
            }

            let raw_line: String = full_text.slice(line_start_idx, line_end_idx);
            let code_content: String = "    " + raw_line + "\n";

            let code_id: Int = register_string_constant(ref c, code_content);
            let code_ptr: String = get_string_ptr(code_id, code_content);

            write_ir(ref c, c.indent + "call void @" + hook_raw_str + "(i8* " + code_ptr + ", i32 " + code_content.length() + ")\n");

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
            let arrow_id: Int = register_string_constant(ref c, arrow_str);
            let arrow_ptr: String = get_string_ptr(arrow_id, arrow_str);

            write_ir(ref c, c.indent + "call void @" + hook_raw_str + "(i8* " + arrow_ptr + ", i32 " + arrow_str.length() + ")\n");
        }
    }

    let exit_hook: String = get_mangled_symbol(ref c, "process_exit", pos);

    write_ir(ref c, c.indent + "call void @" + exit_hook + "(i32 1)\n");
    write_ir(ref c, c.indent + "unreachable\n");
}

func emit_pointer_null_check(ref c: Compiler, ptr_reg: String, type_id: Int, pos: Position) -> Void {
    let ptr_ty: String = get_llvm_type_str(ref c, type_id);
    let is_null: String = next_reg(ref c);
    write_ir(ref c, c.indent + is_null + " = icmp eq " + ptr_ty + " " + ptr_reg + ", null\n");

    let fail_label: String = next_label(ref c);
    let ok_label: String = next_label(ref c);

    write_ir(ref c, c.indent + "br i1 " + is_null + ", label %" + fail_label + ", label %" + ok_label + "\n");
    write_ir(ref c, "\n" + fail_label + ":\n");

    emit_runtime_error(ref c, pos, "Null pointer dereference");

    write_ir(ref c, "\n" + ok_label + ":\n");
}

func emit_native_ref_check(ref c: Compiler, value: String, type_id: Int, pos: Position) -> Void {
// native code can return zero even when its declared White type is non-null
    if (!is_ref_type(ref c, type_id)) { return; }

    let info = c.struct_id_map.lookup(get_repr_type(ref c, type_id));
    if (info is !null && info.is_interface) {
        let llvm_type = get_llvm_type_str(ref c, type_id);
        let object = next_reg(ref c);
        let table = next_reg(ref c);
        write_ir(ref c, c.indent + object + " = extractvalue " + llvm_type + " " + value + ", 0\n");
        write_ir(ref c, c.indent + table + " = extractvalue " + llvm_type + " " + value + ", 1\n");
        emit_pointer_null_check(ref c, object, TYPE_ANYPTR, pos);
        emit_pointer_null_check(ref c, table, TYPE_ANYPTR, pos);
        return;
    }

    emit_pointer_null_check(ref c, value, type_id, pos);
}

func emit_size_to_int(ref c: Compiler, value: String) -> String {
    let size_ty: String = get_size_llvm_type();
    if (size_ty == "i32") { return value; }
    let result: String = next_reg(ref c);
    write_ir(ref c, c.indent + result + " = trunc " + size_ty + " " + value + " to i32\n");

    return result;
}

func emit_int_to_size(ref c: Compiler, value: String, signed: Bool) -> String {
    let size_ty: String = get_size_llvm_type();
    if (size_ty == "i32") { return value; }
    let result: String = next_reg(ref c);
    let op: String = "zext";
    if signed { op = "sext"; }

    write_ir(ref c, c.indent + result + " = " + op + " i32 " + value + " to " + size_ty + "\n");

    return result;
}

func emit_vector_bounds_check(ref c: Compiler, vec_reg: String, idx_reg: String, struct_ty: String, pos: Position) -> Void {
    let size_ty: String = get_size_llvm_type();
    let size_ptr: String = next_reg(ref c);
    write_ir(ref c, c.indent + size_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_reg + ", i32 0, i32 0\n");

    let size_val: String = next_reg(ref c);
    write_ir(ref c, c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");

    let size_index: String = emit_int_to_size(ref c, idx_reg, true);

    let cmp_reg: String = next_reg(ref c);
    write_ir(ref c, c.indent + cmp_reg + " = icmp uge " + size_ty + " " + size_index + ", " + size_val + "\n");

    let fail_label: String = "bounds_fail_" + c.type_counter;
    let ok_label: String = "bounds_ok_" + c.type_counter;
    c.type_counter += 1;

    write_ir(ref c, c.indent + "br i1 " + cmp_reg + ", label %" + fail_label + ", label %" + ok_label + "\n");

    write_ir(ref c, "\n" + fail_label + ":\n");

    emit_runtime_error(ref c, pos, "Index out of bounds");

    write_ir(ref c, "\n" + ok_label + ":\n");
}

func emit_array_bounds_check(ref c: Compiler, idx_reg: String, len_val: String, pos: Position) -> Void {
    let cmp1: String = next_reg(ref c);
    write_ir(ref c, c.indent + cmp1 + " = icmp slt i32 " + idx_reg + ", 0\n");

    let cmp2: String = next_reg(ref c);
    write_ir(ref c, c.indent + cmp2 + " = icmp sge i32 " + idx_reg + ", " + len_val + "\n");

    let or1: String = next_reg(ref c);
    write_ir(ref c, c.indent + or1 + " = or i1 " + cmp1 + ", " + cmp2 + "\n");

    let fail_lbl: String = "arr_fail_" + c.type_counter;
    let ok_lbl: String = "arr_ok_" + c.type_counter;
    c.type_counter += 1;

    write_ir(ref c, c.indent + "br i1 " + or1 + ", label %" + fail_lbl + ", label %" + ok_lbl + "\n");
    write_ir(ref c, "\n" + fail_lbl + ":\n");

    emit_runtime_error(ref c, pos, "Index out of bounds.");

    write_ir(ref c, "\n" + ok_lbl + ":\n");
}

func emit_slice_bounds_check(ref c: Compiler, start_reg: String, end_reg: String, len_val: String, pos: Position) -> Void {
    let cmp1: String = next_reg(ref c);
    write_ir(ref c, c.indent + cmp1 + " = icmp slt i32 " + start_reg + ", 0\n");

    let cmp2: String = next_reg(ref c);
    write_ir(ref c, c.indent + cmp2 + " = icmp sgt i32 " + start_reg + ", " + end_reg + "\n");

    let cmp3: String = next_reg(ref c);
    write_ir(ref c, c.indent + cmp3 + " = icmp sgt i32 " + end_reg + ", " + len_val + "\n");

    let or1: String = next_reg(ref c);
    write_ir(ref c, c.indent + or1 + " = or i1 " + cmp1 + ", " + cmp2 + "\n");

    let or2: String = next_reg(ref c);
    write_ir(ref c, c.indent + or2 + " = or i1 " + or1 + ", " + cmp3 + "\n");

    let fail_lbl: String = "slice_fail_" + c.type_counter;
    let ok_lbl: String = "slice_ok_" + c.type_counter;
    c.type_counter += 1;

    write_ir(ref c, c.indent + "br i1 " + or2 + ", label %" + fail_lbl + ", label %" + ok_lbl + "\n");
    write_ir(ref c, "\n" + fail_lbl + ":\n");

    emit_runtime_error(ref c, pos, "Slice boundaries out of range.");

    write_ir(ref c, "\n" + ok_lbl + ":\n");
}

func emit_slice_parts(ref c: Compiler, slice_reg: String, slice_type: Int, pos: Position) -> SliceParts {
    let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(slice_type);
    if (arr_info is null) {
        throw_type_error(pos, "Expected a slice type.");
        return SliceParts(start="", length="", owner="", data_slot="", size_slot="", data="");
    }
    let elem_ty: String = get_llvm_type_str(ref c, arr_info.base_type);
    let slice_ty: String = arr_info.llvm_name;
    let size_ty: String = get_size_llvm_type();
    emit_pointer_null_check(ref c, slice_reg, slice_type, pos);

    let start_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + start_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 0\n");

    let start: String = next_reg(ref c);
    write_ir(ref c, c.indent + start + " = load " + size_ty + ", " + size_ty + "* " + start_slot + "\n");

    let len_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + len_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 1\n");

    let length: String = next_reg(ref c);
    write_ir(ref c, c.indent + length + " = load " + size_ty + ", " + size_ty + "* " + len_slot + "\n");

    let owner_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + owner_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 2\n");

    let owner: String = next_reg(ref c);
    write_ir(ref c, c.indent + owner + " = load i8*, i8** " + owner_slot + "\n");

    let data_slot_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + data_slot_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 3\n");

    let data_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + data_slot + " = load " + elem_ty + "**, " + elem_ty + "*** " + data_slot_slot + "\n");

    let size_slot_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + size_slot_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 4\n");

    let size_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + size_slot + " = load " + size_ty + "*, " + size_ty + "** " + size_slot_slot + "\n");

    let owner_size: String = next_reg(ref c);
    write_ir(ref c, c.indent + owner_size + " = load " + size_ty + ", " + size_ty + "* " + size_slot + "\n");

    let slice_end: String = next_reg(ref c);
    write_ir(ref c, c.indent + slice_end + " = add " + size_ty + " " + start + ", " + length + "\n");

    let invalid: String = next_reg(ref c);
    write_ir(ref c, c.indent + invalid + " = icmp ugt " + size_ty + " " + slice_end + ", " + owner_size + "\n");

    let fail_label: String = next_label(ref c);
    let ok_label: String = next_label(ref c);

    write_ir(ref c, c.indent + "br i1 " + invalid + ", label %" + fail_label + ", label %" + ok_label + "\n");
    write_ir(ref c, "\n" + fail_label + ":\n");

    emit_runtime_error(ref c, pos, "Slice backing storage was shortened");

    write_ir(ref c, "\n" + ok_label + ":\n");

    let data: String = next_reg(ref c);
    write_ir(ref c, c.indent + data + " = load " + elem_ty + "*, " + elem_ty + "** " + data_slot + "\n");

    return SliceParts(start=start, length=length, owner=owner, data_slot=data_slot, size_slot=size_slot, data=data);
}

func emit_make_slice(ref c: Compiler, elem_type: Int, owner: String, data_slot: String, size_slot: String, start: String, length: String) -> CompileResult {
    let slice_type: Int = get_slice_type_id(ref c, elem_type);
    let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(slice_type);
    if (arr_info is null) {
        throw_internal_compiler_error(Position(idx=0, ln=0, col=0, text="", fn=""), "Missing slice layout.");
        return CompileResult(reg="poison", type=TYPE_POISON, origin_type=0, owns_ref=false, is_const_access=false);
    }
    let elem_ty: String = get_llvm_type_str(ref c, elem_type);
    let slice_ty: String = arr_info.llvm_name;
    let size_ty: String = get_size_llvm_type();

    let size_ptr: String = next_reg(ref c);
    write_ir(ref c, c.indent + size_ptr + " = getelementptr " + slice_ty + ", " + slice_ty + "* null, i32 1\n");

    let size: String = next_reg(ref c);
    write_ir(ref c, c.indent + size + " = ptrtoint " + slice_ty + "* " + size_ptr + " to " + size_ty + "\n");

    let result: String = emit_alloc_obj(ref c, size, "" + slice_type, slice_ty + "*");

    let start_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + start_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 0\n");
    write_ir(ref c, c.indent + "store " + size_ty + " " + start + ", " + size_ty + "* " + start_slot + "\n");

    let len_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + len_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 1\n");
    write_ir(ref c, c.indent + "store " + size_ty + " " + length + ", " + size_ty + "* " + len_slot + "\n");

    let owner_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + owner_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 2\n");
    write_ir(ref c, c.indent + "store i8* " + owner + ", i8** " + owner_slot + "\n");

    let data_slot_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + data_slot_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 3\n");
    write_ir(ref c, c.indent + "store " + elem_ty + "** " + data_slot + ", " + elem_ty + "*** " + data_slot_slot + "\n");

    let size_slot_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + size_slot_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 4\n");
    write_ir(ref c, c.indent + "store " + size_ty + "* " + size_slot + ", " + size_ty + "** " + size_slot_slot + "\n");
    write_ir(ref c, c.indent + "call void @__wl_retain(i8* " + owner + ")\n");

    return CompileResult(reg=result, type=slice_type, origin_type=0, owns_ref=false, is_const_access=false);
}

func emit_slice_copy(ref c: Compiler, elem_type: Int, source: String, start_i32: String, length_i32: String, pos: Position) -> CompileResult {
    let elem_ty: String = get_llvm_type_str(ref c, elem_type);
    let vec_type: Int = get_vector_type_id(ref c, elem_type);
    let vec_ty: String = get_vector_llvm_type(ref c, elem_type);
    let size_ty: String = get_size_llvm_type();

    let vec_size_ptr: String = next_reg(ref c);
    write_ir(ref c, c.indent + vec_size_ptr + " = getelementptr " + vec_ty + ", " + vec_ty + "* null, i32 1\n");

    let vec_size: String = next_reg(ref c);
    write_ir(ref c, c.indent + vec_size + " = ptrtoint " + vec_ty + "* " + vec_size_ptr + " to " + size_ty + "\n");

    let owner_ptr: String = emit_alloc_obj(ref c, vec_size, "" + vec_type, vec_ty + "*");

    let length: String = emit_int_to_size(ref c, length_i32, false);
    let start: String = emit_int_to_size(ref c, start_i32, false);
    let is_empty: String = next_reg(ref c);
    write_ir(ref c, c.indent + is_empty + " = icmp eq " + size_ty + " " + length + ", 0\n");

    let alloc_count: String = next_reg(ref c);
    write_ir(ref c, c.indent + alloc_count + " = select i1 " + is_empty + ", " + size_ty + " 1, " + size_ty + " " + length + "\n");

    let elem_size_ptr: String = next_reg(ref c);
    write_ir(ref c, c.indent + elem_size_ptr + " = getelementptr " + elem_ty + ", " + elem_ty + "* null, " + size_ty + " 1\n");

    let elem_size: String = next_reg(ref c);
    write_ir(ref c, c.indent + elem_size + " = ptrtoint " + elem_ty + "* " + elem_size_ptr + " to " + size_ty + "\n");

    let max_capacity: String = next_reg(ref c);
    write_ir(ref c, c.indent + max_capacity + " = udiv " + size_ty + " -1, " + elem_size + "\n");

    let overflow: String = next_reg(ref c);
    write_ir(ref c, c.indent + overflow + " = icmp ugt " + size_ty + " " + alloc_count + ", " + max_capacity + "\n");

    let fail_label: String = next_label(ref c);
    let alloc_label: String = next_label(ref c);

    write_ir(ref c, c.indent + "br i1 " + overflow + ", label %" + fail_label + ", label %" + alloc_label + "\n");
    write_ir(ref c, "\n" + fail_label + ":\n");
    write_ir(ref c, c.indent + "call void @__wl_oom()\n");
    write_ir(ref c, c.indent + "unreachable\n");
    write_ir(ref c, "\n" + alloc_label + ":\n");

    let bytes: String = next_reg(ref c);
    write_ir(ref c, c.indent + bytes + " = mul " + size_ty + " " + alloc_count + ", " + elem_size + "\n");

    let alloc_hook: String = get_mangled_symbol(ref c, "memory_alloc", pos);
    let raw_data: String = next_reg(ref c);
    write_ir(ref c, c.indent + raw_data + " = call i8* @" + alloc_hook + "(" + size_ty + " " + bytes + ")\n");

    emit_alloc_check(ref c, raw_data);
    let data: String = next_reg(ref c);
    write_ir(ref c, c.indent + data + " = bitcast i8* " + raw_data + " to " + elem_ty + "*\n");

    let size_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + size_slot + " = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* " + owner_ptr + ", i32 0, i32 0\n");
    write_ir(ref c, c.indent + "store " + size_ty + " " + length + ", " + size_ty + "* " + size_slot + "\n");

    let cap_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + cap_slot + " = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* " + owner_ptr + ", i32 0, i32 1\n");
    write_ir(ref c, c.indent + "store " + size_ty + " " + length + ", " + size_ty + "* " + cap_slot + "\n");

    let data_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + data_slot + " = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* " + owner_ptr + ", i32 0, i32 2\n");
    write_ir(ref c, c.indent + "store " + elem_ty + "* " + data + ", " + elem_ty + "** " + data_slot + "\n");

    let index: String = next_reg(ref c);
    write_ir(ref c, c.indent + index + " = alloca " + size_ty + "\n");
    write_ir(ref c, c.indent + "store " + size_ty + " 0, " + size_ty + "* " + index + "\n");

    let loop_cond: String = next_label(ref c);
    let loop_body: String = next_label(ref c);
    let loop_end: String = next_label(ref c);

    write_ir(ref c, c.indent + "br label %" + loop_cond + "\n");
    write_ir(ref c, "\n" + loop_cond + ":\n");

    let i: String = next_reg(ref c);
    write_ir(ref c, c.indent + i + " = load " + size_ty + ", " + size_ty + "* " + index + "\n");

    let more: String = next_reg(ref c);
    write_ir(ref c, c.indent + more + " = icmp ult " + size_ty + " " + i + ", " + length + "\n");
    write_ir(ref c, c.indent + "br i1 " + more + ", label %" + loop_body + ", label %" + loop_end + "\n");
    write_ir(ref c, "\n" + loop_body + ":\n");

    let source_index: String = next_reg(ref c);
    write_ir(ref c, c.indent + source_index + " = add " + size_ty + " " + start + ", " + i + "\n");

    let source_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + source_slot + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + source + ", " + size_ty + " " + source_index + "\n");

    let value: String = next_reg(ref c);
    write_ir(ref c, c.indent + value + " = load " + elem_ty + ", " + elem_ty + "* " + source_slot + "\n");

    let dest_slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + dest_slot + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + data + ", " + size_ty + " " + i + "\n");
    write_ir(ref c, c.indent + "store " + elem_ty + " " + value + ", " + elem_ty + "* " + dest_slot + "\n");

    if (needs_drop(ref c, elem_type)) {
        emit_retain_slot(ref c, dest_slot, elem_type);
    }
    let next: String = next_reg(ref c);
    write_ir(ref c, c.indent + next + " = add " + size_ty + " " + i + ", 1\n");
    write_ir(ref c, c.indent + "store " + size_ty + " " + next + ", " + size_ty + "* " + index + "\n");
    write_ir(ref c, c.indent + "br label %" + loop_cond + "\n");
    write_ir(ref c, "\n" + loop_end + ":\n");

    let owner: String = next_reg(ref c);
    write_ir(ref c, c.indent + owner + " = bitcast " + vec_ty + "* " + owner_ptr + " to i8*\n");

    return emit_make_slice(ref c, elem_type, owner, data_slot, size_slot, "0", length);
}

func emit_union_ownership(ref c: Compiler, slot: String, type_id: Int, retain: Bool) -> Void {
// the payload can contain stale pointers after reassignment, follow its tag only
    let found_union: Optional(UnionInfo) = get_union_type(ref c, get_repr_type(ref c, type_id));
    if (found_union is null) { return; }
    let union: UnionInfo = found_union;
    let storage: String = get_llvm_type_str(ref c, type_id);
    let tag_slot: String = next_reg(ref c);
    let tag: String = next_reg(ref c);
    write_ir(ref c, c.indent + tag_slot + " = getelementptr inbounds " + storage + ", " + storage + "* " + slot + ", i32 0, i32 0\n");
    write_ir(ref c, c.indent + tag + " = load i32, i32* " + tag_slot + "\n");

    let done: String = next_label(ref c);
    let i: Int = 0;
    while (i < union.members.length()) {
        let member: Int = union.members[i];
        if (needs_drop(ref c, member)) {
            let active: String = next_label(ref c);
            let next: String = next_label(ref c);
            let matches: String = next_reg(ref c);
            write_ir(ref c, c.indent + matches + " = icmp eq i32 " + tag + ", " + i + "\n");
            write_ir(ref c, c.indent + "br i1 " + matches + ", label %" + active + ", label %" + next + "\n");
            write_ir(ref c, "\n" + active + ":\n");

            let payload: String = emit_union_payload(ref c, slot, type_id, member);
            if retain { emit_retain_slot(ref c, payload, member); }
            else { emit_drop_slot(ref c, payload, member); }

            write_ir(ref c, c.indent + "br label %" + done + "\n");
            write_ir(ref c, "\n" + next + ":\n");
        }
        i++;
    }
    write_ir(ref c, c.indent + "br label %" + done + "\n");
    write_ir(ref c, "\n" + done + ":\n");
}

func emit_drop_slot(ref c: Compiler, ptr_reg: String, type_id: Int) -> Void {
    let union: Bool = is_union_type(ref c, get_repr_type(ref c, type_id));
    if (union) {
        if (needs_drop(ref c, type_id)) { emit_union_ownership(ref c, ptr_reg, type_id, false); }
        return;
    }
    if (is_fallible_type(ref c, type_id)) {
        let inner_type: Int = get_inner_fallible_type(ref c, type_id);
        if (!needs_drop(ref c, inner_type)) { return; }

        let fallible_ty: String = get_llvm_type_str(ref c, type_id);
        let err_ptr: String = next_reg(ref c);
        write_ir(ref c, c.indent + err_ptr + " = getelementptr inbounds " + fallible_ty + ", " + fallible_ty + "* " + ptr_reg + ", i32 0, i32 0\n");

        let is_err: String = next_reg(ref c);
        write_ir(ref c, c.indent + is_err + " = load i1, i1* " + err_ptr + "\n");

        let drop_label: String = next_label(ref c);
        let done_label: String = next_label(ref c);

        write_ir(ref c, c.indent + "br i1 " + is_err + ", label %" + done_label + ", label %" + drop_label + "\n");
        write_ir(ref c, "\n" + drop_label + ":\n");

        let value_ptr: String = next_reg(ref c);
        write_ir(ref c, c.indent + value_ptr + " = getelementptr inbounds " + fallible_ty + ", " + fallible_ty + "* " + ptr_reg + ", i32 0, i32 2\n");

        emit_drop_slot(ref c, value_ptr, inner_type);

        write_ir(ref c, c.indent + "br label %" + done_label + "\n");
        write_ir(ref c, "\n" + done_label + ":\n");

        return;
    }

    let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
    if ((arr_info is !null) && arr_info.size >= 0) {
        let meta_arr_info: ArrayInfo = arr_info;
        let i: Int = 0;
        while (i < meta_arr_info.size) {
            let elem_ptr: String = next_reg(ref c);
            write_ir(ref c, c.indent + elem_ptr + " = getelementptr inbounds " + meta_arr_info.llvm_name + ", " + meta_arr_info.llvm_name + "* " + ptr_reg + ", i32 0, i32 " + i + "\n");

            emit_drop_slot(ref c, elem_ptr, meta_arr_info.base_type);
            i += 1;
        }
        return;
    }

    if (is_value_struct(ref c, type_id)) {
        let info: Optional(StructInfo) = c.struct_id_map.lookup(get_repr_type(ref c, type_id));
        let i: Int = 0;
        while ((info is !null) && i < info.fields.length()) {
            let field: FieldInfo = info.fields[i];
            if (needs_drop(ref c, field.type)) {
                let field_ptr: String = next_reg(ref c);
                write_ir(ref c, c.indent + field_ptr + " = getelementptr inbounds " + info.llvm_name + ", " + info.llvm_name + "* " + ptr_reg + ", i32 0, i32 " + field.offset + "\n");

                emit_drop_slot(ref c, field_ptr, field.type);
            }
            i += 1;
        }
        return;
    }

    if (!is_ref_type(ref c, type_id)) { return; }
    let llvm_ty: String = get_llvm_type_str(ref c, type_id);
    let value: String = next_reg(ref c);
    write_ir(ref c, c.indent + value + " = load " + llvm_ty + ", " + llvm_ty + "* " + ptr_reg + "\n");

    emit_release(ref c, value, type_id);
}

func emit_retain_slot(ref c: Compiler, ptr_reg: String, type_id: Int) -> Void {
    let union: Bool = is_union_type(ref c, get_repr_type(ref c, type_id));
    if (union) {
        if (needs_drop(ref c, type_id)) { emit_union_ownership(ref c, ptr_reg, type_id, true); }
        return;
    }
    if (is_fallible_type(ref c, type_id)) {
        let inner_type: Int = get_inner_fallible_type(ref c, type_id);
        if (!needs_drop(ref c, inner_type)) {
            return;
        }

        let fallible_ty: String = get_llvm_type_str(ref c, type_id);
        let err_ptr: String = next_reg(ref c);
        write_ir(ref c, c.indent + err_ptr + " = getelementptr inbounds " + fallible_ty + ", " + fallible_ty + "* " + ptr_reg + ", i32 0, i32 0\n");

        let is_err: String = next_reg(ref c);
        write_ir(ref c, c.indent + is_err + " = load i1, i1* " + err_ptr + "\n");

        let retain_label: String = next_label(ref c);
        let done_label: String = next_label(ref c);

        write_ir(ref c, c.indent + "br i1 " + is_err + ", label %" + done_label + ", label %" + retain_label + "\n");
        write_ir(ref c, "\n" + retain_label + ":\n");

        let value_ptr: String = next_reg(ref c);
        write_ir(ref c, c.indent + value_ptr + " = getelementptr inbounds " + fallible_ty + ", " + fallible_ty + "* " + ptr_reg + ", i32 0, i32 2\n");

        emit_retain_slot(ref c, value_ptr, inner_type);

        write_ir(ref c, c.indent + "br label %" + done_label + "\n");
        write_ir(ref c, "\n" + done_label + ":\n");

        return;
    }

    let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
    if ((arr_info is !null) && arr_info.size >= 0) {
        let meta_arr_info: ArrayInfo = arr_info;
        let i: Int = 0;
        while (i < meta_arr_info.size) {
            let elem_ptr: String = next_reg(ref c);
            write_ir(ref c, c.indent + elem_ptr + " = getelementptr inbounds " + meta_arr_info.llvm_name + ", " + meta_arr_info.llvm_name + "* " + ptr_reg + ", i32 0, i32 " + i + "\n");

            emit_retain_slot(ref c, elem_ptr, meta_arr_info.base_type);
            i += 1;
        }
        return;
    }

    if (is_value_struct(ref c, type_id)) {
        let info: Optional(StructInfo) = c.struct_id_map.lookup(get_repr_type(ref c, type_id));
        let i: Int = 0;
        while ((info is !null) && i < info.fields.length()) {
            let field: FieldInfo = info.fields[i];
            if (needs_drop(ref c, field.type)) {
                let field_ptr: String = next_reg(ref c);
                write_ir(ref c, c.indent + field_ptr + " = getelementptr inbounds " + info.llvm_name + ", " + info.llvm_name + "* " + ptr_reg + ", i32 0, i32 " + field.offset + "\n");

                emit_retain_slot(ref c, field_ptr, field.type);
            }
            i += 1;
        }
        return;
    }

    if (!is_ref_type(ref c, type_id)) {
        return;
    }
    let llvm_ty: String = get_llvm_type_str(ref c, type_id);
    let value: String = next_reg(ref c);
    write_ir(ref c, c.indent + value + " = load " + llvm_ty + ", " + llvm_ty + "* " + ptr_reg + "\n");

    emit_retain(ref c, value, type_id);
}

func emit_type_drop(ref c: Compiler, type_id: Int) -> Void {
// one drop thunk per concrete type lets containers destroy erased elements safely

    let free_hook: String = get_mangled_symbol(ref c, "memory_free", no_position());

    write_ir(ref c, "define internal void @__wl_drop." + type_id + "(i8* %ptr) {\n");
    write_ir(ref c, "entry:\n");

    if (type_id == TYPE_GENERIC_FUNCTION) {
        write_ir(ref c, "  %env.addr = getelementptr inbounds i8, i8* %ptr, i32 " + closure_env_offset() + "\n");
        write_ir(ref c, "  %env.slot = bitcast i8* %env.addr to i8**\n");
        write_ir(ref c, "  %env = load i8*, i8** %env.slot\n");
        write_ir(ref c, "  call void @__wl_release(i8* %env)\n");
        write_ir(ref c, "  ret void\n");
        write_ir(ref c, "}\n\n");

        return;
    }

    let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
    if ((arr_info is !null) && arr_info.size == -1) {
        let slice_ty: String = arr_info.llvm_name;

        write_ir(ref c, "  %slice = bitcast i8* %ptr to " + slice_ty + "*\n");
        write_ir(ref c, "  %owner.slot = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* %slice, i32 0, i32 2\n");
        write_ir(ref c, "  %owner = load i8*, i8** %owner.slot\n");
        write_ir(ref c, "  call void @__wl_release(i8* %owner)\n");
        write_ir(ref c, "  ret void\n");
        write_ir(ref c, "}\n\n");

        return;
    }

    let variant_info: Optional(StructInfo) = c.struct_table.lookup("$Variant");
    if ((variant_info is !null) && type_id == variant_info.type_id) {
        write_ir(ref c, "  %box = bitcast i8* %ptr to %struct.$Variant*\n");
        write_ir(ref c, "  %tag.slot = getelementptr inbounds %struct.$Variant, %struct.$Variant* %box, i32 0, i32 0\n");
        write_ir(ref c, "  %tag = load i64, i64* %tag.slot\n");
        write_ir(ref c, "  switch i64 %tag, label %done [\n");

        let ref_cases: String = "";
        let seen_refs: Dict(String, StringConstant) = Dict();
        let ref_id: Int = 1;
        while (ref_id < c.type_counter) {
            if ((is_ref_type(ref c, ref_id) || is_value_struct(ref c, ref_id)) && ref_id != type_id) {
                ref_cases = append_variant_ref_case(ref c, ref_cases, seen_refs, ref_id);
            }
            ref_id += 1;
        }

        write_ir(ref c, ref_cases);
        write_ir(ref c, "  ]\n");
        write_ir(ref c, "release:\n");
        write_ir(ref c, "  %payload.slot = getelementptr inbounds %struct.$Variant, %struct.$Variant* %box, i32 0, i32 1\n");
        write_ir(ref c, "  %payload = load i64, i64* %payload.slot\n");
        write_ir(ref c, "  %value = inttoptr i64 %payload to i8*\n");
        write_ir(ref c, "  call void @__wl_release(i8* %value)\n");
        write_ir(ref c, "  br label %done\n");
        write_ir(ref c, "done:\n");
        write_ir(ref c, "  ret void\n");
        write_ir(ref c, "}\n\n");

        return;
    }

    let vec_info: Optional(SymbolInfo) = c.vector_base_map.lookup(type_id);
    if ((vec_info is !null)) {
        let elem_type: Int = vec_info.type;
        let elem_ty: String = get_llvm_type_str(ref c, elem_type);
        let vec_ty: String = get_vector_llvm_type(ref c, elem_type);
        let size_ty: String = get_size_llvm_type();

        write_ir(ref c, "  %vec = bitcast i8* %ptr to " + vec_ty + "*\n");
        write_ir(ref c, "  %size.slot = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* %vec, i32 0, i32 0\n");
        write_ir(ref c, "  %size = load " + size_ty + ", " + size_ty + "* %size.slot\n");
        write_ir(ref c, "  %data.slot = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* %vec, i32 0, i32 2\n");
        write_ir(ref c, "  %data = load " + elem_ty + "*, " + elem_ty + "** %data.slot\n");

        if (needs_drop(ref c, elem_type)) {
            write_ir(ref c, "  %index = alloca " + size_ty + "\n");
            write_ir(ref c, "  store " + size_ty + " 0, " + size_ty + "* %index\n");
            write_ir(ref c, "  br label %loop.cond\n");
            write_ir(ref c, "loop.cond:\n");
            write_ir(ref c, "  %i = load " + size_ty + ", " + size_ty + "* %index\n");
            write_ir(ref c, "  %more = icmp ult " + size_ty + " %i, %size\n");
            write_ir(ref c, "  br i1 %more, label %loop.body, label %loop.end\n");
            write_ir(ref c, "loop.body:\n");
            write_ir(ref c, "  %slot = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* %data, " + size_ty + " %i\n");

            emit_drop_slot(ref c, "%slot", elem_type);

            write_ir(ref c, "  %next = add " + size_ty + " %i, 1\n");
            write_ir(ref c, "  store " + size_ty + " %next, " + size_ty + "* %index\n");
            write_ir(ref c, "  br label %loop.cond\n");
            write_ir(ref c, "loop.end:\n");
        }

        write_ir(ref c, "  %data.raw = bitcast " + elem_ty + "* %data to i8*\n");
        write_ir(ref c, "  call void @" + free_hook + "(i8* %data.raw)\n");
        write_ir(ref c, "  ret void\n");
        write_ir(ref c, "}\n\n");

        return;
    }

    let s_info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if ((s_info is !null)) {
        let meta_s_info: StructInfo = s_info;
        if (meta_s_info.is_class) {
            let methods: Vector(Struct) = meta_s_info.vtable;
            let method_len: Int = methods.length();
            let method_i: Int = 0;
            let deinit: FuncInfo = FuncInfo(name="", base_name="", ret_type=0, arg_types=[], arg_names=[], is_varargs=false, ann_flags=0, compiler_link_name="", abi_name="", mutates_self=false, variadic_param=0, default_args=[], ref_body=NodeID(0U), ref_context=null, ref_bindings=null);
            while (method_i < method_len) {
                let method_info: FuncInfo = methods[method_i];
                if (method_info.base_name == "$deinit") {
                    deinit = method_info;
                    break;
                }
                method_i += 1;
            }
            if (has_func(deinit)) {
                let self_arg: TypeListNode = deinit.arg_types[0];
                let self_ty: String = get_llvm_type_str(ref c, self_arg.type);
                let deinit_ret: String = get_llvm_type_str(ref c, deinit.ret_type);

                write_ir(ref c, "  %self = bitcast i8* %ptr to " + self_ty + "\n");
                write_ir(ref c, "  call " + deinit_ret + " @" + deinit.name + "(" + self_ty + " %self)\n");
            }
        }

        write_ir(ref c, "  %object = bitcast i8* %ptr to " + meta_s_info.llvm_name + "*\n");

        let fields: Vector(Struct) = meta_s_info.fields;
        let field_len: Int = fields.length();
        let field_i: Int = 0;
        while (field_i < field_len) {
            let field: FieldInfo = fields[field_i];
            if (field.name != "_vptr" && needs_drop(ref c, field.type)) {
                let field_ptr: String = next_reg(ref c);
                write_ir(ref c, c.indent + field_ptr + " = getelementptr inbounds " + meta_s_info.llvm_name + ", " + meta_s_info.llvm_name + "* %object, i32 0, i32 " + field.offset + "\n");

                emit_drop_slot(ref c, field_ptr, field.type);
            }
            field_i += 1;
        }
    }

    write_ir(ref c, "  ret void\n");
    write_ir(ref c, "}\n\n");
}

func compile_arc_hooks(ref c: Compiler) -> Void {
    let free_hook: String = get_mangled_symbol(ref c, "memory_free", no_position());
    let exit_hook: String = get_mangled_symbol(ref c, "process_exit", no_position());

    write_ir(ref c, "define internal void @__wl_oom() noreturn {\n");
    write_ir(ref c, "entry:\n");
    write_ir(ref c, "  call void @" + exit_hook + "(i32 1)\n");
    write_ir(ref c, "  unreachable\n");
    write_ir(ref c, "}\n\n");

    write_ir(ref c, "define internal void @__wl_retain(i8* %ptr) {\n");
    write_ir(ref c, "entry:\n");
    write_ir(ref c, "  %is.null = icmp eq i8* %ptr, null\n");
    write_ir(ref c, "  br i1 %is.null, label %done, label %work\n");
    write_ir(ref c, "work:\n");
    write_ir(ref c, "  %base = getelementptr i8, i8* %ptr, i32 -8\n");
    write_ir(ref c, "  %rc.ptr = bitcast i8* %base to i32*\n");
    write_ir(ref c, "  %rc = load atomic i32, i32* %rc.ptr monotonic, align 4\n");
    write_ir(ref c, "  %is.static = icmp eq i32 %rc, -1\n");
    write_ir(ref c, "  br i1 %is.static, label %done, label %retain\n");
    write_ir(ref c, "retain:\n");
    write_ir(ref c, "  %old = atomicrmw add i32* %rc.ptr, i32 1 monotonic\n");
    write_ir(ref c, "  %invalid = icmp slt i32 %old, 0\n");
    write_ir(ref c, "  br i1 %invalid, label %trap, label %done\n");
    write_ir(ref c, "trap:\n");
    write_ir(ref c, "  call void @llvm.trap()\n");
    write_ir(ref c, "  unreachable\n");
    write_ir(ref c, "done:\n");
    write_ir(ref c, "  ret void\n");
    write_ir(ref c, "}\n\n");

    write_ir(ref c, "define internal void @__wl_release(i8* %ptr) {\n");
    write_ir(ref c, "entry:\n");
    write_ir(ref c, "  %is.null = icmp eq i8* %ptr, null\n");
    write_ir(ref c, "  br i1 %is.null, label %done, label %work\n");
    write_ir(ref c, "work:\n");
    write_ir(ref c, "  %base = getelementptr i8, i8* %ptr, i32 -8\n");
    write_ir(ref c, "  %rc.ptr = bitcast i8* %base to i32*\n");
    write_ir(ref c, "  %rc = load atomic i32, i32* %rc.ptr monotonic, align 4\n");
    write_ir(ref c, "  %is.static = icmp eq i32 %rc, -1\n");
    write_ir(ref c, "  br i1 %is.static, label %done, label %release\n");
    write_ir(ref c, "release:\n");
    write_ir(ref c, "  %old = atomicrmw sub i32* %rc.ptr, i32 1 acq_rel\n");
    write_ir(ref c, "  %invalid = icmp sle i32 %old, 0\n");
    write_ir(ref c, "  br i1 %invalid, label %trap, label %check.last\n");
    write_ir(ref c, "trap:\n");
    write_ir(ref c, "  call void @llvm.trap()\n");
    write_ir(ref c, "  unreachable\n");
    write_ir(ref c, "check.last:\n");
    write_ir(ref c, "  %is.last = icmp eq i32 %old, 1\n");
    write_ir(ref c, "  br i1 %is.last, label %destroy, label %done\n");
    write_ir(ref c, "destroy:\n");
    write_ir(ref c, "  %tag.addr = getelementptr inbounds i8, i8* %base, i32 4\n");
    write_ir(ref c, "  %tag.ptr = bitcast i8* %tag.addr to i32*\n");
    write_ir(ref c, "  %tag = load i32, i32* %tag.ptr\n");
    write_ir(ref c, "  %is.dynamic = icmp ne i32 %tag, " + TYPE_STRING + "\n");
    write_ir(ref c, "  br i1 %is.dynamic, label %destroy.dynamic, label %destroy.legacy\n");
    write_ir(ref c, "destroy.dynamic:\n");
    write_ir(ref c, "  %raw = getelementptr inbounds i8, i8* %base, i32 -8\n");
    write_ir(ref c, "  %drop.slot = bitcast i8* %raw to i8**\n");
    write_ir(ref c, "  %drop.raw = load i8*, i8** %drop.slot\n");
    write_ir(ref c, "  %drop = bitcast i8* %drop.raw to void (i8*)*\n");
    write_ir(ref c, "  call void %drop(i8* %ptr)\n");
    write_ir(ref c, "  call void @" + free_hook + "(i8* %raw)\n");
    write_ir(ref c, "  br label %done\n");
    write_ir(ref c, "destroy.legacy:\n");
    write_ir(ref c, "  call void @" + free_hook + "(i8* %base)\n");
    write_ir(ref c, "  br label %done\n");
    write_ir(ref c, "done:\n");
    write_ir(ref c, "  ret void\n");
    write_ir(ref c, "}\n\n");

    emit_type_drop(ref c, TYPE_GENERIC_FUNCTION);

    let variant_info: Optional(StructInfo) = c.struct_table.lookup("$Variant");
    if ((variant_info is !null)) {
        emit_type_drop(ref c, variant_info.type_id);
    }

    let type_id: Int = 100;
    while (type_id < c.type_counter) {
        let should_emit: Bool = false;
        let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
        if ((arr_info is !null) && arr_info.size == -1) { should_emit = true; }
        if ((c.vector_base_map.lookup(type_id) is !null)) { should_emit = true; }

        let s_info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
        if ((s_info is !null) && !s_info.is_enum && !s_info.is_interface) {
            if (!(variant_info is !null) || type_id != variant_info.type_id) { should_emit = true; }
        }

        if should_emit { emit_type_drop(ref c, type_id); }
        type_id += 1;
    }
}

func emit_erased_check_helpers(ref c: Compiler) -> Void {
    let slot: Int = 0;
    while (slot < c.erased_checks.capacity) {
        if (c.erased_checks.hashes[slot] >= 2) {
            let entry: StringConstant = c.erased_checks.values[slot];
            let expected: Int = entry.id;

            write_ir(ref c, "define internal i1 " + entry.value + "(i8* %value) {\n");
            write_ir(ref c, "entry:\n");
            write_ir(ref c, "  %is_null = icmp eq i8* %value, null\n");
            let null_target = "accept";
            if (entry.value.starts_with("@__wl_is_instance_")) { null_target = "reject"; }
            write_ir(ref c, "  br i1 %is_null, label %" + null_target + ", label %inspect\n");
            write_ir(ref c, "inspect:\n");
            write_ir(ref c, "  %tag_bytes = getelementptr i8, i8* %value, i32 -4\n");
            write_ir(ref c, "  %tag_slot = bitcast i8* %tag_bytes to i32*\n");
            write_ir(ref c, "  %tag = load i32, i32* %tag_slot\n");
            write_ir(ref c, "  switch i32 %tag, label %reject [\n");

                let candidate: Int = 100;
                while (candidate < c.type_counter) {
                    let accepted: Bool = candidate == expected;
                    if (!accepted) { accepted = callable_types_compatible(ref c, candidate, expected); }

                    let expected_info: Optional(StructInfo) = c.struct_id_map.lookup(expected);
                if (!accepted && (expected_info is !null) && expected_info.is_class) {
                    accepted = is_subclass(ref c, candidate, expected);
                }
                if accepted {
                    write_ir(ref c, "    i32 " + candidate + ", label %accept\n");
                }
                candidate += 1;
            }

            write_ir(ref c, "  ]\n");
            write_ir(ref c, "accept:\n");
            write_ir(ref c, "  ret i1 true\n");
            write_ir(ref c, "reject:\n");
            write_ir(ref c, "  ret i1 false\n");
            write_ir(ref c, "}\n\n");
        }
        slot += 1;
    }
}
