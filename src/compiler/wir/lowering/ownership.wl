// compiler/wir/lowering/ownership.wl

import * from "../model.wl"
import * from "../builder.wl"
import * from "state.wl"
import * from "../../context.wl"

func wir_value_needs_drop(ref source: Compiler, source_type: Int) -> Bool {
    let repr: Int = get_repr_type(ref source, source_type);
    if (repr == TYPE_GENERIC_FUNCTION) { return false; }
    if (source.func_ret_map is !null && has_symbol(source.func_ret_map.lookup("" + repr))) { return false; }
    return needs_drop(ref source, source_type);
}

func wir_owned_value_index(state: WirFunctionLowering, value: WirValueID) -> Int {
    let i: Int = state.owned_values.length() - 1;
    while (i >= 0) {
        if (state.owned_values[i].value == value) { return i; }
        i--;
    }
    return -1;
}

func wir_track_owned(ref state: WirFunctionLowering, value: WirValueID, source_type: Int) -> Void {
    if (value == NO_WIR_VALUE || wir_owned_value_index(state, value) >= 0) { return; }
    state.owned_values.append(WirOwnedValue(value=value, source_type=source_type));
}

func wir_take_owned(ref state: WirFunctionLowering, value: WirValueID) -> Bool {
    let index: Int = wir_owned_value_index(state, value);
    if (index < 0) { return false; }
    let values: Vector(WirOwnedValue) = [];
    let i: Int = 0;
    while (i < state.owned_values.length()) {
        if (i != index) { values.append(state.owned_values[i]); }
        i++;
    }
    state.owned_values = values;
    return true;
}

func wir_arc_pointer(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, value: WirValueID, source_type: Int) -> WirValueID {
    let repr: Int = get_repr_type(ref source, source_type);
    let info: StructInfo = StructInfo();
    if (source.struct_id_map is !null) { info = source.struct_id_map.lookup("" + repr); }
    if (has_struct(info) && info.is_interface) {
        return wir_field(ref program, state.block, value, 0, "", no_wir_location());
    }
    let array: ArrayInfo = ArrayInfo();
    if (source.array_info_map is !null) { array = source.array_info_map.lookup("" + repr); }
    if (has_array_info(array) && array.size == -1) {
        return wir_field(ref program, state.block, value, 2, "", no_wir_location());
    }
    let type_id: WirTypeID = wir_value_type(program, value);
    if (program.arena.types[wir_id_index(UInt32(type_id))].kind == WirTypeKind.Pointer) { return value; }
    state.errors.append("ARC value has no payload pointer in WIR lowering");
    return NO_WIR_VALUE;
}

func wir_emit_ownership_value(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, value: WirValueID, source_type: Int, retain: Bool) -> Void {
    if (!wir_value_needs_drop(ref source, source_type)) { return; }
    if (is_fallible_type(ref source, source_type)) {
        state.errors.append("fallible ownership is not lowered to WIR yet");
        return;
    }

    let repr: Int = get_repr_type(ref source, source_type);
    let array: ArrayInfo = ArrayInfo();
    if (source.array_info_map is !null) { array = source.array_info_map.lookup("" + repr); }
    if (has_array_info(array) && array.size >= 0) {
        let index_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
        let i: Int = 0;
        while (i < array.size) {
            let index: WirValueID = wir_const_int(ref program, index_type, UInt128(UIntSize(i)));
            let element: WirValueID = wir_index(ref program, state.block, value, index, "", no_wir_location());
            wir_emit_ownership_value(ref state, ref source, ref program, element, array.base_type, retain);
            i++;
        }
        return;
    }

    let struct_info: StructInfo = StructInfo();
    if (source.struct_id_map is !null) { struct_info = source.struct_id_map.lookup("" + repr); }
    if (has_struct(struct_info) && !struct_info.is_class && !struct_info.is_interface && !struct_info.is_enum) {
        let i: Int = 0;
        while (struct_info.fields is !null && i < struct_info.fields.length()) {
            let field: FieldInfo = struct_info.fields[i];
            if (wir_value_needs_drop(ref source, field.type)) {
                let field_value: WirValueID = wir_field(ref program, state.block, value, field.offset, "", no_wir_location());
                wir_emit_ownership_value(ref state, ref source, ref program, field_value, field.type, retain);
            }
            i++;
        }
        return;
    }

    if (!is_ref_type(ref source, source_type)) { return; }
    let pointer: WirValueID = wir_arc_pointer(ref state, ref source, ref program, value, source_type);
    if (pointer == NO_WIR_VALUE) { return; }
    if (retain) { wir_retain(ref program, state.block, pointer, no_wir_location()); }
    else { wir_release(ref program, state.block, pointer, no_wir_location()); }
}

func wir_emit_ownership_slot(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, address: WirValueID, source_type: Int, retain: Bool) -> Void {
    if (!wir_value_needs_drop(ref source, source_type)) { return; }
    let value: WirValueID = wir_load(ref program, state.block, address, "", no_wir_location());
    wir_emit_ownership_value(ref state, ref source, ref program, value, source_type, retain);
}

func wir_move_or_retain(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, value: WirExpr) -> Void {
    if (!wir_value_needs_drop(ref source, value.source_type)) { return; }
    if (!wir_take_owned(ref state, value.value)) {
        wir_emit_ownership_value(ref state, ref source, ref program, value.value, value.source_type, true);
    }
}

func wir_cleanup_bindings(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, first: Int) -> Void {
    let i: Int = state.bindings.length() - 1;
    while (i >= first) {
        let binding: WirBinding = state.bindings[i];
        if (binding.owns_value) {
            wir_emit_ownership_slot(ref state, ref source, ref program, binding.address, binding.source_type, false);
        }
        i--;
    }
}

func wir_cleanup_temporaries(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, first: Int) -> Void {
    let i: Int = state.owned_values.length() - 1;
    while (i >= first) {
        let owned: WirOwnedValue = state.owned_values[i];
        wir_emit_ownership_value(ref state, ref source, ref program, owned.value, owned.source_type, false);
        i--;
    }
    let values: Vector(WirOwnedValue) = [];
    i = 0;
    while (i < first && i < state.owned_values.length()) {
        values.append(state.owned_values[i]);
        i++;
    }
    state.owned_values = values;
}
