// src/compiler/machine/remainder.wl
import * from "../wir/model.wl"
import * from "../wir/builder.wl"


func machine_rem_branch(ref program: WirModule, block: WirBlockID, condition: WirValueID, yes: WirBlockID, yes_args: Vector(WirValueID), no: WirBlockID, no_args: Vector(WirValueID)) -> Void {
    wir_append(ref program, block, WirOpcode.Branch, program.void_type, [condition], [wir_edge(yes, yes_args), wir_edge(no, no_args)], no_wir_location());
}

func machine_rem_helper(ref program: WirModule, type: WirTypeID) -> WirFuncID {
// reduce by powers of two, every subtraction is exact once the divisor is aligned
    let bits = program.arena.types[wir_id_index(UInt32(type))].bits;
    let int = wir_unsigned_int_type(ref program, bits);
    let sign_bits = 0x8000000000000000UL;
    let inf_bits = 0x7ff0000000000000UL;
    let nan_bits = 0x7ff8000000000000UL;
    let half_bits = 0x3fe0000000000000UL;
    if (bits == 32) {
        sign_bits = 0x80000000UL;
        inf_bits = 0x7f800000UL;
        nan_bits = 0x7fc00000UL;
        half_bits = 0x3f000000UL;
    }

    let name = "$machine.frem.f" + bits;
    while (program.arena.function_names.contains_key(name)) { name += "."; }
    let function = wir_add_function(ref program, name, [wir_param("x", type), wir_param("y", type)], type, false, WirLinkage.Internal, WirABI.White);
    let params = program.arena.functions[wir_id_index(UInt32(function))].parameters;
    let entry = wir_add_block(ref program, function, "entry", []);
    let invalid = wir_add_block(ref program, function, "invalid", []);
    let check = wir_add_block(ref program, function, "check", []);
    let unchanged = wir_add_block(ref program, function, "unchanged", []);
    let align = wir_add_block(ref program, function, "align", [wir_param("d", type)]);
    let reduce = wir_add_block(ref program, function, "reduce", [wir_param("r", type), wir_param("d", type)]);
    let subtract = wir_add_block(ref program, function, "subtract", []);
    let next = wir_add_block(ref program, function, "next", [wir_param("r", type)]);
    let step = wir_add_block(ref program, function, "step", []);
    let done = wir_add_block(ref program, function, "done", []);
    let loc = no_wir_location();

    let sign_mask = wir_const_int(ref program, int, UInt128(sign_bits));
    let abs_mask = wir_const_int(ref program, int, UInt128(sign_bits - 1UL));
    let inf = wir_const_int(ref program, int, UInt128(inf_bits));
    let zero = wir_const_int(ref program, int, UInt128(0U));
    let half = wir_const_float_bits(ref program, type, half_bits);
    let xb = wir_unary(ref program, entry, WirOpcode.Bitcast, int, params[0], "xb", loc);
    let yb = wir_unary(ref program, entry, WirOpcode.Bitcast, int, params[1], "yb", loc);
    let sign = wir_binary(ref program, entry, WirOpcode.BitAnd, int, xb, sign_mask, "sign", loc);
    let ax = wir_binary(ref program, entry, WirOpcode.BitAnd, int, xb, abs_mask, "ax", loc);
    let ay = wir_binary(ref program, entry, WirOpcode.BitAnd, int, yb, abs_mask, "ay", loc);
    let y_zero = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, ay, zero, "", loc);
    let x_invalid = wir_binary(ref program, entry, WirOpcode.UnsignedGreaterEqual, program.bool_type, ax, inf, "", loc);
    let y_nan = wir_binary(ref program, entry, WirOpcode.UnsignedGreater, program.bool_type, ay, inf, "", loc);
    let bad = wir_binary(ref program, entry, WirOpcode.BitOr, program.bool_type, y_zero, x_invalid, "", loc);
    bad = wir_binary(ref program, entry, WirOpcode.BitOr, program.bool_type, bad, y_nan, "", loc);
    machine_rem_branch(ref program, entry, bad, invalid, [], check, []);
    wir_return(ref program, invalid, wir_const_float_bits(ref program, type, nan_bits), loc);

    let smaller = wir_binary(ref program, check, WirOpcode.UnsignedLess, program.bool_type, ax, ay, "", loc);
    let x = wir_unary(ref program, check, WirOpcode.Bitcast, type, ax, "x.abs", loc);
    let y = wir_unary(ref program, check, WirOpcode.Bitcast, type, ay, "y.abs", loc);
    machine_rem_branch(ref program, check, smaller, unchanged, [], align, [y]);
    wir_return(ref program, unchanged, params[0], loc);

    // doubling the divisor and halving it later preserve its significand, including
    // subnormals. A finite dividend also keeps an overflowing double out of reduce.
    // the two loops are bounded by the format's exponent range, never by x/y.
    let divisor = program.arena.blocks[wir_id_index(UInt32(align))].parameters[0];
    let doubled = wir_binary(ref program, align, WirOpcode.Add, type, divisor, divisor, "doubled", loc);
    let fits = wir_binary(ref program, align, WirOpcode.FloatLessEqual, program.bool_type, doubled, x, "", loc);
    machine_rem_branch(ref program, align, fits, align, [doubled], reduce, [x, divisor]);

    let current = program.arena.blocks[wir_id_index(UInt32(reduce))].parameters;
    let subtracts = wir_binary(ref program, reduce, WirOpcode.FloatGreaterEqual, program.bool_type, current[0], current[1], "", loc);
    machine_rem_branch(ref program, reduce, subtracts, subtract, [], next, [current[0]]);
    let difference = wir_binary(ref program, subtract, WirOpcode.Subtract, type, current[0], current[1], "difference", loc);
    wir_append(ref program, subtract, WirOpcode.Jump, program.void_type, [], [wir_edge(next, [difference])], loc);

    let result = program.arena.blocks[wir_id_index(UInt32(next))].parameters[0];
    let last = wir_binary(ref program, next, WirOpcode.Equal, program.bool_type, current[1], y, "", loc);
    machine_rem_branch(ref program, next, last, done, [], step, []);
    let halved = wir_binary(ref program, step, WirOpcode.Multiply, type, current[1], half, "halved", loc);
    wir_append(ref program, step, WirOpcode.Jump, program.void_type, [], [wir_edge(reduce, [result, halved])], loc);

    // OR the original sign onto a nonnegative remainder, subtraction can produce
    // +0 even when the required result is -0.
    let result_bits = wir_unary(ref program, done, WirOpcode.Bitcast, int, result, "bits", loc);
    let signed_bits = wir_binary(ref program, done, WirOpcode.BitOr, int, result_bits, sign, "signed", loc);
    wir_return(ref program, done, wir_unary(ref program, done, WirOpcode.Bitcast, type, signed_bits, "result", loc), loc);
    return function;
}

func machine_lower_remainders(ref program: WirModule) -> String {
// keep the original result IDs and locations, both encoders see ordinary calls
    let count = program.arena.instructions.length();
    let helpers: Dict(UInt32, WirFuncID) = null;
    for (let i = 0; i < count; i++) {
        let instruction = program.arena.instructions[i];
        if (instruction.opcode != WirOpcode.FloatRemainder) { continue; }
        let index = wir_id_index(UInt32(instruction.type_id));
        if (index < 0 || index >= program.arena.types.length() || instruction.operands.length() != 2) {
            return "floating remainder has an invalid WIR shape";
        }
        let type = program.arena.types[index];
        if (type.kind != WirTypeKind.FloatType || (type.bits != 32 && type.bits != 64)) {
            return "floating remainder requires f32 or f64";
        }
        if (helpers is null) { helpers = Dict(); }
        let helper = helpers.lookup(UInt32(instruction.type_id));
        if (helper == NO_WIR_FUNC) {
            helper = machine_rem_helper(ref program, instruction.type_id);
            helpers.put(UInt32(instruction.type_id), helper);
        }

        let callee = program.arena.functions[wir_id_index(UInt32(helper))];
        instruction.opcode = WirOpcode.Call;
        instruction.call_type = callee.type_id;
        instruction.operands = [callee.address, instruction.operands[0], instruction.operands[1]];
        program.arena.instructions[i] = instruction;
    }
    return "";
}
