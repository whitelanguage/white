// Test: WIR_LLVM_AGGREGATES
// File: tests/integration/tooling/test_wir_llvm_aggregates.wl
// Focus: Win64 physical signatures, entry storage, and PHIs after ABI checks.
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"


func contains_text(text: String, wanted: String) -> Bool {
    let i = 0;
    while (i + wanted.length() <= text.length()) {
        if (text.slice(i, i + wanted.length()) == wanted) { return true; }
        i++;
    }
    return false;
}

func main() -> Int {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i64_type = wir_signed_int_type(ref program, 64);
    let f32_type = wir_float_type(ref program, 32);
    let small = wir_struct_type(ref program, [f32_type]);
    let large = wir_struct_type(ref program, [i64_type, i64_type]);
    wir_add_function(ref program, "small_c", [wir_param("value", small)], small, false, WirLinkage.External, WirABI.C);
    let callee_type = wir_function_type(ref program, [large], large, false, WirABI.C);
    let function = wir_add_function(ref program, "large_c", [wir_param("value", large), wir_param("callee", callee_type)], large, false, WirLinkage.Exported, WirABI.C);
    let entry = wir_add_block(ref program, function, "entry", []);
    let body = wir_add_block(ref program, function, "body", [wir_param("value", large)]);
    let info = program.arena.functions[wir_id_index(UInt32(function))];
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(body, [info.parameters[0]])], no_wir_location());
    let block = program.arena.blocks[wir_id_index(UInt32(body))];
    let result = wir_call(ref program, body, info.parameters[1], [block.parameters[0]], "result", no_wir_location());
    wir_return(ref program, body, result, no_wir_location());

    let emitted = emit_wir_llvm(program)?;
    catch(err) { return 1; }
    if (emitted.errors.length() != 0) { return 2; }
    if (!contains_text(emitted.text, "declare ccc i32 @small_c(i32)")) { return 3; }
    if (!contains_text(emitted.text, "define ccc void @large_c(ptr sret(%wir.t")) { return 4; }
    if (!contains_text(emitted.text, ", %abi.ok.arg.0 ]")) { return 5; }
    if (!contains_text(emitted.text, "abi.ok.arg.0:\n  " + llvm_value_name(info.parameters[0]) + " = load")) { return 6; }
    if (!contains_text(emitted.text, "b1:\n  %abi.call.")) { return 7; }
    if (!contains_text(emitted.text, "declare void @llvm.trap()")) { return 8; }
    if (!contains_text(emitted.text, "  ret void\n")) { return 9; }
    print("PASS: WIR LLVM aggregate ABI");
    return 0;
}
