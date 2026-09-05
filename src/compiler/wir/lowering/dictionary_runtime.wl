// compiler/wir/lowering/dictionary_runtime.wl

import * from "../model.wl"
import * from "../builder.wl"
import * from "types.wl"
import * from "declarations.wl"
import * from "../../context.wl"

func wir_dict_mix_function(ref program: WirModule) -> WirFuncID {
    let name: String = "__wl_dict_hash_bits";
    let existing: WirFuncID = wir_find_function(program, name);
    if (existing != NO_WIR_FUNC) { return existing; }

    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("tag", i64_type), wir_param("low", i64_type), wir_param("high", i64_type)], i32_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let adjust: WirBlockID = wir_add_block(ref program, function_id, "adjust", []);
    let keep: WirBlockID = wir_add_block(ref program, function_id, "keep", []);
    let done: WirBlockID = wir_add_block(ref program, function_id, "done", [wir_param("value", i32_type)]);

    let mixed0: WirValueID = wir_binary(ref program, entry, WirOpcode.BitXor, i64_type, function.parameters[0], function.parameters[1], "mixed.0", no_wir_location());
    let mixed1: WirValueID = wir_binary(ref program, entry, WirOpcode.BitXor, i64_type, mixed0, function.parameters[2], "mixed.1", no_wir_location());
    let shifted0: WirValueID = wir_binary(ref program, entry, WirOpcode.UnsignedShiftRight, i64_type, mixed1, wir_const_int(ref program, i64_type, UInt128(30U)), "shifted.0", no_wir_location());
    let mixed2: WirValueID = wir_binary(ref program, entry, WirOpcode.BitXor, i64_type, mixed1, shifted0, "mixed.2", no_wir_location());
    let mixed3: WirValueID = wir_binary(ref program, entry, WirOpcode.Multiply, i64_type, mixed2, wir_const_int(ref program, i64_type, UInt128(13787848793156543929UL)), "mixed.3", no_wir_location());
    let shifted1: WirValueID = wir_binary(ref program, entry, WirOpcode.UnsignedShiftRight, i64_type, mixed3, wir_const_int(ref program, i64_type, UInt128(27U)), "shifted.1", no_wir_location());
    let mixed4: WirValueID = wir_binary(ref program, entry, WirOpcode.BitXor, i64_type, mixed3, shifted1, "mixed.4", no_wir_location());
    let mixed5: WirValueID = wir_binary(ref program, entry, WirOpcode.Multiply, i64_type, mixed4, wir_const_int(ref program, i64_type, UInt128(10723151780598845931UL)), "mixed.5", no_wir_location());
    let shifted2: WirValueID = wir_binary(ref program, entry, WirOpcode.UnsignedShiftRight, i64_type, mixed5, wir_const_int(ref program, i64_type, UInt128(31U)), "shifted.2", no_wir_location());
    let mixed6: WirValueID = wir_binary(ref program, entry, WirOpcode.BitXor, i64_type, mixed5, shifted2, "mixed.6", no_wir_location());
    let raw: WirValueID = wir_cast(ref program, entry, mixed6, i32_type, "raw", no_wir_location());
    let positive: WirValueID = wir_binary(ref program, entry, WirOpcode.BitAnd, i32_type, raw, wir_const_int(ref program, i32_type, UInt128(2147483647U)), "positive", no_wir_location());
    let small: WirValueID = wir_binary(ref program, entry, WirOpcode.SignedLess, program.bool_type, positive, wir_const_int(ref program, i32_type, UInt128(2U)), "small", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [small], [wir_edge(adjust, []), wir_edge(keep, [])], no_wir_location());

    let adjusted: WirValueID = wir_binary(ref program, adjust, WirOpcode.Add, i32_type, positive, wir_const_int(ref program, i32_type, UInt128(2U)), "adjusted", no_wir_location());
    wir_append(ref program, adjust, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [adjusted])], no_wir_location());
    wir_append(ref program, keep, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [positive])], no_wir_location());
    let done_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(done))];
    wir_return(ref program, done, done_block.parameters[0], no_wir_location());
    return function_id;
}

func wir_dict_variant_hash_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, variant_type: Int) -> WirFuncID {
    let name: String = "__wl_dict_key_hash";
    let existing: WirFuncID = wir_find_function(program, name);
    if (existing != NO_WIR_FUNC) { return existing; }

    let variant_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, variant_type);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let tag_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("key", variant_wir)], i32_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let key: WirValueID = function.parameters[0];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let read: WirBlockID = wir_add_block(ref program, function_id, "read", []);
    let check_float: WirBlockID = wir_add_block(ref program, function_id, "check.float", []);
    let check_class: WirBlockID = wir_add_block(ref program, function_id, "check.class", []);
    let string_key: WirBlockID = wir_add_block(ref program, function_id, "string", []);
    let float_key: WirBlockID = wir_add_block(ref program, function_id, "float", []);
    let float_zero: WirBlockID = wir_add_block(ref program, function_id, "float.zero", []);
    let float_bits: WirBlockID = wir_add_block(ref program, function_id, "float.bits", []);
    let float_done: WirBlockID = wir_add_block(ref program, function_id, "float.done", [wir_param("low", wir_signed_int_type(ref program, 64))]);
    let bits: WirBlockID = wir_add_block(ref program, function_id, "bits", []);
    let invalid: WirBlockID = wir_add_block(ref program, function_id, "invalid", []);

    let is_null: WirValueID = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, key, wir_null(ref program, variant_wir), "is.null", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [is_null], [wir_edge(invalid, []), wir_edge(read, [])], no_wir_location());

    let tag: WirValueID = wir_load(ref program, read, wir_field_address(ref program, read, key, 0, "", no_wir_location()), "tag", no_wir_location());
    let low: WirValueID = wir_load(ref program, read, wir_field_address(ref program, read, key, 1, "", no_wir_location()), "low", no_wir_location());
    let high: WirValueID = wir_load(ref program, read, wir_field_address(ref program, read, key, 2, "", no_wir_location()), "high", no_wir_location());
    let is_string: WirValueID = wir_binary(ref program, read, WirOpcode.Equal, program.bool_type, tag, wir_const_int(ref program, tag_type, UInt128(type_fingerprint(ref source, TYPE_STRING))), "is.string", no_wir_location());
    wir_append(ref program, read, WirOpcode.Branch, program.void_type, [is_string], [wir_edge(string_key, []), wir_edge(check_float, [])], no_wir_location());

    let is_float64: WirValueID = wir_binary(ref program, check_float, WirOpcode.Equal, program.bool_type, tag, wir_const_int(ref program, tag_type, UInt128(type_fingerprint(ref source, TYPE_FLOAT))), "is.float64", no_wir_location());
    let is_float32: WirValueID = wir_binary(ref program, check_float, WirOpcode.Equal, program.bool_type, tag, wir_const_int(ref program, tag_type, UInt128(type_fingerprint(ref source, TYPE_FLOAT32))), "is.float32", no_wir_location());
    let is_float: WirValueID = wir_binary(ref program, check_float, WirOpcode.BitOr, program.bool_type, is_float64, is_float32, "is.float", no_wir_location());
    wir_append(ref program, check_float, WirOpcode.Branch, program.void_type, [is_float], [wir_edge(float_key, []), wir_edge(check_class, [])], no_wir_location());

    let string_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_STRING);
    let string_value: WirValueID = wir_cast(ref program, string_key, low, string_type, "value", no_wir_location());
    let string_hash: WirFuncID = wir_dict_string_hash_function(ref types, ref source, ref program, TYPE_STRING);
    let string_result: WirValueID = wir_call(ref program, string_key, wir_function_value(program, string_hash), [string_value], "hash", no_wir_location());
    wir_return(ref program, string_key, string_result, no_wir_location());

    let float_type: WirTypeID = wir_float_type(ref program, 64);
    let float_value: WirValueID = wir_unary(ref program, float_key, WirOpcode.Bitcast, float_type, low, "value", no_wir_location());
    let is_zero: WirValueID = wir_binary(ref program, float_key, WirOpcode.Equal, program.bool_type, float_value, wir_const_float(ref program, float_type, 0.0), "is.zero", no_wir_location());
    wir_append(ref program, float_key, WirOpcode.Branch, program.void_type, [is_zero], [wir_edge(float_zero, []), wir_edge(float_bits, [])], no_wir_location());
    let zero_payload: WirValueID = wir_const_int(ref program, wir_signed_int_type(ref program, 64), UInt128(0U));
    wir_append(ref program, float_zero, WirOpcode.Jump, program.void_type, [], [wir_edge(float_done, [zero_payload])], no_wir_location());
    wir_append(ref program, float_bits, WirOpcode.Jump, program.void_type, [], [wir_edge(float_done, [low])], no_wir_location());
    let float_done_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(float_done))];
    let normalized: WirValueID = wir_cast(ref program, float_done, float_done_block.parameters[0], tag_type, "normalized", no_wir_location());
    let mix_float: WirFuncID = wir_dict_mix_function(ref program);
    let float_result: WirValueID = wir_call(ref program, float_done, wir_function_value(program, mix_float), [tag, normalized, wir_const_int(ref program, tag_type, UInt128(0U))], "hash", no_wir_location());
    wir_return(ref program, float_done, float_result, no_wir_location());

    let class_check: WirBlockID = check_class;
    let hash_interface: StructInfo = source.struct_table.lookup("hashing.Hash");
    let type_id: Int = 100;
    while (type_id < source.type_counter) {
        let info: StructInfo = source.struct_id_map.lookup("" + type_id);
        let hashable: Bool = has_struct(info) && info.is_class && has_struct(hash_interface) && implements_interface(ref source, type_id, hash_interface.type_id);
        if hashable {
            let class_key: WirBlockID = wir_add_block(ref program, function_id, "class." + type_id, []);
            let next: WirBlockID = wir_add_block(ref program, function_id, "check.class." + type_id, []);
            let matches: WirValueID = wir_binary(ref program, class_check, WirOpcode.Equal, program.bool_type, tag, wir_const_int(ref program, tag_type, UInt128(type_fingerprint(ref source, type_id))), "matches", no_wir_location());
            wir_append(ref program, class_check, WirOpcode.Branch, program.void_type, [matches], [wir_edge(class_key, []), wir_edge(next, [])], no_wir_location());

            let class_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, type_id);
            let class_value: WirValueID = wir_cast(ref program, class_key, low, class_type, "value", no_wir_location());
            let class_hash: WirFuncID = wir_dict_class_hash_function(ref types, ref source, ref program, type_id, info);
            if (class_hash != NO_WIR_FUNC) {
                let class_result: WirValueID = wir_call(ref program, class_key, wir_function_value(program, class_hash), [class_value], "hash", no_wir_location());
                wir_return(ref program, class_key, class_result, no_wir_location());
            } else {
                wir_append(ref program, class_key, WirOpcode.Jump, program.void_type, [], [wir_edge(bits, [])], no_wir_location());
            }
            class_check = next;
        }
        type_id++;
    }
    wir_append(ref program, class_check, WirOpcode.Jump, program.void_type, [], [wir_edge(bits, [])], no_wir_location());

    let low_bits: WirValueID = wir_cast(ref program, bits, low, tag_type, "low.bits", no_wir_location());
    let high_bits: WirValueID = wir_cast(ref program, bits, high, tag_type, "high.bits", no_wir_location());
    let mix: WirFuncID = wir_dict_mix_function(ref program);
    let result: WirValueID = wir_call(ref program, bits, wir_function_value(program, mix), [tag, low_bits, high_bits], "hash", no_wir_location());
    wir_return(ref program, bits, result, no_wir_location());
    wir_return(ref program, invalid, wir_const_int(ref program, i32_type, UInt128(0U)), no_wir_location());
    return function_id;
}

func wir_dict_variant_equal_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, variant_type: Int) -> WirFuncID {
    let name: String = "__wl_dict_keys_equal";
    let existing: WirFuncID = wir_find_function(program, name);
    if (existing != NO_WIR_FUNC) { return existing; }

    let variant_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, variant_type);
    let tag_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("left", variant_wir), wir_param("right", variant_wir)], program.bool_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let left: WirValueID = function.parameters[0];
    let right: WirValueID = function.parameters[1];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let null_check: WirBlockID = wir_add_block(ref program, function_id, "check.null", []);
    let read: WirBlockID = wir_add_block(ref program, function_id, "read", []);
    let dispatch: WirBlockID = wir_add_block(ref program, function_id, "dispatch", []);
    let check_float: WirBlockID = wir_add_block(ref program, function_id, "check.float", []);
    let check_class: WirBlockID = wir_add_block(ref program, function_id, "check.class", []);
    let string_key: WirBlockID = wir_add_block(ref program, function_id, "string", []);
    let float_key: WirBlockID = wir_add_block(ref program, function_id, "float", []);
    let bits: WirBlockID = wir_add_block(ref program, function_id, "bits", []);
    let equal: WirBlockID = wir_add_block(ref program, function_id, "equal", []);
    let different: WirBlockID = wir_add_block(ref program, function_id, "different", []);

    let same: WirValueID = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, left, right, "same", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [same], [wir_edge(equal, []), wir_edge(null_check, [])], no_wir_location());

    let left_null: WirValueID = wir_binary(ref program, null_check, WirOpcode.Equal, program.bool_type, left, wir_null(ref program, variant_wir), "left.null", no_wir_location());
    let right_null: WirValueID = wir_binary(ref program, null_check, WirOpcode.Equal, program.bool_type, right, wir_null(ref program, variant_wir), "right.null", no_wir_location());
    let has_null: WirValueID = wir_binary(ref program, null_check, WirOpcode.BitOr, program.bool_type, left_null, right_null, "has.null", no_wir_location());
    wir_append(ref program, null_check, WirOpcode.Branch, program.void_type, [has_null], [wir_edge(different, []), wir_edge(read, [])], no_wir_location());

    let left_tag: WirValueID = wir_load(ref program, read, wir_field_address(ref program, read, left, 0, "", no_wir_location()), "left.tag", no_wir_location());
    let right_tag: WirValueID = wir_load(ref program, read, wir_field_address(ref program, read, right, 0, "", no_wir_location()), "right.tag", no_wir_location());
    let same_tag: WirValueID = wir_binary(ref program, read, WirOpcode.Equal, program.bool_type, left_tag, right_tag, "same.tag", no_wir_location());
    wir_append(ref program, read, WirOpcode.Branch, program.void_type, [same_tag], [wir_edge(dispatch, []), wir_edge(different, [])], no_wir_location());

    let is_string: WirValueID = wir_binary(ref program, dispatch, WirOpcode.Equal, program.bool_type, left_tag, wir_const_int(ref program, tag_type, UInt128(type_fingerprint(ref source, TYPE_STRING))), "is.string", no_wir_location());
    wir_append(ref program, dispatch, WirOpcode.Branch, program.void_type, [is_string], [wir_edge(string_key, []), wir_edge(check_float, [])], no_wir_location());

    let is_float64: WirValueID = wir_binary(ref program, check_float, WirOpcode.Equal, program.bool_type, left_tag, wir_const_int(ref program, tag_type, UInt128(type_fingerprint(ref source, TYPE_FLOAT))), "is.float64", no_wir_location());
    let is_float32: WirValueID = wir_binary(ref program, check_float, WirOpcode.Equal, program.bool_type, left_tag, wir_const_int(ref program, tag_type, UInt128(type_fingerprint(ref source, TYPE_FLOAT32))), "is.float32", no_wir_location());
    let is_float: WirValueID = wir_binary(ref program, check_float, WirOpcode.BitOr, program.bool_type, is_float64, is_float32, "is.float", no_wir_location());
    wir_append(ref program, check_float, WirOpcode.Branch, program.void_type, [is_float], [wir_edge(float_key, []), wir_edge(check_class, [])], no_wir_location());

    let left_low: WirValueID = wir_load(ref program, string_key, wir_field_address(ref program, string_key, left, 1, "", no_wir_location()), "left.low", no_wir_location());
    let right_low: WirValueID = wir_load(ref program, string_key, wir_field_address(ref program, string_key, right, 1, "", no_wir_location()), "right.low", no_wir_location());
    let string_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, TYPE_STRING);
    let left_string: WirValueID = wir_cast(ref program, string_key, left_low, string_type, "left.value", no_wir_location());
    let right_string: WirValueID = wir_cast(ref program, string_key, right_low, string_type, "right.value", no_wir_location());
    let string_equal: WirFuncID = wir_dict_string_equal_function(ref types, ref source, ref program, TYPE_STRING);
    let string_result: WirValueID = wir_call(ref program, string_key, wir_function_value(program, string_equal), [left_string, right_string], "equal", no_wir_location());
    wir_return(ref program, string_key, string_result, no_wir_location());

    let float_left_low: WirValueID = wir_load(ref program, float_key, wir_field_address(ref program, float_key, left, 1, "", no_wir_location()), "left.low", no_wir_location());
    let float_right_low: WirValueID = wir_load(ref program, float_key, wir_field_address(ref program, float_key, right, 1, "", no_wir_location()), "right.low", no_wir_location());
    let float_type: WirTypeID = wir_float_type(ref program, 64);
    let left_float: WirValueID = wir_unary(ref program, float_key, WirOpcode.Bitcast, float_type, float_left_low, "left.value", no_wir_location());
    let right_float: WirValueID = wir_unary(ref program, float_key, WirOpcode.Bitcast, float_type, float_right_low, "right.value", no_wir_location());
    let float_result: WirValueID = wir_binary(ref program, float_key, WirOpcode.Equal, program.bool_type, left_float, right_float, "equal", no_wir_location());
    wir_return(ref program, float_key, float_result, no_wir_location());

    let class_check: WirBlockID = check_class;
    let hash_interface: StructInfo = source.struct_table.lookup("hashing.Hash");
    let type_id: Int = 100;
    while (type_id < source.type_counter) {
        let info: StructInfo = source.struct_id_map.lookup("" + type_id);
        let comparable: Bool = has_struct(info) && info.is_class && has_struct(hash_interface) && implements_interface(ref source, type_id, hash_interface.type_id);
        if comparable {
            let class_key: WirBlockID = wir_add_block(ref program, function_id, "class." + type_id, []);
            let next: WirBlockID = wir_add_block(ref program, function_id, "check.class." + type_id, []);
            let matches: WirValueID = wir_binary(ref program, class_check, WirOpcode.Equal, program.bool_type, left_tag, wir_const_int(ref program, tag_type, UInt128(type_fingerprint(ref source, type_id))), "matches", no_wir_location());
            wir_append(ref program, class_check, WirOpcode.Branch, program.void_type, [matches], [wir_edge(class_key, []), wir_edge(next, [])], no_wir_location());

            let left_low: WirValueID = wir_load(ref program, class_key, wir_field_address(ref program, class_key, left, 1, "", no_wir_location()), "left.low", no_wir_location());
            let right_low: WirValueID = wir_load(ref program, class_key, wir_field_address(ref program, class_key, right, 1, "", no_wir_location()), "right.low", no_wir_location());
            let class_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, type_id);
            let left_value: WirValueID = wir_cast(ref program, class_key, left_low, class_type, "left.value", no_wir_location());
            let right_value: WirValueID = wir_cast(ref program, class_key, right_low, class_type, "right.value", no_wir_location());
            let class_equal: WirFuncID = wir_dict_class_equal_function(ref types, ref source, ref program, type_id, info);
            if (class_equal != NO_WIR_FUNC) {
                let class_result: WirValueID = wir_call(ref program, class_key, wir_function_value(program, class_equal), [left_value, right_value], "equal", no_wir_location());
                wir_return(ref program, class_key, class_result, no_wir_location());
            } else {
                wir_append(ref program, class_key, WirOpcode.Jump, program.void_type, [], [wir_edge(bits, [])], no_wir_location());
            }
            class_check = next;
        }
        type_id++;
    }
    wir_append(ref program, class_check, WirOpcode.Jump, program.void_type, [], [wir_edge(bits, [])], no_wir_location());

    let bits_left_low: WirValueID = wir_load(ref program, bits, wir_field_address(ref program, bits, left, 1, "", no_wir_location()), "left.low", no_wir_location());
    let bits_right_low: WirValueID = wir_load(ref program, bits, wir_field_address(ref program, bits, right, 1, "", no_wir_location()), "right.low", no_wir_location());
    let bits_left_high: WirValueID = wir_load(ref program, bits, wir_field_address(ref program, bits, left, 2, "", no_wir_location()), "left.high", no_wir_location());
    let bits_right_high: WirValueID = wir_load(ref program, bits, wir_field_address(ref program, bits, right, 2, "", no_wir_location()), "right.high", no_wir_location());
    let same_low: WirValueID = wir_binary(ref program, bits, WirOpcode.Equal, program.bool_type, bits_left_low, bits_right_low, "same.low", no_wir_location());
    let same_high: WirValueID = wir_binary(ref program, bits, WirOpcode.Equal, program.bool_type, bits_left_high, bits_right_high, "same.high", no_wir_location());
    let same_bits: WirValueID = wir_binary(ref program, bits, WirOpcode.BitAnd, program.bool_type, same_low, same_high, "same.bits", no_wir_location());
    wir_return(ref program, bits, same_bits, no_wir_location());
    wir_return(ref program, equal, wir_const_bool(ref program, true), no_wir_location());
    wir_return(ref program, different, wir_const_bool(ref program, false), no_wir_location());
    return function_id;
}

func wir_dict_string_hash_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int) -> WirFuncID {
    let name: String = "__wl_hash_value_" + source_type;
    let existing: WirFuncID = wir_find_function(program, name);
    if (existing != NO_WIR_FUNC) { return existing; }

    let string_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    let i8_type: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("key", string_type)], i32_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let key: WirValueID = function.parameters[0];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let read: WirBlockID = wir_add_block(ref program, function_id, "read", []);
    let loop: WirBlockID = wir_add_block(ref program, function_id, "loop", [wir_param("index", i32_type), wir_param("state", i64_type)]);
    let body: WirBlockID = wir_add_block(ref program, function_id, "body", []);
    let finish: WirBlockID = wir_add_block(ref program, function_id, "finish", []);
    let invalid: WirBlockID = wir_add_block(ref program, function_id, "invalid", []);

    let is_null: WirValueID = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, key, wir_null(ref program, string_type), "is.null", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [is_null], [wir_edge(invalid, []), wir_edge(read, [])], no_wir_location());

    let data: WirValueID = wir_load(ref program, read, wir_field_address(ref program, read, key, 0, "", no_wir_location()), "data", no_wir_location());
    let length: WirValueID = wir_load(ref program, read, wir_field_address(ref program, read, key, 1, "", no_wir_location()), "length", no_wir_location());
    let offset_basis: WirValueID = wir_const_int(ref program, i64_type, UInt128(14695981039346656037UL));
    wir_append(ref program, read, WirOpcode.Jump, program.void_type, [], [wir_edge(loop, [wir_const_int(ref program, i32_type, UInt128(0U)), offset_basis])], no_wir_location());

    let loop_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(loop))];
    let index: WirValueID = loop_block.parameters[0];
    let state: WirValueID = loop_block.parameters[1];
    let done: WirValueID = wir_binary(ref program, loop, WirOpcode.SignedGreaterEqual, program.bool_type, index, length, "done", no_wir_location());
    wir_append(ref program, loop, WirOpcode.Branch, program.void_type, [done], [wir_edge(finish, []), wir_edge(body, [])], no_wir_location());

    let byte_address: WirValueID = wir_index_address(ref program, body, data, index, "", no_wir_location());
    let byte: WirValueID = wir_load(ref program, body, byte_address, "byte", no_wir_location());
    let wide: WirValueID = byte;
    if (wir_value_type(program, byte) == i8_type) { wide = wir_cast(ref program, body, byte, i64_type, "wide", no_wir_location()); }
    let mixed: WirValueID = wir_binary(ref program, body, WirOpcode.BitXor, i64_type, state, wide, "mixed", no_wir_location());
    let next_state: WirValueID = wir_binary(ref program, body, WirOpcode.Multiply, i64_type, mixed, wir_const_int(ref program, i64_type, UInt128(1099511628211UL)), "next.state", no_wir_location());
    let next: WirValueID = wir_binary(ref program, body, WirOpcode.Add, i32_type, index, wir_const_int(ref program, i32_type, UInt128(1U)), "next", no_wir_location());
    wir_append(ref program, body, WirOpcode.Jump, program.void_type, [], [wir_edge(loop, [next, next_state])], no_wir_location());

    let mix_id: WirFuncID = wir_dict_mix_function(ref program);
    let length_wide: WirValueID = wir_cast(ref program, finish, length, i64_type, "length.wide", no_wir_location());
    let tag: WirValueID = wir_const_int(ref program, i64_type, UInt128(type_fingerprint(ref source, source_type)));
    let result: WirValueID = wir_call(ref program, finish, wir_function_value(program, mix_id), [tag, state, length_wide], "hash", no_wir_location());
    wir_return(ref program, finish, result, no_wir_location());
    wir_return(ref program, invalid, wir_const_int(ref program, i32_type, UInt128(0U)), no_wir_location());
    return function_id;
}

func wir_dict_string_equal_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int) -> WirFuncID {
    let name: String = "__wl_values_equal_" + source_type;
    let existing: WirFuncID = wir_find_function(program, name);
    if (existing != NO_WIR_FUNC) { return existing; }

    let string_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("left", string_type), wir_param("right", string_type)], program.bool_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let compare: FuncInfo = wir_compiler_link_function(ref source, "string_compare");
    if (!has_func(compare)) {
        wir_trap(ref program, entry, no_wir_location());
        return function_id;
    }
    let compare_id: WirFuncID = wir_find_function(program, compare.name);
    if (compare_id == NO_WIR_FUNC) { compare_id = wir_lower_function_decl(ref types, ref source, ref program, compare); }
    let ordering: WirValueID = wir_call(ref program, entry, wir_function_value(program, compare_id), [function.parameters[0], function.parameters[1]], "ordering", no_wir_location());
    let i32_type: WirTypeID = wir_value_type(program, ordering);
    let equal: WirValueID = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, ordering, wir_const_int(ref program, i32_type, UInt128(0U)), "equal", no_wir_location());
    wir_return(ref program, entry, equal, no_wir_location());
    return function_id;
}

func wir_dict_scalar_hash_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int) -> WirFuncID {
    let name: String = "__wl_hash_value_" + source_type;
    let existing: WirFuncID = wir_find_function(program, name);
    if (existing != NO_WIR_FUNC) { return existing; }

    let source_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (source_wir == NO_WIR_TYPE) { return NO_WIR_FUNC; }
    let source_layout: WirType = program.arena.types[wir_id_index(UInt32(source_wir))];
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("key", source_wir)], i32_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let key: WirValueID = function.parameters[0];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let mix: WirFuncID = wir_dict_mix_function(ref program);
    let tag: WirValueID = wir_const_int(ref program, i64_type, UInt128(type_fingerprint(ref source, source_type)));

    if (source_layout.kind == WirTypeKind.FloatType) {
        let invalid: WirBlockID = wir_add_block(ref program, function_id, "invalid", []);
        let valid: WirBlockID = wir_add_block(ref program, function_id, "valid", []);
        let zero: WirBlockID = wir_add_block(ref program, function_id, "zero", []);
        let bits: WirBlockID = wir_add_block(ref program, function_id, "bits", []);
        let done: WirBlockID = wir_add_block(ref program, function_id, "done", [wir_param("payload", i64_type)]);
        let is_nan: WirValueID = wir_binary(ref program, entry, WirOpcode.NotEqual, program.bool_type, key, key, "is.nan", no_wir_location());
        wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [is_nan], [wir_edge(invalid, []), wir_edge(valid, [])], no_wir_location());
        let is_zero: WirValueID = wir_binary(ref program, valid, WirOpcode.Equal, program.bool_type, key, wir_const_float(ref program, source_wir, 0.0), "is.zero", no_wir_location());
        wir_append(ref program, valid, WirOpcode.Branch, program.void_type, [is_zero], [wir_edge(zero, []), wir_edge(bits, [])], no_wir_location());
        wir_append(ref program, zero, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [wir_const_int(ref program, i64_type, UInt128(0U))])], no_wir_location());
        let raw_type: WirTypeID = wir_unsigned_int_type(ref program, source_layout.bits);
        let raw: WirValueID = wir_unary(ref program, bits, WirOpcode.Bitcast, raw_type, key, "raw", no_wir_location());
        let wide: WirValueID = wir_cast(ref program, bits, raw, i64_type, "wide", no_wir_location());
        wir_append(ref program, bits, WirOpcode.Jump, program.void_type, [], [wir_edge(done, [wide])], no_wir_location());
        let done_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(done))];
        let result: WirValueID = wir_call(ref program, done, wir_function_value(program, mix), [tag, done_block.parameters[0], wir_const_int(ref program, i64_type, UInt128(0U))], "hash", no_wir_location());
        wir_return(ref program, done, result, no_wir_location());
        wir_return(ref program, invalid, wir_const_int(ref program, i32_type, UInt128(0U)), no_wir_location());
        return function_id;
    }

    if (source_layout.kind == WirTypeKind.Pointer) {
        let bits: WirValueID = wir_cast(ref program, entry, key, i64_type, "bits", no_wir_location());
        let result: WirValueID = wir_call(ref program, entry, wir_function_value(program, mix), [tag, bits, wir_const_int(ref program, i64_type, UInt128(0U))], "hash", no_wir_location());
        wir_return(ref program, entry, result, no_wir_location());
        return function_id;
    }

    if (source_layout.bits == 128) {
        let low: WirValueID = wir_cast(ref program, entry, key, i64_type, "low", no_wir_location());
        let unsigned_source: WirTypeID = wir_unsigned_int_type(ref program, 128);
        let raw: WirValueID = key;
        if (source_wir != unsigned_source) { raw = wir_unary(ref program, entry, WirOpcode.Bitcast, unsigned_source, key, "raw", no_wir_location()); }
        let shifted: WirValueID = wir_binary(ref program, entry, WirOpcode.UnsignedShiftRight, unsigned_source, raw, wir_const_int(ref program, unsigned_source, UInt128(64U)), "shifted", no_wir_location());
        let high: WirValueID = wir_cast(ref program, entry, shifted, i64_type, "high", no_wir_location());
        let result: WirValueID = wir_call(ref program, entry, wir_function_value(program, mix), [tag, low, high], "hash", no_wir_location());
        wir_return(ref program, entry, result, no_wir_location());
        return function_id;
    }

    let unsigned_source: WirTypeID = wir_unsigned_int_type(ref program, source_layout.bits);
    let raw: WirValueID = key;
    if (source_wir != unsigned_source) { raw = wir_unary(ref program, entry, WirOpcode.Bitcast, unsigned_source, key, "raw", no_wir_location()); }
    let bits: WirValueID = wir_cast(ref program, entry, raw, i64_type, "bits", no_wir_location());
    let result: WirValueID = wir_call(ref program, entry, wir_function_value(program, mix), [tag, bits, wir_const_int(ref program, i64_type, UInt128(0U))], "hash", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());
    return function_id;
}

func wir_dict_scalar_equal_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int) -> WirFuncID {
    let name: String = "__wl_values_equal_" + source_type;
    let existing: WirFuncID = wir_find_function(program, name);
    if (existing != NO_WIR_FUNC) { return existing; }
    let source_wir: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (source_wir == NO_WIR_TYPE) { return NO_WIR_FUNC; }
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("left", source_wir), wir_param("right", source_wir)], program.bool_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let equal: WirValueID = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, function.parameters[0], function.parameters[1], "equal", no_wir_location());
    wir_return(ref program, entry, equal, no_wir_location());
    return function_id;
}

func wir_dict_class_method(info: StructInfo, name: String) -> FuncInfo {
    let index: Int = 0;
    while (info.vtable is !null && index < info.vtable.length()) {
        let method_info: FuncInfo = info.vtable[index];
        if (method_info.base_name == name) { return method_info; }
        index++;
    }
    return FuncInfo();
}

func wir_dict_class_method_index(info: StructInfo, name: String) -> Int {
    let index: Int = 0;
    while (info.vtable is !null && index < info.vtable.length()) {
        let method_info: FuncInfo = info.vtable[index];
        if (method_info.base_name == name) { return index; }
        index++;
    }
    return -1;
}

func wir_dict_class_hash_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int, info: StructInfo) -> WirFuncID {
    let name: String = "__wl_hash_value_" + source_type;
    let existing: WirFuncID = wir_find_function(program, name);
    if (existing != NO_WIR_FUNC) { return existing; }

    let method_info: FuncInfo = wir_dict_class_method(info, "hash");
    let slot: Int = wir_dict_class_method_index(info, "hash");
    if (!has_func(method_info) || slot < 0) { return NO_WIR_FUNC; }
    queue_generic_class_method(ref source, info, method_info.base_name);
    let method_id: WirFuncID = wir_find_function(program, method_info.name);
    if (method_id == NO_WIR_FUNC) { method_id = wir_lower_function_decl(ref types, ref source, ref program, method_info); }
    if (method_id == NO_WIR_FUNC) { return NO_WIR_FUNC; }

    let class_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let i64_type: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("key", class_type)], i32_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let call: WirBlockID = wir_add_block(ref program, function_id, "call", []);
    let invalid: WirBlockID = wir_add_block(ref program, function_id, "invalid", []);
    let key: WirValueID = function.parameters[0];
    let is_null: WirValueID = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, key, wir_null(ref program, class_type), "is.null", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [is_null], [wir_edge(invalid, []), wir_edge(call, [])], no_wir_location());

    let table: WirValueID = wir_load(ref program, call, wir_field_address(ref program, call, key, 0, "", no_wir_location()), "vtable", no_wir_location());
    let slot_value: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, program.pointer_bits), UInt128(UIntSize(slot)));
    let method_address: WirValueID = wir_index_address(ref program, call, table, slot_value, "", no_wir_location());
    let callee: WirValueID = wir_load(ref program, call, method_address, "method", no_wir_location());
    let method_function: WirFunction = program.arena.functions[wir_id_index(UInt32(method_id))];
    let hash: WirValueID = wir_call_typed(ref program, call, callee, method_function.type_id, [key], "hash", no_wir_location());
    let wide: WirValueID = wir_cast(ref program, call, hash, i64_type, "wide", no_wir_location());
    let mix: WirFuncID = wir_dict_mix_function(ref program);
    let tag: WirValueID = wir_const_int(ref program, i64_type, UInt128(type_fingerprint(ref source, source_type)));
    let result: WirValueID = wir_call(ref program, call, wir_function_value(program, mix), [tag, wide, wir_const_int(ref program, i64_type, UInt128(0U))], "result", no_wir_location());
    wir_return(ref program, call, result, no_wir_location());
    wir_return(ref program, invalid, wir_const_int(ref program, i32_type, UInt128(0U)), no_wir_location());
    return function_id;
}

func wir_dict_class_equal_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int, info: StructInfo) -> WirFuncID {
    let name: String = "__wl_values_equal_" + source_type;
    let existing: WirFuncID = wir_find_function(program, name);
    if (existing != NO_WIR_FUNC) { return existing; }

    let method_info: FuncInfo = wir_dict_class_method(info, "equals");
    let slot: Int = wir_dict_class_method_index(info, "equals");
    if (!has_func(method_info) || slot < 0) { return NO_WIR_FUNC; }
    queue_generic_class_method(ref source, info, method_info.base_name);
    let method_id: WirFuncID = wir_find_function(program, method_info.name);
    if (method_id == NO_WIR_FUNC) { method_id = wir_lower_function_decl(ref types, ref source, ref program, method_info); }
    if (method_id == NO_WIR_FUNC) { return NO_WIR_FUNC; }

    let class_type: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("left", class_type), wir_param("right", class_type)], program.bool_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let check_null: WirBlockID = wir_add_block(ref program, function_id, "check.null", []);
    let call: WirBlockID = wir_add_block(ref program, function_id, "call", []);
    let equal: WirBlockID = wir_add_block(ref program, function_id, "equal", []);
    let different: WirBlockID = wir_add_block(ref program, function_id, "different", []);
    let left: WirValueID = function.parameters[0];
    let right: WirValueID = function.parameters[1];
    let same: WirValueID = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, left, right, "same", no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [same], [wir_edge(equal, []), wir_edge(check_null, [])], no_wir_location());
    let left_null: WirValueID = wir_binary(ref program, check_null, WirOpcode.Equal, program.bool_type, left, wir_null(ref program, class_type), "left.null", no_wir_location());
    let right_null: WirValueID = wir_binary(ref program, check_null, WirOpcode.Equal, program.bool_type, right, wir_null(ref program, class_type), "right.null", no_wir_location());
    let has_null: WirValueID = wir_binary(ref program, check_null, WirOpcode.BitOr, program.bool_type, left_null, right_null, "has.null", no_wir_location());
    wir_append(ref program, check_null, WirOpcode.Branch, program.void_type, [has_null], [wir_edge(different, []), wir_edge(call, [])], no_wir_location());

    let table: WirValueID = wir_load(ref program, call, wir_field_address(ref program, call, left, 0, "", no_wir_location()), "vtable", no_wir_location());
    let slot_value: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, program.pointer_bits), UInt128(UIntSize(slot)));
    let method_address: WirValueID = wir_index_address(ref program, call, table, slot_value, "", no_wir_location());
    let callee: WirValueID = wir_load(ref program, call, method_address, "method", no_wir_location());
    let method_function: WirFunction = program.arena.functions[wir_id_index(UInt32(method_id))];
    let result: WirValueID = wir_call_typed(ref program, call, callee, method_function.type_id, [left, right], "result", no_wir_location());
    wir_return(ref program, call, result, no_wir_location());
    wir_return(ref program, equal, wir_const_bool(ref program, true), no_wir_location());
    wir_return(ref program, different, wir_const_bool(ref program, false), no_wir_location());
    return function_id;
}

func wir_dict_typed_hash_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int) -> WirFuncID {
    let repr: Int = get_repr_type(ref source, source_type);
    if (repr == TYPE_STRING) { return wir_dict_string_hash_function(ref types, ref source, ref program, source_type); }
    let info: StructInfo = source.struct_id_map.lookup("" + repr);
    if (has_struct(info) && info.is_class) { return wir_dict_class_hash_function(ref types, ref source, ref program, source_type, info); }
    return wir_dict_scalar_hash_function(ref types, ref source, ref program, source_type);
}

func wir_dict_typed_equal_function(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, source_type: Int) -> WirFuncID {
    let repr: Int = get_repr_type(ref source, source_type);
    if (repr == TYPE_STRING) { return wir_dict_string_equal_function(ref types, ref source, ref program, source_type); }
    let info: StructInfo = source.struct_id_map.lookup("" + repr);
    if (has_struct(info) && info.is_class) { return wir_dict_class_equal_function(ref types, ref source, ref program, source_type, info); }
    return wir_dict_scalar_equal_function(ref types, ref source, ref program, source_type);
}
