// src/compiler/lowering/native_values.wl
import * from "../context.wl"
import * from "../../frontend/diagnostics.wl"
import emit_pointer_null_check, emit_runtime_error from "ownership.wl"
import emit_union_payload from "unions.wl"


func emit_native_value_check(ref c: Compiler, value: String, type_id: Int, pos: Position) -> Void {
// check the active inline payload before ARC or source code can consume it
    if (!needs_native_check(ref c, type_id)) { return; }
    let repr = get_repr_type(ref c, type_id);
    let storage = get_llvm_type_str(ref c, type_id);
    if (repr == TYPE_CHAR) {
        let range = next_reg(ref c);
        let below = next_reg(ref c);
        let above = next_reg(ref c);
        let outside = next_reg(ref c);
        let valid = next_reg(ref c);
        write_ir(ref c, c.indent + range + " = icmp ule i32 " + value + ", 1114111\n");
        write_ir(ref c, c.indent + below + " = icmp ult i32 " + value + ", 55296\n");
        write_ir(ref c, c.indent + above + " = icmp ugt i32 " + value + ", 57343\n");
        write_ir(ref c, c.indent + outside + " = or i1 " + below + ", " + above + "\n");
        write_ir(ref c, c.indent + valid + " = and i1 " + range + ", " + outside + "\n");
        emit_native_condition(ref c, valid, pos, "Invalid native Char value");
        return;
    }
    let info = c.struct_id_map.lookup(repr);
    if (is_ref_type(ref c, type_id)) {
        if (info is !null && info.is_interface) {
            let object = next_reg(ref c);
            let table = next_reg(ref c);
            write_ir(ref c, c.indent + object + " = extractvalue " + storage + " " + value + ", 0\n");
            write_ir(ref c, c.indent + table + " = extractvalue " + storage + " " + value + ", 1\n");
            emit_pointer_null_check(ref c, object, TYPE_ANYPTR, pos);
            emit_pointer_null_check(ref c, table, TYPE_ANYPTR, pos);
        } else {
            emit_pointer_null_check(ref c, value, type_id, pos);
        }
        return;
    }

    if (is_fallible_type(ref c, repr)) {
        let is_error = next_reg(ref c);
        let payload = next_reg(ref c);
        let active = next_label(ref c);
        let done = next_label(ref c);
        write_ir(ref c, c.indent + is_error + " = extractvalue " + storage + " " + value + ", 0\n");
        write_ir(ref c, c.indent + "br i1 " + is_error + ", label %" + done + ", label %" + active + "\n");
        write_ir(ref c, "\n" + active + ":\n");
        write_ir(ref c, c.indent + payload + " = extractvalue " + storage + " " + value + ", 2\n");
        emit_native_value_check(ref c, payload, get_inner_fallible_type(ref c, repr), pos);
        write_ir(ref c, c.indent + "br label %" + done + "\n");
        write_ir(ref c, "\n" + done + ":\n");
        return;
    }

    let found_union = get_union_type(ref c, repr);
    if (found_union is !null) {
        let union: UnionInfo = found_union;
        let tag = next_reg(ref c);
        let valid = next_reg(ref c);
        let checked = next_label(ref c);
        let failed = next_label(ref c);
        write_ir(ref c, c.indent + tag + " = extractvalue " + storage + " " + value + ", 0\n");
        write_ir(ref c, c.indent + valid + " = icmp ult i32 " + tag + ", " + union.members.length() + "\n");
        write_ir(ref c, c.indent + "br i1 " + valid + ", label %" + checked + ", label %" + failed + "\n");
        write_ir(ref c, "\n" + failed + ":\n");
        emit_runtime_error(ref c, pos, "Invalid native union tag");
        write_ir(ref c, "\n" + checked + ":\n");

        let slot = next_reg(ref c);
        write_ir(ref c, c.indent + slot + " = alloca " + storage + "\n");
        write_ir(ref c, c.indent + "store " + storage + " " + value + ", " + storage + "* " + slot + "\n");
        let done = next_label(ref c);
        let i = 0;
        while (i < union.members.length()) {
            let member = union.members[i];
            if (needs_native_check(ref c, member)) {
                let active = next_label(ref c);
                let next = next_label(ref c);
                let matches = next_reg(ref c);
                write_ir(ref c, c.indent + matches + " = icmp eq i32 " + tag + ", " + i + "\n");
                write_ir(ref c, c.indent + "br i1 " + matches + ", label %" + active + ", label %" + next + "\n");
                write_ir(ref c, "\n" + active + ":\n");
                let address = emit_union_payload(ref c, slot, type_id, member);
                let payload = next_reg(ref c);
                let member_type = get_llvm_type_str(ref c, member);
                write_ir(ref c, c.indent + payload + " = load " + member_type + ", " + member_type + "* " + address + "\n");
                emit_native_value_check(ref c, payload, member, pos);
                write_ir(ref c, c.indent + "br label %" + done + "\n");
                write_ir(ref c, "\n" + next + ":\n");
            }
            i++;
        }
        write_ir(ref c, c.indent + "br label %" + done + "\n");
        write_ir(ref c, "\n" + done + ":\n");
        return;
    }

    let array = c.array_info_map.lookup(repr);
    if (array is !null && array.size >= 0) {
        emit_native_array_check(ref c, value, type_id, array, pos);
        return;
    }
    let i = 0;
    while (info is !null && i < info.fields.length()) {
        let field: FieldInfo = info.fields[i];
        if (needs_native_check(ref c, field.type)) {
            let payload = next_reg(ref c);
            write_ir(ref c, c.indent + payload + " = extractvalue " + storage + " " + value + ", " + field.offset + "\n");
            emit_native_value_check(ref c, payload, field.type, pos);
        }
        i++;
    }
}

func emit_native_condition(ref c: Compiler, valid: String, pos: Position, message: String) -> Void {
    let good = next_label(ref c);
    let bad = next_label(ref c);
    write_ir(ref c, c.indent + "br i1 " + valid + ", label %" + good + ", label %" + bad + "\n\n" + bad + ":\n");
    emit_runtime_error(ref c, pos, message);
    write_ir(ref c, "\n" + good + ":\n");
}

func emit_raw_value_load(ref c: Compiler, address: String, type_id: Int, pos: Position) -> String {
// a raw pointer proves neither initialization nor the payload's source-language invariants.
    let storage = get_llvm_type_str(ref c, type_id);
    let value = next_reg(ref c);
    if (get_repr_type(ref c, type_id) == TYPE_BOOL) {
        // loading i1 first would discard the bits needed to detect a malformed byte.
        let bytes = next_reg(ref c);
        let raw = next_reg(ref c);
        let valid = next_reg(ref c);
        write_ir(ref c, c.indent + bytes + " = bitcast " + storage + "* " + address + " to i8*\n");
        write_ir(ref c, c.indent + raw + " = load i8, i8* " + bytes + "\n");
        write_ir(ref c, c.indent + valid + " = icmp ule i8 " + raw + ", 1\n");
        emit_native_condition(ref c, valid, pos, "Invalid native Bool value");
        write_ir(ref c, c.indent + value + " = trunc i8 " + raw + " to i1\n");
    } else {
        emit_raw_bool_check(ref c, address, type_id, pos);
        write_ir(ref c, c.indent + value + " = load " + storage + ", " + storage + "* " + address + "\n");
        emit_native_value_check(ref c, value, type_id, pos);
    }
    return value;
}

func emit_raw_bool_check(ref c: Compiler, address: String, type_id: Int, pos: Position) -> Void {
// inspect original storage, a typed load can already discard invalid bool bits
    if (!needs_raw_bool_check(ref c, type_id)) { return; }
    let repr = get_repr_type(ref c, type_id);
    let storage = get_llvm_type_str(ref c, type_id);
    if (repr == TYPE_BOOL) {
        emit_raw_value_load(ref c, address, type_id, pos);
        return;
    }
    if (is_fallible_type(ref c, repr)) {
        let flag = next_reg(ref c);
        write_ir(ref c, c.indent + flag + " = getelementptr inbounds " + storage + ", " + storage + "* " + address + ", i32 0, i32 0\n");
        let failed = emit_raw_value_load(ref c, flag, TYPE_BOOL, pos);
        let inner = get_inner_fallible_type(ref c, repr);
        if (needs_raw_bool_check(ref c, inner)) {
            let active = next_label(ref c);
            let done = next_label(ref c);
            write_ir(ref c, c.indent + "br i1 " + failed + ", label %" + done + ", label %" + active + "\n\n" + active + ":\n");
            let payload = next_reg(ref c);
            write_ir(ref c, c.indent + payload + " = getelementptr inbounds " + storage + ", " + storage + "* " + address + ", i32 0, i32 2\n");
            emit_raw_bool_check(ref c, payload, inner, pos);
            write_ir(ref c, c.indent + "br label %" + done + "\n\n" + done + ":\n");
        }
        return;
    }
    let found_union = get_union_type(ref c, repr);
    if (found_union is !null) {
        let union: UnionInfo = found_union;
        let tag_addr = next_reg(ref c);
        let tag = next_reg(ref c);
        write_ir(ref c, c.indent + tag_addr + " = getelementptr inbounds " + storage + ", " + storage + "* " + address + ", i32 0, i32 0\n");
        write_ir(ref c, c.indent + tag + " = load i32, i32* " + tag_addr + "\n");
        let i = 0;
        while (i < union.members.length()) {
            let member = union.members[i];
            if (needs_raw_bool_check(ref c, member)) {
                let matches = next_reg(ref c);
                let active = next_label(ref c);
                let done = next_label(ref c);
                write_ir(ref c, c.indent + matches + " = icmp eq i32 " + tag + ", " + i + "\n");
                write_ir(ref c, c.indent + "br i1 " + matches + ", label %" + active + ", label %" + done + "\n\n" + active + ":\n");
                let payload = emit_union_payload(ref c, address, type_id, member);
                emit_raw_bool_check(ref c, payload, member, pos);
                write_ir(ref c, c.indent + "br label %" + done + "\n\n" + done + ":\n");
            }
            i++;
        }
        return;
    }
    let array = c.array_info_map.lookup(repr);
    if (array is !null && array.size >= 0) {
        let size_type = get_llvm_type_str(ref c, TYPE_INTSIZE);
        let slot = next_reg(ref c);
        write_ir(ref c, c.indent + slot + " = alloca " + size_type + "\n");
        write_ir(ref c, c.indent + "store " + size_type + " 0, " + size_type + "* " + slot + "\n");
        let cond = next_label(ref c);
        let body = next_label(ref c);
        let done = next_label(ref c);
        write_ir(ref c, c.indent + "br label %" + cond + "\n\n" + cond + ":\n");
        let index = next_reg(ref c);
        let more = next_reg(ref c);
        write_ir(ref c, c.indent + index + " = load " + size_type + ", " + size_type + "* " + slot + "\n");
        write_ir(ref c, c.indent + more + " = icmp ult " + size_type + " " + index + ", " + array.size + "\n");
        write_ir(ref c, c.indent + "br i1 " + more + ", label %" + body + ", label %" + done + "\n\n" + body + ":\n");
        let element = next_reg(ref c);
        write_ir(ref c, c.indent + element + " = getelementptr inbounds " + storage + ", " + storage + "* " + address + ", i32 0, " + size_type + " " + index + "\n");
        emit_raw_bool_check(ref c, element, array.base_type, pos);
        let next = next_reg(ref c);
        write_ir(ref c, c.indent + next + " = add " + size_type + " " + index + ", 1\n");
        write_ir(ref c, c.indent + "store " + size_type + " " + next + ", " + size_type + "* " + slot + "\n");
        write_ir(ref c, c.indent + "br label %" + cond + "\n\n" + done + ":\n");
        return;
    }
    let info = c.struct_id_map.lookup(repr);
    let i = 0;
    while (info is !null && i < info.fields.length()) {
        let field: FieldInfo = info.fields[i];
        if (needs_raw_bool_check(ref c, field.type)) {
            let payload = next_reg(ref c);
            write_ir(ref c, c.indent + payload + " = getelementptr inbounds " + storage + ", " + storage + "* " + address + ", i32 0, i32 " + field.offset + "\n");
            emit_raw_bool_check(ref c, payload, field.type, pos);
        }
        i++;
    }
}

func emit_native_array_check(ref c: Compiler, value: String, type_id: Int, array: ArrayInfo, pos: Position) -> Void {
// a native array check stays a loop, large fixed arrays should not expand compiler output
    let storage = get_llvm_type_str(ref c, type_id);
    let element_type = get_llvm_type_str(ref c, array.base_type);
    let slot = next_reg(ref c);
    let index_slot = next_reg(ref c);
    let size_type = get_size_llvm_type();
    write_ir(ref c, c.indent + slot + " = alloca " + storage + "\n");
    write_ir(ref c, c.indent + "store " + storage + " " + value + ", " + storage + "* " + slot + "\n");
    write_ir(ref c, c.indent + index_slot + " = alloca " + size_type + "\n");
    write_ir(ref c, c.indent + "store " + size_type + " 0, " + size_type + "* " + index_slot + "\n");
    let cond = next_label(ref c);
    let body = next_label(ref c);
    let done = next_label(ref c);
    write_ir(ref c, c.indent + "br label %" + cond + "\n\n" + cond + ":\n");
    let index = next_reg(ref c);
    let more = next_reg(ref c);
    write_ir(ref c, c.indent + index + " = load " + size_type + ", " + size_type + "* " + index_slot + "\n");
    write_ir(ref c, c.indent + more + " = icmp ult " + size_type + " " + index + ", " + array.size + "\n");
    write_ir(ref c, c.indent + "br i1 " + more + ", label %" + body + ", label %" + done + "\n\n" + body + ":\n");
    let address = next_reg(ref c);
    let payload = next_reg(ref c);
    write_ir(ref c, c.indent + address + " = getelementptr inbounds " + storage + ", " + storage + "* " + slot + ", i32 0, " + size_type + " " + index + "\n");
    write_ir(ref c, c.indent + payload + " = load " + element_type + ", " + element_type + "* " + address + "\n");
    emit_native_value_check(ref c, payload, array.base_type, pos);
    let next = next_reg(ref c);
    write_ir(ref c, c.indent + next + " = add " + size_type + " " + index + ", 1\n");
    write_ir(ref c, c.indent + "store " + size_type + " " + next + ", " + size_type + "* " + index_slot + "\n");
    write_ir(ref c, c.indent + "br label %" + cond + "\n\n" + done + ":\n");
}
