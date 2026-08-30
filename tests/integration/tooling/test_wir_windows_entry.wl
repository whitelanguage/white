// Test: WIR_WINDOWS_ENTRY
// File: tests/integration/tooling/test_wir_windows_entry.wl
// Focus: Building Windows process entry points from ordinary WIR functions.

import * from "../../../src/compiler/context.wl"
import PARAM_VALUE from "../../../src/frontend/ast.wl"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import wir_find_function from "../../../src/compiler/wir/lowering/declarations.wl"
import wir_find_global from "../../../src/compiler/wir/lowering/globals.wl"
import * from "../../../src/compiler/wir/lowering/target_runtime.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func entry_contains(text: String, needle: String) -> Bool {
    let start: Int = 0;
    while (start + needle.length() <= text.length()) {
        let offset: Int = 0;
        while (offset < needle.length() && text[start + offset] == needle[offset]) { offset++; }
        if (offset == needle.length()) { return true; }
        start++;
    }
    return needle.length() == 0;
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let main_id: WirFuncID = wir_add_function(ref program, "main", [], int_type, false, WirLinkage.Exported, WirABI.White);
    let main_entry: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    wir_return(ref program, main_entry, wir_const_int(ref program, int_type, UInt128(0U)), no_wir_location());
    let exit_id: WirFuncID = wir_add_function(ref program, "runtime.exit", [wir_param("status", int_type)], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let exit_entry: WirBlockID = wir_add_block(ref program, exit_id, "entry", []);
    wir_return(ref program, exit_entry, NO_WIR_VALUE, no_wir_location());

    let functions: Dict(String, FuncInfo) = Dict();
    let links: Dict(String, String) = Dict();
    functions.put("runtime.exit", FuncInfo(name="runtime.exit", base_name="process_exit", ret_type=TYPE_VOID, arg_types=[TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)], arg_names=["status"], is_varargs=false, abi_name=""));
    links.put("process_exit", "runtime.exit");
    let source: Compiler = Compiler(func_table=functions, compiler_link=links, is_shared=false);
    let errors: Vector(String) = [];
    wir_emit_target_runtime(ref source, ref program, errors);
    if (errors.length() != 0) { print("FAIL: Windows entry lowering: ", errors[0]); return 1; }
    let verify_errors: Vector(String) = verify_wir(program);
    if (verify_errors.length() != 0) { print("FAIL: Windows entry verification: ", verify_errors[0]); return 1; }
    if (wir_find_global(program, "_fltused") == NO_WIR_GLOBAL || wir_find_function(program, "__main") == NO_WIR_FUNC || wir_find_function(program, "mainCRTStartup") == NO_WIR_FUNC) {
        print("FAIL: Windows ABI symbols were not emitted");
        return 1;
    }

    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) { print("FAIL: Windows entry LLVM emission failed"); return 1; }
    if (emitted.errors.length() != 0 || !entry_contains(emitted.text, "define void @mainCRTStartup()") || !entry_contains(emitted.text, "call i32 @main()") || !entry_contains(emitted.text, "call void @runtime.exit")) {
        print("FAIL: Windows entry point was lost in LLVM emission");
        return 1;
    }
    if (!entry_contains(emitted.text, "define ptr @memcpy") || !entry_contains(emitted.text, "define ptr @memmove") || !entry_contains(emitted.text, "define ptr @memset") || !entry_contains(emitted.text, "module asm \".globl ___chkstk_ms\"")) {
        print("FAIL: Windows freestanding support was not emitted");
        return 1;
    }
    print("PASS: WIR Windows entry point");
    return 0;
}
