// src/compiler/wir/lowering/native_values.wl
import * from "../model.wl"
import * from "../builder.wl"
import * from "state.wl"
import * from "types.wl"
import * from "../../context.wl"
import wir_union_payload from "unions.wl"
import wir_guard_runtime from "functions.wl"


func wir_native_value_check(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirValueID, source_type: Int) -> Void {
// native values are checked before their active payload is retained or exposed to source code
    if (!needs_native_check(ref source, source_type)) { return; }
    let repr = get_repr_type(ref source, source_type);
    let info = source.struct_id_map.lookup(repr);
    if (is_ref_type(ref source, source_type)) {
        if (info is !null && info.is_interface) {
            let object = wir_field(ref program, state.block, value, 0, "", no_wir_location());
            let table = wir_field(ref program, state.block, value, 1, "", no_wir_location());
            wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [object], [], no_wir_location());
            wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [table], [], no_wir_location());
        } else {
            wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [value], [], no_wir_location());
        }
        return;
    }

    if (is_fallible_type(ref source, repr)) {
        let is_error = wir_field(ref program, state.block, value, 0, "", no_wir_location());
        let active = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "native.payload."), []);
        let done = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "native.end."), []);
        wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [is_error], [wir_edge(done, []), wir_edge(active, [])], no_wir_location());
        state.block = active;
        let payload = wir_field(ref program, state.block, value, 2, "", no_wir_location());
        wir_native_value_check(ref state, ref types, ref source, ref program, payload, get_inner_fallible_type(ref source, repr));
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [])], no_wir_location());
        state.block = done;
        return;
    }

    let found_union = get_union_type(ref source, repr);
    if (found_union is !null) {
        let union: UnionInfo = found_union;
        let tag = wir_field(ref program, state.block, value, 0, "", no_wir_location());
        let tag_type = wir_value_type(ref program, tag);
        let valid = wir_binary(ref program, state.block, WirOpcode.UnsignedLess, program.bool_type, tag,
            wir_const_int(ref program, tag_type, UInt128(UInt32(union.members.length()))), "", no_wir_location());
        wir_guard_runtime(ref state, ref program, valid, "__wl_fail_native_tag");
        let slot = wir_stack_alloc(ref program, state.entry, wir_value_type(ref program, value), "native.union", no_wir_location());
        wir_store(ref program, state.block, value, slot, no_wir_location());
        let done = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "native.union.end."), []);

        let i = 0;
        while (i < union.members.length()) {
            let member = union.members[i];
            if (needs_native_check(ref source, member)) {
                let active = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "native.union.member."), []);
                let next = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "native.union.next."), []);
                let matches = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, tag,
                    wir_const_int(ref program, tag_type, UInt128(UInt32(i))), "", no_wir_location());
                wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [matches], [wir_edge(active, []), wir_edge(next, [])], no_wir_location());
                state.block = active;
                let payload = wir_union_payload(ref state, ref types, ref source, ref program, slot, member);
                let loaded = wir_load(ref program, state.block, payload, "", no_wir_location());
                wir_native_value_check(ref state, ref types, ref source, ref program, loaded, member);
                wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [])], no_wir_location());
                state.block = next;
            }
            i++;
        }
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [])], no_wir_location());
        state.block = done;
        return;
    }

    let array = source.array_info_map.lookup(repr);
    if (array is !null && array.size >= 0) {
        wir_native_array_check(ref state, ref types, ref source, ref program, value, array);
        return;
    }
    let i = 0;
    while (info is !null && i < info.fields.length()) {
        let field: FieldInfo = info.fields[i];
        if (needs_native_check(ref source, field.type)) {
            let payload = wir_field(ref program, state.block, value, field.offset, "", no_wir_location());
            wir_native_value_check(ref state, ref types, ref source, ref program, payload, field.type);
        }
        i++;
    }
}

func wir_native_array_check(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirValueID, array: ArrayInfo) -> Void {
// only one element check is emitted, entry storage is reused on each iteration
    let storage = wir_value_type(ref program, value);
    let slot = wir_stack_alloc(ref program, state.entry, storage, "native.array", no_wir_location());
    wir_store(ref program, state.block, value, slot, no_wir_location());
    let index_type = wir_unsigned_int_type(ref program, program.pointer_bits);
    let cond = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "native.array.cond."), [wir_param("index", index_type)]);
    let body = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "native.array.body."), []);
    let done = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "native.array.end."), []);
    let zero = wir_const_int(ref program, index_type, UInt128(0U));
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(cond, [zero])], no_wir_location());
    state.block = cond;
    let index = program.arena.blocks[wir_id_index(UInt32(cond))].parameters[0];
    let more = wir_binary(ref program, cond, WirOpcode.UnsignedLess, program.bool_type, index,
        wir_const_int(ref program, index_type, UInt128(UIntSize(array.size))), "", no_wir_location());
    wir_append(ref program, cond, WirOpcode.Branch, program.void_type, [more], [wir_edge(body, []), wir_edge(done, [])], no_wir_location());
    state.block = body;
    let address = wir_index_address(ref program, body, slot, index, "", no_wir_location());
    let payload = wir_load(ref program, body, address, "", no_wir_location());
    wir_native_value_check(ref state, ref types, ref source, ref program, payload, array.base_type);
    let next = wir_binary(ref program, state.block, WirOpcode.Add, index_type, index,
        wir_const_int(ref program, index_type, UInt128(1U)), "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(cond, [next])], no_wir_location());
    state.block = done;
}
