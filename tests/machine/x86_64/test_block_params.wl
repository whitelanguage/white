// Test: X86_64_BLOCK_PARAMETERS
// File: tests/machine/x86_64/test_block_params.wl
// Focus: Transfer block arguments safely across conditional and cyclic edges.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let result_param: Vector(WirParam) = [WirParam(name="value", type_id=int_type)];
    let function_id: WirFuncID = wir_add_function(ref program, "main", [], int_type, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let less: WirBlockID = wir_add_block(ref program, function_id, "less", result_param);
    let greater_equal: WirBlockID = wir_add_block(ref program, function_id, "greater_equal", result_param);
    let left: WirValueID = wir_const_int(ref program, int_type, UInt128(1U));
    let right: WirValueID = wir_const_int(ref program, int_type, UInt128(2U));
    let answer: WirValueID = wir_const_int(ref program, int_type, UInt128(42U));
    let fallback: WirValueID = wir_const_int(ref program, int_type, UInt128(1U));
    let condition: WirValueID = wir_append(ref program, entry, WirOpcode.SignedLess, program.bool_type, [left, right], [], no_wir_location());
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [condition], [wir_edge(less, [answer]), wir_edge(greater_equal, [fallback])], no_wir_location());
    wir_return(ref program, less, program.arena.blocks[wir_id_index(UInt32(less))].parameters[0], no_wir_location());
    wir_return(ref program, greater_equal, program.arena.blocks[wir_id_index(UInt32(greater_equal))].parameters[0], no_wir_location());

    let lowered: X86LoweringResult = x86_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: x86_64 block parameter lowering failed: ", lowered.errors[0]);
        return 1;
    }

    let swap_params: Vector(WirParam) = [WirParam(name="left", type_id=int_type), WirParam(name="right", type_id=int_type)];
    let loop_id: WirFuncID = wir_add_function(ref program, "swap_loop", [], int_type, false, WirLinkage.Internal, WirABI.White);
    let loop_entry: WirBlockID = wir_add_block(ref program, loop_id, "swap.entry", []);
    let loop_body: WirBlockID = wir_add_block(ref program, loop_id, "swap.body", swap_params);
    wir_append(ref program, loop_entry, WirOpcode.Jump, program.void_type, [], [wir_edge(loop_body, [left, right])], no_wir_location());
    let loop_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(loop_body))];
    wir_append(ref program, loop_body, WirOpcode.Jump, program.void_type, [], [wir_edge(loop_body, [loop_block.parameters[1], loop_block.parameters[0]])], no_wir_location());
    let loop_lowered: X86LoweringResult = x86_lower_function(ref program, loop_id);
    if (loop_lowered.errors.length() != 0) {
        print("FAIL: cyclic block parameter transfer failed: ", loop_lowered.errors[0]);
        return 1;
    }

    let object: Vector(Byte) = coff_object_for_text("main", lowered.bytes)?;
    catch(err) {
        print("FAIL: could not write block parameter test object");
        return 1;
    }
    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: could not print block parameter WIR");
        return 1;
    }
    print("WIR-BEGIN");
    print(text);
    print("WIR-END");
    print("OBJECT-BEGIN");
    let i: Int = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i += 1;
    }
    print("OBJECT-END");
    return 0;
}
