// src/compiler/lowering/unions.wl
import * from "../context.wl"
import * from "../../frontend/diagnostics.wl"
import * from "../narrowing.wl"
import emit_implicit_cast from "casts.wl"
import NodeID from "../../frontend/ast.wl"


func emit_union_payload(ref c: Compiler, slot: String, union_type: Int, member: Int) -> String {
// access the carrier through the selected member, inactive bytes are never read
    let layout: UnionLayout = get_union_layout(ref c, get_repr_type(ref c, union_type));
    let storage: String = get_llvm_type_str(ref c, union_type);
    let carrier: String = "[" + layout.payload_count + " x " + get_llvm_type_str(ref c, layout.payload_type) + "]";
    let address: String = next_reg(ref c);
    let payload: String = next_reg(ref c);
    write_ir(ref c, c.indent + address + " = getelementptr inbounds " + storage + ", " + storage + "* " + slot + ", i32 0, i32 1\n");
    write_ir(ref c, c.indent + payload + " = bitcast " + carrier + "* " + address + " to " + get_llvm_type_str(ref c, member) + "*\n");

    return payload;
}

func emit_union_read(ref c: Compiler, value: CompileResult, member: Int) -> CompileResult {
// a dominating check selected this member, no conversion or extra ownership is involved
    if (member == TYPE_NULL) { return CompileResult(reg="null", type=TYPE_NULL, origin_type=0, owns_ref=false, is_const_access=false); }
    if (is_union_type(ref c, member)) {
        value.owns_ref = false;
        return emit_union_cast(ref c, value, member, no_position(), true);
    }
    let storage = get_llvm_type_str(ref c, value.type);
    let slot = next_reg(ref c);
    write_ir(ref c, c.indent + slot + " = alloca " + storage + "\n");
    write_ir(ref c, c.indent + "store " + storage + " " + value.reg + ", " + storage + "* " + slot + "\n");
    let address = emit_union_payload(ref c, slot, value.type, member);
    let array = c.array_info_map.lookup(member);
    if ((array is !null) && array.size >= 0) {
        return CompileResult(reg=address, type=member, is_const_access=value.is_const_access, origin_type=0, owns_ref=false);
    }
    let result = next_reg(ref c);
    let member_type = get_llvm_type_str(ref c, member);
    write_ir(ref c, c.indent + result + " = load " + member_type + ", " + member_type + "* " + address + "\n");
    return CompileResult(reg=result, type=member, is_const_access=value.is_const_access, origin_type=0, owns_ref=false);
}

func apply_flow_guard(ref c: Compiler, condition: NodeID, truth: Bool) -> Void {
    flow_apply_guard(ref c, condition, truth);
}

func emit_union_member(ref c: Compiler, slot: String, target: Int, member: Int, value: String) -> Void {
    if (member != TYPE_NULL) {
        let payload: String = emit_union_payload(ref c, slot, target, member);
        let member_type: String = get_llvm_type_str(ref c, member);
        write_ir(ref c, c.indent + "store " + member_type + " " + value + ", " + member_type + "* " + payload + "\n");
    }

    let tag_slot: String = next_reg(ref c);
    let storage: String = get_llvm_type_str(ref c, target);
    write_ir(ref c, c.indent + tag_slot + " = getelementptr inbounds " + storage + ", " + storage + "* " + slot + ", i32 0, i32 0\n");
    write_ir(ref c, c.indent + "store i32 " + union_member_index(ref c, target, member) + ", i32* " + tag_slot + "\n");
}

func emit_union_cast(ref c: Compiler, value: CompileResult, target: Int, pos: Position, checked: Bool = false) -> CompileResult {
    if ((!checked && !union_accepts_type(ref c, target, value.type)) ||
        (checked && !union_accepts_type(ref c, value.type, target))) {
        throw_type_error(pos, "Type mismatch. Expected " + get_type_name(ref c, target) + ", got " + get_type_name(ref c, value.type) + ".");
        return CompileResult(reg="poison", type=TYPE_POISON, origin_type=0, owns_ref=false, is_const_access=false);
    }

    let storage: String = get_llvm_type_str(ref c, target);
    let slot: String = next_reg(ref c);
    write_ir(ref c, c.indent + slot + " = alloca " + storage + "\n");
    write_ir(ref c, c.indent + "store " + storage + " zeroinitializer, " + storage + "* " + slot + "\n");

    let found_source_union: Optional(UnionInfo) = get_union_type(ref c, value.type);
    if (found_source_union is null) {
        let array = c.array_info_map.lookup(value.type);
        if ((array is !null) && array.size >= 0) {
            let loaded = next_reg(ref c);
            write_ir(ref c, c.indent + loaded + " = load " + array.llvm_name + ", " + array.llvm_name + "* " + value.reg + "\n");
            value.reg = loaded;
        }
        let member = union_member_target(ref c, target, value.type);
        value = emit_implicit_cast(ref c, value, member, pos);
        emit_union_member(ref c, slot, target, member, value.reg);
    } else {
        let source_union: UnionInfo = found_source_union;
        let source_ty: String = get_llvm_type_str(ref c, value.type);
        let source_slot: String = next_reg(ref c);
        let tag: String = next_reg(ref c);
        write_ir(ref c, c.indent + source_slot + " = alloca " + source_ty + "\n");
        write_ir(ref c, c.indent + "store " + source_ty + " " + value.reg + ", " + source_ty + "* " + source_slot + "\n");
        write_ir(ref c, c.indent + tag + " = extractvalue " + source_ty + " " + value.reg + ", 0\n");

        let done: String = next_label(ref c);
        let i: Int = 0;
        while (i < source_union.members.length()) {
            let member: Int = source_union.members[i];
            let selected = union_member_target(ref c, target, member);
            if (checked && union_member_index(ref c, target, member) < 0) { i++; continue; }
            let copy: String = next_label(ref c);
            let next: String = next_label(ref c);
            let matches: String = next_reg(ref c);
            write_ir(ref c, c.indent + matches + " = icmp eq i32 " + tag + ", " + i + "\n");
            write_ir(ref c, c.indent + "br i1 " + matches + ", label %" + copy + ", label %" + next + "\n");
            write_ir(ref c, "\n" + copy + ":\n");

            let payload: String = "";
            if (member != TYPE_NULL) {
                let address: String = emit_union_payload(ref c, source_slot, value.type, member);
                let member_type: String = get_llvm_type_str(ref c, member);
                payload = next_reg(ref c);
                write_ir(ref c, c.indent + payload + " = load " + member_type + ", " + member_type + "* " + address + "\n");
            }
            if (selected != member) {
                let converted = emit_implicit_cast(ref c, CompileResult(reg=payload, type=member, origin_type=0, owns_ref=false, is_const_access=value.is_const_access), selected, pos);
                payload = converted.reg;
            }
            emit_union_member(ref c, slot, target, selected, payload);
            write_ir(ref c, c.indent + "br label %" + done + "\n");
            write_ir(ref c, "\n" + next + ":\n");
            i++;
        }
        write_ir(ref c, c.indent + "unreachable\n");
        write_ir(ref c, "\n" + done + ":\n");
    }

    let result: String = next_reg(ref c);
    write_ir(ref c, c.indent + result + " = load " + storage + ", " + storage + "* " + slot + "\n");
    return CompileResult(reg=result, type=target, owns_ref=value.owns_ref, is_const_access=value.is_const_access, origin_type=0);
}

func emit_union_null_check(ref c: Compiler, value: CompileResult, negate: Bool) -> CompileResult {
    let member: Int = union_member_index(ref c, get_repr_type(ref c, value.type), TYPE_NULL);
    if (member < 0) {
        let result: String = "false";
        if negate { result = "true"; }
        return CompileResult(reg=result, type=TYPE_BOOL, origin_type=0, owns_ref=false, is_const_access=false);
    }

    let tag: String = next_reg(ref c);
    let result: String = next_reg(ref c);
    let condition: String = "eq";
    if negate { condition = "ne"; }
    write_ir(ref c, c.indent + tag + " = extractvalue " + get_llvm_type_str(ref c, value.type) + " " + value.reg + ", 0\n");
    write_ir(ref c, c.indent + result + " = icmp " + condition + " i32 " + tag + ", " + member + "\n");

    return CompileResult(reg=result, type=TYPE_BOOL, origin_type=0, owns_ref=false, is_const_access=false);
}
