// Test: X86_64_INTEGER_CASES
// File: tests/machine/x86_64/test_integer_cases.wl
// Focus: Execute signed and unsigned integer operations at each supported width.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"

struct IntegerCase(bits: Int, unsigned: Bool, opcode: WirOpcode, left: UInt64, right: UInt64, expected: UInt64, immediate: Bool)

func main() -> Int {
    let cases: Vector(IntegerCase) = [
        IntegerCase(8, false, WirOpcode.SignedDivide, 156UL, 7UL, 242UL, false),
        IntegerCase(16, false, WirOpcode.SignedDivide, 65436UL, 7UL, 65522UL, false),
        IntegerCase(32, false, WirOpcode.SignedDivide, 4294967196UL, 7UL, 4294967282UL, false),
        IntegerCase(64, false, WirOpcode.SignedDivide, 18446744073709551516UL, 7UL, 18446744073709551602UL, false),
        IntegerCase(8, false, WirOpcode.SignedRemainder, 156UL, 7UL, 254UL, false),
        IntegerCase(16, false, WirOpcode.SignedRemainder, 65436UL, 7UL, 65534UL, false),
        IntegerCase(32, false, WirOpcode.SignedRemainder, 4294967196UL, 7UL, 4294967294UL, false),
        IntegerCase(64, false, WirOpcode.SignedRemainder, 18446744073709551516UL, 7UL, 18446744073709551614UL, false),
        IntegerCase(8, true, WirOpcode.UnsignedDivide, 128UL, 7UL, 18UL, false),
        IntegerCase(16, true, WirOpcode.UnsignedDivide, 32768UL, 7UL, 4681UL, false),
        IntegerCase(32, true, WirOpcode.UnsignedDivide, 2147483648UL, 7UL, 306783378UL, false),
        IntegerCase(64, true, WirOpcode.UnsignedDivide, 9223372036854775808UL, 7UL, 1317624576693539401UL, false),
        IntegerCase(8, true, WirOpcode.UnsignedRemainder, 128UL, 7UL, 2UL, false),
        IntegerCase(16, true, WirOpcode.UnsignedRemainder, 32768UL, 7UL, 1UL, false),
        IntegerCase(32, true, WirOpcode.UnsignedRemainder, 2147483648UL, 7UL, 2UL, false),
        IntegerCase(64, true, WirOpcode.UnsignedRemainder, 9223372036854775808UL, 7UL, 1UL, false),
        IntegerCase(8, false, WirOpcode.SignedShiftRight, 192UL, 2UL, 240UL, false),
        IntegerCase(16, false, WirOpcode.SignedShiftRight, 65472UL, 2UL, 65520UL, true),
        IntegerCase(32, false, WirOpcode.SignedShiftRight, 4294967232UL, 2UL, 4294967280UL, false),
        IntegerCase(64, false, WirOpcode.SignedShiftRight, 18446744073709551552UL, 2UL, 18446744073709551600UL, true),
        IntegerCase(64, true, WirOpcode.UnsignedShiftRight, 9223372036854775808UL, 63UL, 1UL, false),
        IntegerCase(64, true, WirOpcode.ShiftLeft, 1UL, 40UL, 1099511627776UL, true),
        IntegerCase(64, true, WirOpcode.BitOr, 4294967296UL, 3UL, 4294967299UL, false),
        IntegerCase(64, true, WirOpcode.BitXor, 4294967296UL, 3UL, 4294967299UL, true),
        IntegerCase(64, true, WirOpcode.BitAnd, 4294967296UL, 4294967295UL, 0UL, true),
        IntegerCase(8, true, WirOpcode.Add, 255UL, 1UL, 0UL, true),
        IntegerCase(8, false, WirOpcode.Add, 127UL, 1UL, 128UL, false),
        IntegerCase(16, true, WirOpcode.Multiply, 32768UL, 2UL, 0UL, false),
        IntegerCase(8, true, WirOpcode.BitOr, 128UL, 1UL, 129UL, true),
        IntegerCase(16, true, WirOpcode.BitXor, 65535UL, 255UL, 65280UL, true),
        IntegerCase(8, false, WirOpcode.Negate, 1UL, 0UL, 255UL, false),
        IntegerCase(16, false, WirOpcode.Negate, 1UL, 0UL, 65535UL, false),
        IntegerCase(32, false, WirOpcode.Negate, 1UL, 0UL, 4294967295UL, false),
        IntegerCase(64, false, WirOpcode.Negate, 1UL, 0UL, 18446744073709551615UL, false),
        IntegerCase(8, true, WirOpcode.Not, 128UL, 0UL, 127UL, false),
        IntegerCase(16, true, WirOpcode.Not, 32768UL, 0UL, 32767UL, false),
        IntegerCase(32, true, WirOpcode.Not, 2147483648UL, 0UL, 2147483647UL, false),
        IntegerCase(64, true, WirOpcode.Not, 9223372036854775808UL, 0UL, 9223372036854775807UL, false)
    ];
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32, false, WirLinkage.Exported, WirABI.White);
    let block: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let i: Int = 0;
    while (i < cases.length()) {
        let item: IntegerCase = cases[i];
        let scalar: WirTypeID = wir_signed_int_type(ref program, item.bits);
        if (item.unsigned) { scalar = wir_unsigned_int_type(ref program, item.bits); }
        let function: WirFuncID = wir_add_function(ref program, "case_" + i, [WirParam(name="left", type_id=scalar), WirParam(name="right", type_id=scalar)], scalar, false, WirLinkage.Internal, WirABI.White);
        let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
        let parameters: Vector(WirValueID) = program.arena.functions[wir_id_index(UInt32(function))].parameters;
        let right: WirValueID = parameters[1];
        if (item.immediate) { right = wir_const_int(ref program, scalar, UInt128(item.right)); }
        let result: WirValueID = NO_WIR_VALUE;
        if (item.opcode == WirOpcode.Negate || item.opcode == WirOpcode.Not) {
            result = wir_unary(ref program, entry, item.opcode, scalar, parameters[0], "result", no_wir_location());
        } else {
            result = wir_binary(ref program, entry, item.opcode, scalar, parameters[0], right, "result", no_wir_location());
        }
        wir_return(ref program, entry, result, no_wir_location());

        let signature: WirTypeID = wir_function_type(ref program, [scalar, scalar], scalar, false, WirABI.White);
        let actual: WirValueID = wir_call_typed(ref program, block, program.arena.functions[wir_id_index(UInt32(function))].address, signature, [wir_const_int(ref program, scalar, UInt128(item.left)), wir_const_int(ref program, scalar, UInt128(item.right))], "actual", no_wir_location());
        let condition: WirValueID = wir_append(ref program, block, WirOpcode.Equal, program.bool_type, [actual, wir_const_int(ref program, scalar, UInt128(item.expected))], [], no_wir_location());
        // leave flags different from the saved comparison before branching
        wir_binary(ref program, block, WirOpcode.Add, i32, wir_const_int(ref program, i32, UInt128(1U)), wir_const_int(ref program, i32, UInt128(1U)), "clobber", no_wir_location());
        let next: WirBlockID = wir_add_block(ref program, main_id, "next_" + i, []);
        let fail: WirBlockID = wir_add_block(ref program, main_id, "fail_" + i, []);
        wir_append(ref program, block, WirOpcode.Branch, program.void_type, [condition], [wir_edge(next, []), wir_edge(fail, [])], no_wir_location());
        wir_return(ref program, fail, wir_const_int(ref program, i32, UInt128(UInt32(i + 1))), no_wir_location());
        block = next;
        i++;
    }
    wir_return(ref program, block, wir_const_int(ref program, i32, UInt128(0U)), no_wir_location());
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid integer cases: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: integer cases lowering: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object_for_text_symbols(lowered.bytes, lowered.symbols, lowered.relocations)?;
    catch(err) {
        print("FAIL: integer cases COFF output");
        return 1;
    }
    print("PASS: x86_64 integer cases");
    print("OBJECT-BEGIN");
    i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");
    return 0;
}
