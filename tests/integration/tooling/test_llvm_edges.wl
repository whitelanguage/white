// Test: LLVM_PARALLEL_EDGES
// File: tests/integration/tooling/test_llvm_edges.wl
// Focus: Giving parallel WIR edges distinct LLVM predecessors and preserving negative i128 constants.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"


func has_text(text: String, part: String) -> Bool {
    let i = 0;
    while (i + part.length() <= text.length()) {
        if (text[i:i + part.length()] == part) { return true; }
        i++;
    }
    return false;
}

func main() -> Int {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type = wir_signed_int_type(ref program, 128);
    let func_id = wir_add_function(ref program, "choose", [wir_param("condition", program.bool_type)], int_type, false, WirLinkage.Internal, WirABI.White);
    let entry = wir_add_block(ref program, func_id, "entry", []);
    let join = wir_add_block(ref program, func_id, "join", [wir_param("value", int_type)]);
    let condition = program.arena.functions[wir_id_index(UInt32(func_id))].parameters[0];
    let negative = wir_const_int(ref program, int_type, ~UInt128(0U));
    let positive = wir_const_int(ref program, int_type, UInt128(42U));
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [condition], [wir_edge(join, [negative]), wir_edge(join, [positive])], no_wir_location());
    let branch = program.arena.blocks[wir_id_index(UInt32(entry))].instructions[0];
    let result = program.arena.blocks[wir_id_index(UInt32(join))].parameters[0];
    wir_return(ref program, join, result, no_wir_location());

    let emitted = emit_wir_llvm(program)?;
    catch(err) {
        print("FAIL: LLVM parallel edges");
        return 1;
    }
    let edge = "edge." + UInt32(branch);
    if (emitted.errors.length() != 0 || !has_text(emitted.text, "br i1 %v1, label %" + edge + ".0, label %" + edge + ".1") ||
        !has_text(emitted.text, "phi i128 [ -1, %" + edge + ".0 ], [ 42, %" + edge + ".1 ]")) {
        print("FAIL: LLVM parallel edges", emitted.text);
        return 1;
    }

    print("PASS: LLVM parallel edges and signed i128");
    return 0;
}
