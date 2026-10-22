// src/compiler/machine/numeric.wl
import * from "../wir/model.wl"
import * from "../wir/builder.wl"


func machine_numeric_branch(ref program: WirModule, block: WirBlockID, condition: WirValueID, yes: WirBlockID, yes_args: Vector(WirValueID), no: WirBlockID, no_args: Vector(WirValueID)) -> Void {
    wir_append(ref program, block, WirOpcode.Branch, program.void_type, [condition], [wir_edge(yes, yes_args), wir_edge(no, no_args)], no_wir_location());
}

func machine_numeric_jump(ref program: WirModule, block: WirBlockID, next: WirBlockID, args: Vector(WirValueID)) -> Void {
    wir_append(ref program, block, WirOpcode.Jump, program.void_type, [], [wir_edge(next, args)], no_wir_location());
}

func machine_int128_to_float(ref program: WirModule, input: WirTypeID, output: WirTypeID, name: String) -> WirFuncID {
// round the integer once at the destination precision, going through f64 would
// lose sticky bits before a later f32 conversion
    let bits = program.arena.types[wir_id_index(UInt32(output))].bits;
    let fraction = 52;
    let bias = 1023;
    if (bits == 32) { fraction = 23; bias = 127; }
    let wide = wir_unsigned_int_type(ref program, 128);
    let word = wir_unsigned_int_type(ref program, 64);
    let signed = program.arena.types[wir_id_index(UInt32(input))].kind == WirTypeKind.SignedInt;
    let fn_id = wir_add_function(ref program, name, [wir_param("value", input)], output, false, WirLinkage.Internal, WirABI.White);
    let value = program.arena.functions[wir_id_index(UInt32(fn_id))].parameters[0];
    let entry = wir_add_block(ref program, fn_id, "entry", []);
    let zero_block = wir_add_block(ref program, fn_id, "zero", []);
    let scan = wir_add_block(ref program, fn_id, "scan", []);
    let loc = no_wir_location();
    let zero = wir_const_int(ref program, wide, UInt128(0U));
    let one = wir_const_int(ref program, wide, UInt128(1U));
    let word_zero = wir_const_int(ref program, word, UInt128(0U));
    let sign = word_zero;
    let magnitude = wir_cast(ref program, entry, value, wide, "magnitude", loc);

    if signed {
        let mask = wir_binary(ref program, entry, WirOpcode.SignedShiftRight, input, value, wir_const_int(ref program, input, UInt128(127U)), "mask", loc);
        let unsigned_mask = wir_cast(ref program, entry, mask, wide, "", loc);
        magnitude = wir_binary(ref program, entry, WirOpcode.BitXor, wide, magnitude, unsigned_mask, "", loc);
        magnitude = wir_binary(ref program, entry, WirOpcode.Subtract, wide, magnitude, unsigned_mask, "magnitude", loc);
        sign = wir_binary(ref program, entry, WirOpcode.BitAnd, word, wir_cast(ref program, entry, mask, word, "", loc), wir_const_int(ref program, word, UInt128(1U) << UInt128(bits - 1)), "sign", loc);
    }

    let empty = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, magnitude, zero, "", loc);
    machine_numeric_branch(ref program, entry, empty, zero_block, [], scan, []);
    wir_return(ref program, zero_block, wir_const_float_bits(ref program, output, 0UL), loc);

    // a binary search for the highest set bit takes seven tests even for u128 max
    let probe = magnitude;
    let exponent = word_zero;
    let current = scan;
    for (let step = 64; step > 0; step /= 2) {
        let shifted = wir_binary(ref program, current, WirOpcode.UnsignedShiftRight, wide, probe, wir_const_int(ref program, wide, UInt128(step)), "probe", loc);
        let high = wir_binary(ref program, current, WirOpcode.NotEqual, program.bool_type, shifted, zero, "", loc);
        let added = wir_binary(ref program, current, WirOpcode.Add, word, exponent, wir_const_int(ref program, word, UInt128(step)), "exponent", loc);
        let next = wir_add_block(ref program, fn_id, "scan." + step, [wir_param("probe", wide), wir_param("exponent", word)]);
        machine_numeric_branch(ref program, current, high, next, [shifted, added], next, [probe, exponent]);
        let params = program.arena.blocks[wir_id_index(UInt32(next))].parameters;
        probe = params[0];
        exponent = params[1];
        current = next;
    }

    let exact = wir_add_block(ref program, fn_id, "exact", []);
    let round = wir_add_block(ref program, fn_id, "round", []);
    let carry = wir_add_block(ref program, fn_id, "carry", []);
    let pack = wir_add_block(ref program, fn_id, "pack", [wir_param("significand", word), wir_param("exponent", word)]);
    let mantissa_bits = wir_const_int(ref program, word, UInt128(fraction));
    let fits = wir_binary(ref program, current, WirOpcode.UnsignedLessEqual, program.bool_type, exponent, mantissa_bits, "", loc);
    machine_numeric_branch(ref program, current, fits, exact, [], round, []);

    let left = wir_binary(ref program, exact, WirOpcode.Subtract, word, mantissa_bits, exponent, "", loc);
    let aligned = wir_binary(ref program, exact, WirOpcode.ShiftLeft, wide, magnitude, wir_cast(ref program, exact, left, wide, "", loc), "aligned", loc);
    machine_numeric_jump(ref program, exact, pack, [wir_cast(ref program, exact, aligned, word, "", loc), exponent]);

    let right = wir_binary(ref program, round, WirOpcode.Subtract, word, exponent, mantissa_bits, "", loc);
    let shift = wir_cast(ref program, round, right, wide, "", loc);
    let kept = wir_binary(ref program, round, WirOpcode.UnsignedShiftRight, wide, magnitude, shift, "kept", loc);
    let limit = wir_binary(ref program, round, WirOpcode.ShiftLeft, wide, one, shift, "", loc);
    let mask = wir_binary(ref program, round, WirOpcode.Subtract, wide, limit, one, "", loc);
    let discarded = wir_binary(ref program, round, WirOpcode.BitAnd, wide, magnitude, mask, "discarded", loc);
    let half = wir_binary(ref program, round, WirOpcode.UnsignedShiftRight, wide, limit, one, "half", loc);
    let above = wir_binary(ref program, round, WirOpcode.UnsignedGreater, program.bool_type, discarded, half, "", loc);
    let tie = wir_binary(ref program, round, WirOpcode.Equal, program.bool_type, discarded, half, "", loc);
    let odd = wir_binary(ref program, round, WirOpcode.NotEqual, program.bool_type, wir_binary(ref program, round, WirOpcode.BitAnd, wide, kept, one, "", loc), zero, "", loc);
    let tie_up = wir_binary(ref program, round, WirOpcode.BitAnd, program.bool_type, tie, odd, "", loc);
    let up = wir_binary(ref program, round, WirOpcode.BitOr, program.bool_type, above, tie_up, "", loc);
    let rounded = wir_binary(ref program, round, WirOpcode.Add, wide, kept, wir_cast(ref program, round, up, wide, "", loc), "rounded", loc);
    let significand = wir_cast(ref program, round, rounded, word, "", loc);
    let overflow = wir_binary(ref program, round, WirOpcode.UnsignedGreaterEqual, program.bool_type, rounded, wir_const_int(ref program, wide, UInt128(1U) << UInt128(fraction + 1)), "", loc);
    machine_numeric_branch(ref program, round, overflow, carry, [], pack, [significand, exponent]);

    let smaller = wir_binary(ref program, carry, WirOpcode.UnsignedShiftRight, word, significand, wir_const_int(ref program, word, UInt128(1U)), "", loc);
    let larger_exp = wir_binary(ref program, carry, WirOpcode.Add, word, exponent, wir_const_int(ref program, word, UInt128(1U)), "", loc);
    machine_numeric_jump(ref program, carry, pack, [smaller, larger_exp]);

    let params = program.arena.blocks[wir_id_index(UInt32(pack))].parameters;
    let biased = wir_binary(ref program, pack, WirOpcode.Add, word, params[1], wir_const_int(ref program, word, UInt128(bias)), "", loc);
    let exp_bits = wir_binary(ref program, pack, WirOpcode.ShiftLeft, word, biased, mantissa_bits, "", loc);
    let low = wir_binary(ref program, pack, WirOpcode.BitAnd, word, params[0], wir_const_int(ref program, word, (UInt128(1U) << UInt128(fraction)) - UInt128(1U)), "", loc);
    let encoded = wir_binary(ref program, pack, WirOpcode.BitOr, word, exp_bits, low, "", loc);
    encoded = wir_binary(ref program, pack, WirOpcode.BitOr, word, encoded, sign, "", loc);
    let rep = wir_unsigned_int_type(ref program, bits);
    wir_return(ref program, pack, wir_unary(ref program, pack, WirOpcode.Bitcast, output, wir_cast(ref program, pack, encoded, rep, "", loc), "result", loc), loc);
    return fn_id;
}

func machine_float_to_int128(ref program: WirModule, input: WirTypeID, output: WirTypeID, name: String) -> WirFuncID {
// decode the significand and shift it as an integer, no rounded floating
// subtraction is needed to recover the upper and lower halves
    let bits = program.arena.types[wir_id_index(UInt32(input))].bits;
    let fraction = 52;
    let bias = 1023;
    if (bits == 32) { fraction = 23; bias = 127; }
    let rep = wir_unsigned_int_type(ref program, bits);
    let word = wir_unsigned_int_type(ref program, 64);
    let wide = wir_unsigned_int_type(ref program, 128);
    let signed = program.arena.types[wir_id_index(UInt32(output))].kind == WirTypeKind.SignedInt;
    let fn_id = wir_add_function(ref program, name, [wir_param("value", input)], output, false, WirLinkage.Internal, WirABI.White);
    let value = program.arena.functions[wir_id_index(UInt32(fn_id))].parameters[0];
    let entry = wir_add_block(ref program, fn_id, "entry", []);
    let zero_block = wir_add_block(ref program, fn_id, "zero", []);
    let check = wir_add_block(ref program, fn_id, "check", []);
    let decode = wir_add_block(ref program, fn_id, "decode", []);
    let left = wir_add_block(ref program, fn_id, "left", []);
    let right = wir_add_block(ref program, fn_id, "right", []);
    let finish = wir_add_block(ref program, fn_id, "finish", [wir_param("magnitude", wide)]);
    let negative = wir_add_block(ref program, fn_id, "negative", []);
    let positive = wir_add_block(ref program, fn_id, "positive", []);
    let invalid = wir_add_block(ref program, fn_id, "invalid", []);
    let loc = no_wir_location();
    let encoded = wir_cast(ref program, entry, wir_unary(ref program, entry, WirOpcode.Bitcast, rep, value, "bits", loc), word, "", loc);
    let fraction_bits = wir_const_int(ref program, word, UInt128(fraction));
    let exp = wir_binary(ref program, entry, WirOpcode.UnsignedShiftRight, word, encoded, fraction_bits, "", loc);
    exp = wir_binary(ref program, entry, WirOpcode.BitAnd, word, exp, wir_const_int(ref program, word, UInt128(bias * 2 + 1)), "exponent", loc);
    let sign = wir_binary(ref program, entry, WirOpcode.UnsignedShiftRight, word, encoded, wir_const_int(ref program, word, UInt128(bits - 1)), "sign", loc);
    let small = wir_binary(ref program, entry, WirOpcode.UnsignedLess, program.bool_type, exp, wir_const_int(ref program, word, UInt128(bias)), "", loc);
    machine_numeric_branch(ref program, entry, small, zero_block, [], check, []);
    wir_return(ref program, zero_block, wir_const_int(ref program, output, UInt128(0U)), loc);

    // source casts already check range, raw WIR must not turn NaN or an excessive
    // exponent into a masked shift that happens to produce an ordinary integer
    let too_large = wir_binary(ref program, check, WirOpcode.UnsignedGreaterEqual, program.bool_type, exp, wir_const_int(ref program, word, UInt128(bias + 128)), "", loc);
    machine_numeric_branch(ref program, check, too_large, invalid, [], decode, []);
    wir_trap(ref program, invalid, loc);

    let exponent = wir_binary(ref program, decode, WirOpcode.Subtract, word, exp, wir_const_int(ref program, word, UInt128(bias)), "", loc);
    let fraction_mask = wir_const_int(ref program, word, (UInt128(1U) << UInt128(fraction)) - UInt128(1U));
    let significand = wir_binary(ref program, decode, WirOpcode.BitAnd, word, encoded, fraction_mask, "", loc);
    significand = wir_binary(ref program, decode, WirOpcode.BitOr, word, significand, wir_const_int(ref program, word, UInt128(1U) << UInt128(fraction)), "significand", loc);
    let mantissa = wir_cast(ref program, decode, significand, wide, "", loc);
    let high = wir_binary(ref program, decode, WirOpcode.UnsignedGreaterEqual, program.bool_type, exponent, fraction_bits, "", loc);
    machine_numeric_branch(ref program, decode, high, left, [], right, []);
    let left_shift = wir_binary(ref program, left, WirOpcode.Subtract, word, exponent, fraction_bits, "", loc);
    let shifted_left = wir_binary(ref program, left, WirOpcode.ShiftLeft, wide, mantissa, wir_cast(ref program, left, left_shift, wide, "", loc), "", loc);
    machine_numeric_jump(ref program, left, finish, [shifted_left]);
    let right_shift = wir_binary(ref program, right, WirOpcode.Subtract, word, fraction_bits, exponent, "", loc);
    let shifted_right = wir_binary(ref program, right, WirOpcode.UnsignedShiftRight, wide, mantissa, wir_cast(ref program, right, right_shift, wide, "", loc), "", loc);
    machine_numeric_jump(ref program, right, finish, [shifted_right]);

    let magnitude = program.arena.blocks[wir_id_index(UInt32(finish))].parameters[0];
    let is_negative = wir_binary(ref program, finish, WirOpcode.NotEqual, program.bool_type, sign, wir_const_int(ref program, word, UInt128(0U)), "", loc);
    if signed {
        let limit = wir_const_int(ref program, wide, UInt128(1U) << UInt128(127U));
        let beyond = wir_binary(ref program, finish, WirOpcode.UnsignedGreater, program.bool_type, magnitude, limit, "", loc);
        let at_limit = wir_binary(ref program, finish, WirOpcode.Equal, program.bool_type, magnitude, limit, "", loc);
        let nonnegative = wir_binary(ref program, finish, WirOpcode.Equal, program.bool_type, sign, wir_const_int(ref program, word, UInt128(0U)), "", loc);
        let positive_limit = wir_binary(ref program, finish, WirOpcode.BitAnd, program.bool_type, at_limit, nonnegative, "", loc);
        let overflow = wir_binary(ref program, finish, WirOpcode.BitOr, program.bool_type, beyond, positive_limit, "", loc);
        let choose = wir_add_block(ref program, fn_id, "choose", []);
        machine_numeric_branch(ref program, finish, overflow, invalid, [], choose, []);
        machine_numeric_branch(ref program, choose, is_negative, negative, [], positive, []);
        let negated = wir_unary(ref program, negative, WirOpcode.Negate, wide, magnitude, "", loc);
        wir_return(ref program, negative, wir_cast(ref program, negative, negated, output, "", loc), loc);
    } else {
        machine_numeric_branch(ref program, finish, is_negative, invalid, [], positive, []);
        wir_trap(ref program, negative, loc);
    }
    wir_return(ref program, positive, wir_cast(ref program, positive, magnitude, output, "", loc), loc);
    return fn_id;
}

func machine_lower_wide_conversions(ref program: WirModule) -> String {
// create each conversion body only when used, preserve source result IDs and locations
    let helpers: Dict(String, WirFuncID) = null;
    let count = program.arena.instructions.length();
    for (let i = 0; i < count; i++) {
        let inst = program.arena.instructions[i];
        let to_float = inst.opcode == WirOpcode.SignedIntToFloat || inst.opcode == WirOpcode.UnsignedIntToFloat;
        let to_int = inst.opcode == WirOpcode.FloatToSignedInt || inst.opcode == WirOpcode.FloatToUnsignedInt;
        if (!to_float && !to_int) { continue; }
        if (inst.operands.length() != 1 || inst.result == NO_WIR_VALUE) { return "numeric conversion requires one operand and a result"; }
        let operand_index = wir_id_index(UInt32(inst.operands[0]));
        if (operand_index < 0 || operand_index >= program.arena.values.length()) {
            return "numeric conversion has an invalid operand";
        }
        let source = wir_value_type(ref program, inst.operands[0]);
        let source_index = wir_id_index(UInt32(source));
        let target_index = wir_id_index(UInt32(inst.type_id));
        if (source_index < 0 || source_index >= program.arena.types.length() ||
            target_index < 0 || target_index >= program.arena.types.length()) {
            return "numeric conversion has an invalid type";
        }
        let integer = inst.type_id;
        let float = source;
        if to_float { integer = source; float = inst.type_id; }
        let int_type = program.arena.types[wir_id_index(UInt32(integer))];
        if (int_type.bits != 128) { continue; }
        let float_type = program.arena.types[wir_id_index(UInt32(float))];
        if ((int_type.kind != WirTypeKind.SignedInt && int_type.kind != WirTypeKind.UnsignedInt) ||
            float_type.kind != WirTypeKind.FloatType || (float_type.bits != 32 && float_type.bits != 64)) {
            return "128-bit numeric conversion requires an integer and f32 or f64";
        }
        let signed_op = inst.opcode == WirOpcode.SignedIntToFloat || inst.opcode == WirOpcode.FloatToSignedInt;
        if (signed_op != (int_type.kind == WirTypeKind.SignedInt)) {
            return "numeric conversion has mismatched integer signedness";
        }
        if (helpers is null) { helpers = Dict(); }
        let key = "" + UInt32(source) + "." + UInt32(inst.type_id);
        let helper = NO_WIR_FUNC;
        helper = helpers.get(key)?;
        catch(err) { helper = NO_WIR_FUNC; }
        if (helper == NO_WIR_FUNC) {
            let name = "$machine.convert." + key;
            while (program.arena.function_names.contains_key(name)) { name += "."; }
            if to_float {
                helper = machine_int128_to_float(ref program, source, inst.type_id, name);
            } else {
                helper = machine_float_to_int128(ref program, source, inst.type_id, name);
            }
            helpers.put(key, helper);
        }
        let callee = program.arena.functions[wir_id_index(UInt32(helper))];
        inst.opcode = WirOpcode.Call;
        inst.call_type = callee.type_id;
        inst.operands = [callee.address, inst.operands[0]];
        program.arena.instructions[i] = inst;
    }
    return "";
}
