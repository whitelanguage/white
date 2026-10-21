// src/compiler/wir/lowering/unions.wl
import * from "../model.wl"
import * from "../builder.wl"
import * from "state.wl"
import * from "types.wl"
import * from "../../context.wl"


func wir_union_payload(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, slot: WirValueID, member: Int) -> WirValueID {
// the integer carrier supplies alignment, access uses the active member's type
    let payload: WirValueID = wir_field_address(ref program, state.block, slot, 1, "", no_wir_location());
    let member_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, member);

    return wir_cast(ref program, state.block, payload, wir_pointer_type(ref program, member_type), "", no_wir_location());
}

func wir_union_store_member(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, slot: WirValueID, union_type: Int, member: Int, value: WirValueID) -> Void {
    if (member != TYPE_NULL) {
        let payload: WirValueID = wir_union_payload(ref state, ref types, ref source, ref program, slot, member);
        wir_store(ref program, state.block, value, payload, no_wir_location());
    }

    let tag_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let tag: WirValueID = wir_const_int(ref program, tag_type, UInt128(UInt32(union_member_index(ref source, union_type, member))));
    let tag_slot: WirValueID = wir_field_address(ref program, state.block, slot, 0, "", no_wir_location());
    wir_store(ref program, state.block, tag, tag_slot, no_wir_location());
}

func wir_pack_union(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, target: Int) -> WirValueID {
// temporary storage is in entry, even when construction happens inside a loop
    let target_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, target);
    let slot: WirValueID = wir_stack_alloc(ref program, state.entry, target_wir, "union.value", no_wir_location());
    wir_store(ref program, state.block, wir_const_zero(ref program, target_wir), slot, no_wir_location());

    let source_union: UnionInfo = get_union_type(ref source, value.source_type);
    if (source_union.members is null) {
        wir_union_store_member(ref state, ref types, ref source, ref program, slot, target, value.source_type, value.value);
        return wir_load(ref program, state.block, slot, "", no_wir_location());
    }

    // widening must remap tags, adding a member can change the canonical order.
    let source_wir: WirTypeID = wir_value_type(ref program, value.value);
    let source_slot: WirValueID = wir_stack_alloc(ref program, state.entry, source_wir, "union.source", no_wir_location());
    wir_store(ref program, state.block, value.value, source_slot, no_wir_location());
    let tag: WirValueID = wir_field(ref program, state.block, value.value, 0, "", no_wir_location());
    let tag_type: WirTypeID = wir_value_type(ref program, tag);
    let done: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "union.end."), []);

    let i: Int = 0;
    while (i < source_union.members.length()) {
        let member: Int = source_union.members[i];
        let copy: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "union.member."), []);
        let next: WirBlockID = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "union.next."), []);
        let matches: WirValueID = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, tag,
            wir_const_int(ref program, tag_type, UInt128(UInt32(i))), "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [matches], [wir_edge(copy, []), wir_edge(next, [])], no_wir_location());

        state.block = copy;
        let payload: WirValueID = NO_WIR_VALUE;
        if (member != TYPE_NULL) {
            let address: WirValueID = wir_union_payload(ref state, ref types, ref source, ref program, source_slot, member);
            payload = wir_load(ref program, state.block, address, "", no_wir_location());
        }
        wir_union_store_member(ref state, ref types, ref source, ref program, slot, target, member, payload);
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [])], no_wir_location());

        state.block = next;
        i++;
    }
    wir_append(ref program, state.block, WirOpcode.Unreachable, program.void_type, [], [], no_wir_location());

    state.block = done;
    return wir_load(ref program, state.block, slot, "", no_wir_location());
}
