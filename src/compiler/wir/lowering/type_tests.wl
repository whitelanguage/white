// src/compiler/wir/lowering/type_tests.wl
import * from "../model.wl"
import * from "../builder.wl"
import WIR_ARC_TYPE_OFFSET from "../runtime.wl"
import * from "state.wl"
import * from "types.wl"
import wir_find_function from "declarations.wl"
import * from "unions.wl"
import * from "../../context.wl"
import * from "../../type_tests.wl"


func wir_instance_test_func(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, target: Int) -> WirFuncID {
// the body waits until generic instantiation has discovered every concrete subclass
    let name = "__wl_is_instance_" + target;
    let id = wir_find_function(program, name);
    if (id != NO_WIR_FUNC) { return id; }
    let raw = wir_opaque_pointer(ref types, ref program);
    source.erased_checks.put("instance." + target, StringConstant(id=target, value=name));
    return wir_add_function(ref program, name, [wir_param("object", raw)], program.bool_type, false, WirLinkage.Internal, WirABI.White);
}

func wir_finish_type_tests(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule) -> Void {
    let slot = 0;
    while (slot < source.erased_checks.capacity) {
        if (source.erased_checks.hashes[slot] < 2) { slot++; continue; }
        let check = source.erased_checks.values[slot];
        if (!check.value.starts_with("__wl_is_instance_")) { slot++; continue; }
        let id = wir_find_function(program, check.value);
        let function = program.arena.functions[wir_id_index(UInt32(id))];
        if (function.blocks.length() != 0) { slot++; continue; }
        let object = function.parameters[0];
        let raw = wir_value_type(ref program, object);
        let entry = wir_add_block(ref program, id, "entry", []);
        let inspect = wir_add_block(ref program, id, "inspect", []);
        let absent = wir_add_block(ref program, id, "absent", []);
        let is_null = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, object, wir_null(ref program, raw), "", no_wir_location());
        wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [is_null], [wir_edge(absent, []), wir_edge(inspect, [])], no_wir_location());
        wir_return(ref program, absent, wir_const_bool(ref program, false), no_wir_location());

        let tag_type = wir_unsigned_int_type(ref program, 32);
        let address = wir_pointer_offset(ref program, inspect, object, WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, tag_type));
        let tag = wir_load(ref program, inspect, address, "", no_wir_location());
        let result = wir_const_bool(ref program, false);
        let candidate = 100;
        while (candidate < source.type_counter) {
            let info = source.struct_id_map.lookup(candidate);
            if ((info is !null) && info.is_class && is_subclass(ref source, candidate, check.id)) {
                let expected = wir_const_int(ref program, tag_type, UInt128(UInt32(candidate)));
                let matches = wir_binary(ref program, inspect, WirOpcode.Equal, program.bool_type, tag, expected, "", no_wir_location());
                result = wir_binary(ref program, inspect, WirOpcode.BitOr, program.bool_type, result, matches, "", no_wir_location());
            }
            candidate++;
        }
        wir_return(ref program, inspect, result, no_wir_location());
        slot++;
    }
}

func wir_class_test(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, target: Int, instance: Bool) -> WirValueID {
    let object = value.value;
    let info = source.struct_id_map.lookup(get_repr_type(ref source, value.source_type));
    if ((info is !null) && info.is_interface) {
        object = wir_field(ref program, state.block, object, 0, "", no_wir_location());
    }
    let raw = wir_opaque_pointer(ref types, ref program);
    object = wir_cast(ref program, state.block, object, raw, "", no_wir_location());
    if instance {
        let helper = wir_instance_test_func(ref types, ref source, ref program, target);
        return wir_call(ref program, state.block, wir_function_value(ref program, helper), [object], "", no_wir_location());
    }

    let inspect = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "type.inspect."), []);
    let done = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "type.end."), [wir_param("matches", program.bool_type)]);
    let absent = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, object, wir_null(ref program, raw), "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [absent], [wir_edge(done, [wir_const_bool(ref program, false)]), wir_edge(inspect, [])], no_wir_location());
    state.block = inspect;
    let tag_type = wir_unsigned_int_type(ref program, 32);
    let address = wir_pointer_offset(ref program, state.block, object, WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, tag_type));
    let tag = wir_load(ref program, state.block, address, "", no_wir_location());
    let matches = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, tag, wir_const_int(ref program, tag_type, UInt128(UInt32(target))), "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [matches])], no_wir_location());
    state.block = done;
    return program.arena.blocks[wir_id_index(UInt32(done))].parameters[0];
}

func wir_type_test(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, value: WirExpr, target: Int, instance: Bool) -> WirValueID {
    let found = get_union_type(ref source, value.source_type);
    if (found is null) {
        if (!instance && get_named_type(ref source, value.source_type) is !null) {
            return wir_const_bool(ref program, value.source_type == target);
        }
        if (type_test_class(ref source, value.source_type) || type_test_header(value.source_type)) {
            return wir_class_test(ref state, ref types, ref source, ref program, value, target, instance);
        }
        return wir_const_bool(ref program, value.source_type == target);
    }
    let union: UnionInfo = found;
    let done = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "test.end."), [wir_param("matches", program.bool_type)]);
    let tag = wir_field(ref program, state.block, value.value, 0, "", no_wir_location());
    let tag_type = wir_value_type(ref program, tag);
    let slot = wir_stack_alloc(ref program, state.entry, wir_value_type(ref program, value.value), "test.union", no_wir_location());
    wir_store(ref program, state.block, value.value, slot, no_wir_location());
    let i = 0;
    while (i < union.members.length()) {
        let member = union.members[i];
        let test = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "test.member."), []);
        let next = wir_add_block(ref program, state.function, wir_next_block_name(ref state, "test.next."), []);
        let active = wir_binary(ref program, state.block, WirOpcode.Equal, program.bool_type, tag, wir_const_int(ref program, tag_type, UInt128(UInt32(i))), "", no_wir_location());
        wir_append(ref program, state.block, WirOpcode.Branch, program.void_type, [active], [wir_edge(test, []), wir_edge(next, [])], no_wir_location());
        state.block = test;
        let matches = wir_const_bool(ref program, member == target);
        if ((instance || get_named_type(ref source, member) is null) && (type_test_class(ref source, member) || type_test_header(member))) {
            let address = wir_union_payload(ref state, ref types, ref source, ref program, slot, member);
            let object = wir_load(ref program, state.block, address, "", no_wir_location());
            matches = wir_class_test(ref state, ref types, ref source, ref program, WirExpr(value=object, source_type=member), target, instance);
        }
        wir_append(ref program, state.block, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [matches])], no_wir_location());
        state.block = next;
        i++;
    }
    wir_append(ref program, state.block, WirOpcode.Unreachable, program.void_type, [], [], no_wir_location());
    state.block = done;
    return program.arena.blocks[wir_id_index(UInt32(done))].parameters[0];
}
