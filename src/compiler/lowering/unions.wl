// src/compiler/lowering/unions.wl
import * from "../context.wl"
import * from "../../frontend/diagnostics.wl"
import * from "../narrowing.wl"
import NodeID from "../../frontend/ast.wl"


func emit_union_payload(ref c: Compiler, slot: String, union_type: Int, member: Int) -> String {
// access the carrier through the selected member, inactive bytes are never read
    let layout: UnionLayout = get_union_layout(ref c, get_repr_type(ref c, union_type));
    let storage: String = get_llvm_type_str(ref c, union_type);
    let carrier: String = "[" + layout.payload_count + " x " + get_llvm_type_str(ref c, layout.payload_type) + "]";
    let address: String = next_reg(ref c);
    let payload: String = next_reg(ref c);
    c.output_file.write(c.indent + address + " = getelementptr inbounds " + storage + ", " + storage + "* " + slot + ", i32 0, i32 1\n");
    c.output_file.write(c.indent + payload + " = bitcast " + carrier + "* " + address + " to " + get_llvm_type_str(ref c, member) + "*\n");

    return payload;
}

func emit_union_read(ref c: Compiler, value: CompileResult, member: Int) -> CompileResult {
// a dominating check selected this member, no conversion or extra ownership is involved
    if (member == TYPE_NULL) { return CompileResult(reg="null", type=TYPE_NULL); }
    let storage = get_llvm_type_str(ref c, value.type);
    let slot = next_reg(ref c);
    c.output_file.write(c.indent + slot + " = alloca " + storage + "\n");
    c.output_file.write(c.indent + "store " + storage + " " + value.reg + ", " + storage + "* " + slot + "\n");
    let address = emit_union_payload(ref c, slot, value.type, member);
    let array = c.array_info_map.lookup(member);
    if (has_array_info(array) && array.size >= 0) {
        return CompileResult(reg=address, type=member, is_const_access=value.is_const_access);
    }
    let result = next_reg(ref c);
    let member_type = get_llvm_type_str(ref c, member);
    c.output_file.write(c.indent + result + " = load " + member_type + ", " + member_type + "* " + address + "\n");
    return CompileResult(reg=result, type=member, is_const_access=value.is_const_access);
}

func apply_flow_guard(ref c: Compiler, condition: NodeID, truth: Bool) -> Void {
    if (!flow_has_guard(ref c, condition)) { return; }
    let guards: Vector(FlowGuard) = [];
    flow_guards(ref c, condition, truth, guards);
    let i = 0;
    while (i < guards.length()) {
        let guard = guards[i];
        let old_skip = c.flow_skip;
        c.flow_skip = guard.target;
        let original = get_expr_type(ref c, guard.target);
        c.flow_skip = old_skip;
        let path = format_ast_path(ref c, guard.target);
        let root = path;
        let dot = 0;
        while (dot < root.length() && root[dot] != Byte(46)) { dot++; }
        if (dot < root.length()) { root = root.slice(0, dot); }
        let symbol = find_symbol(ref c, root);
        let unstable = flow_has_field(path) || !has_symbol(symbol);
        if (has_symbol(symbol)) { unstable = unstable || symbol.reg.starts_with("@") || symbol.is_reference; }
        unstable = unstable || flow_is_exposed(ref c, path);
        if (!unstable || !flow_has_call(ref c, condition)) {
            flow_record(ref c, guard.target, original, guard.present, unstable);
        }
        i++;
    }
}

func emit_union_member(ref c: Compiler, slot: String, target: Int, member: Int, value: String) -> Void {
    if (member != TYPE_NULL) {
        let payload: String = emit_union_payload(ref c, slot, target, member);
        let member_type: String = get_llvm_type_str(ref c, member);
        c.output_file.write(c.indent + "store " + member_type + " " + value + ", " + member_type + "* " + payload + "\n");
    }

    let tag_slot: String = next_reg(ref c);
    let storage: String = get_llvm_type_str(ref c, target);
    c.output_file.write(c.indent + tag_slot + " = getelementptr inbounds " + storage + ", " + storage + "* " + slot + ", i32 0, i32 0\n");
    c.output_file.write(c.indent + "store i32 " + union_member_index(ref c, target, member) + ", i32* " + tag_slot + "\n");
}

func emit_union_cast(ref c: Compiler, value: CompileResult, target: Int, pos: Position) -> CompileResult {
    if (!union_accepts_type(ref c, target, value.type)) {
        throw_type_error(pos, "Type mismatch. Expected " + get_type_name(ref c, target) + ", got " + get_type_name(ref c, value.type) + ".");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let storage: String = get_llvm_type_str(ref c, target);
    let slot: String = next_reg(ref c);
    c.output_file.write(c.indent + slot + " = alloca " + storage + "\n");
    c.output_file.write(c.indent + "store " + storage + " zeroinitializer, " + storage + "* " + slot + "\n");

    let source_union: UnionInfo = get_union_type(ref c, value.type);
    if (source_union.members is null) {
        let array = c.array_info_map.lookup(value.type);
        if (has_array_info(array) && array.size >= 0) {
            let loaded = next_reg(ref c);
            c.output_file.write(c.indent + loaded + " = load " + array.llvm_name + ", " + array.llvm_name + "* " + value.reg + "\n");
            value.reg = loaded;
        }
        emit_union_member(ref c, slot, target, value.type, value.reg);
    } else {
        let source_ty: String = get_llvm_type_str(ref c, value.type);
        let source_slot: String = next_reg(ref c);
        let tag: String = next_reg(ref c);
        c.output_file.write(c.indent + source_slot + " = alloca " + source_ty + "\n");
        c.output_file.write(c.indent + "store " + source_ty + " " + value.reg + ", " + source_ty + "* " + source_slot + "\n");
        c.output_file.write(c.indent + tag + " = extractvalue " + source_ty + " " + value.reg + ", 0\n");

        let done: String = next_label(ref c);
        let i: Int = 0;
        while (i < source_union.members.length()) {
            let member: Int = source_union.members[i];
            let copy: String = next_label(ref c);
            let next: String = next_label(ref c);
            let matches: String = next_reg(ref c);
            c.output_file.write(c.indent + matches + " = icmp eq i32 " + tag + ", " + i + "\n");
            c.output_file.write(c.indent + "br i1 " + matches + ", label %" + copy + ", label %" + next + "\n");
            c.output_file.write("\n" + copy + ":\n");

            let payload: String = "";
            if (member != TYPE_NULL) {
                let address: String = emit_union_payload(ref c, source_slot, value.type, member);
                let member_type: String = get_llvm_type_str(ref c, member);
                payload = next_reg(ref c);
                c.output_file.write(c.indent + payload + " = load " + member_type + ", " + member_type + "* " + address + "\n");
            }
            emit_union_member(ref c, slot, target, member, payload);
            c.output_file.write(c.indent + "br label %" + done + "\n");
            c.output_file.write("\n" + next + ":\n");
            i++;
        }
        c.output_file.write(c.indent + "unreachable\n");
        c.output_file.write("\n" + done + ":\n");
    }

    let result: String = next_reg(ref c);
    c.output_file.write(c.indent + result + " = load " + storage + ", " + storage + "* " + slot + "\n");
    return CompileResult(reg=result, type=target, owns_ref=value.owns_ref, is_const_access=value.is_const_access);
}

func emit_union_null_check(ref c: Compiler, value: CompileResult, negate: Bool) -> CompileResult {
    let member: Int = union_member_index(ref c, get_repr_type(ref c, value.type), TYPE_NULL);
    if (member < 0) {
        let result: String = "false";
        if negate { result = "true"; }
        return CompileResult(reg=result, type=TYPE_BOOL);
    }

    let tag: String = next_reg(ref c);
    let result: String = next_reg(ref c);
    let condition: String = "eq";
    if negate { condition = "ne"; }
    c.output_file.write(c.indent + tag + " = extractvalue " + get_llvm_type_str(ref c, value.type) + " " + value.reg + ", 0\n");
    c.output_file.write(c.indent + result + " = icmp " + condition + " i32 " + tag + ", " + member + "\n");

    return CompileResult(reg=result, type=TYPE_BOOL);
}
