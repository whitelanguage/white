// Test: X86_64_BRANCH_LOWERING
// File: tests/machine/x86_64/test_branch.wl
// Focus: Encode forward and backward rel32 edges without assembler involvement.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);

    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "main", [], int_type, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);

    let less: WirBlockID = wir_add_block(ref program, function_id, "less", []);
    let greater_equal: WirBlockID = wir_add_block(ref program, function_id, "greater_equal", []);

    let slot: WirValueID = wir_stack_alloc(ref program, entry, int_type, "left", no_wir_location());
    let left: WirValueID = wir_const_int(ref program, int_type, UInt128(1U));
    let right: WirValueID = wir_const_int(ref program, int_type, UInt128(2U));
    wir_store(ref program, entry, left, slot, no_wir_location());

    let loaded: WirValueID = wir_load(ref program, entry, slot, "loaded", no_wir_location());
    let condition: WirValueID = wir_append(ref program, entry, WirOpcode.SignedLess, program.bool_type, [loaded, right], [], no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [condition], [wir_edge(less, []), wir_edge(greater_equal, [])], no_wir_location());
    wir_return(ref program, less, wir_const_int(ref program, int_type, UInt128(42U)), no_wir_location());
    wir_return(ref program, greater_equal, wir_const_int(ref program, int_type, UInt128(1U)), no_wir_location());

    let lowered: X86LoweringResult = x86_lower_function(program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: x86_64 branch lowering failed: ", lowered.errors[0]);
        return 1;
    }

    if (lowered.bytes.length() != 64 || lowered.bytes[33] != Byte(15) || lowered.bytes[34] != Byte(140)) {
        print("FAIL: unexpected conditional branch encoding: ", lowered.bytes.length(), " bytes, opcode ", Int(lowered.bytes[33]), " ", Int(lowered.bytes[34]));
        return 1;
    }

    let loop_id: WirFuncID = wir_add_function(ref program, "loop", [], int_type, false, WirLinkage.Internal, WirABI.White);
    let loop_entry: WirBlockID = wir_add_block(ref program, loop_id, "loop.entry", []);
    let loop_body: WirBlockID = wir_add_block(ref program, loop_id, "loop.body", []);
    wir_append(ref program, loop_entry, WirOpcode.Jump, program.void_type, [], [wir_edge(loop_body, [])], no_wir_location());
    wir_append(ref program, loop_body, WirOpcode.Jump, program.void_type, [], [wir_edge(loop_entry, [])], no_wir_location());

    let loop_lowered: X86LoweringResult = x86_lower_function(program, loop_id);
    if (loop_lowered.errors.length() != 0 || loop_lowered.bytes.length() != 10 ||
        loop_lowered.bytes[6] != Byte(246) || loop_lowered.bytes[7] != Byte(255) ||
        loop_lowered.bytes[8] != Byte(255) || loop_lowered.bytes[9] != Byte(255)) {
        print("FAIL: backward rel32 fixup is incorrect");
        return 1;
    }

    let object: Vector(Byte) = coff_object_for_text("main", lowered.bytes)?;
    catch(err) {
        print("FAIL: could not write branch test object");
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: could not print branch WIR");
        return 1;
    }
    print("WIR-BEGIN");
    print(text);
    print("WIR-END");

    print("OBJECT-BEGIN");
    let i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");

    return 0;
}
