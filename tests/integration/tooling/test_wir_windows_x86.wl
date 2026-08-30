// Test: WIR_WINDOWS_X86
// File: tests/integration/tooling/test_wir_windows_x86.wl
// Focus: Emitting the freestanding helper symbols required by Windows x86.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func contains(text: String, needle: String) -> Bool {
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
    let program: WirModule = new_wir_module("i686-pc-windows-msvc", 32);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    wir_add_global(ref program, "_fltused", int_type, wir_const_int(ref program, int_type, UInt128(39029U)), WirLinkage.Exported, false);

    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) { print("FAIL: Windows x86 support emission failed"); return 1; }
    if (emitted.errors.length() != 0) { print("FAIL: Windows x86 support was rejected: ", emitted.errors[0]); return 1; }
    if (!contains(emitted.text, "@\"\\01__alldiv\"") || !contains(emitted.text, "@\"\\01__allrem\"") || !contains(emitted.text, "@\"\\01__aulldiv\"") || !contains(emitted.text, "@\"\\01__aullrem\"")) {
        print("FAIL: Windows x86 division helpers were not emitted");
        return 1;
    }
    if (!contains(emitted.text, "module asm \".globl __chkstk\"")) {
        print("FAIL: Windows x86 stack probe was not emitted");
        return 1;
    }
    print("PASS: WIR Windows x86 support");
    return 0;
}
