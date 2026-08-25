// Test: WIR_LLVM_CONTROL
// File: tests/integration/tooling/test_wir_llvm_control.wl
// Focus: Emitting branches and block parameters as valid LLVM control flow.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32_type, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let true_block: WirBlockID = wir_add_block(ref program, main_id, "true", []);
    let false_block: WirBlockID = wir_add_block(ref program, main_id, "false", []);
    let exit: WirBlockID = wir_add_block(ref program, main_id, "exit", [wir_param("value", i32_type)]);
    let condition: WirValueID = wir_const_bool(ref program, true);
    let true_value: WirValueID = wir_const_int(ref program, i32_type, UInt128(42U));
    let false_value: WirValueID = wir_const_int(ref program, i32_type, UInt128(1U));

    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [condition], [wir_edge(true_block, []), wir_edge(false_block, [])], no_wir_location());
    wir_append(ref program, true_block, WirOpcode.Jump, program.void_type, [], [wir_edge(exit, [true_value])], no_wir_location());
    wir_append(ref program, false_block, WirOpcode.Jump, program.void_type, [], [wir_edge(exit, [false_value])], no_wir_location());
    let exit_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(exit))];
    wir_return(ref program, exit, exit_block.parameters[0], no_wir_location());

    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) {
        print("FAIL: WIR control flow could not be emitted as LLVM IR");
        return 1;
    }
    if (emitted.errors.length() != 0) {
        print("FAIL: valid WIR control flow was rejected: ", emitted.errors[0]);
        return 1;
    }
    let expected: String = "target triple = \"x86_64-pc-windows-msvc\"\n\ndefine i32 @main() {\nb1:\n  br i1 true, label %b2, label %b3\nb2:\n  br label %b4\nb3:\n  br label %b4\nb4:\n  %v2 = phi i32 [ 42, %b2 ], [ 1, %b3 ]\n  ret i32 %v2\n}\n";
    if (emitted.text != expected) {
        print("FAIL: WIR LLVM control-flow output is not stable");
        print(emitted.text);
        return 1;
    }
    print("PASS: WIR LLVM control flow");
    return 0;
}
