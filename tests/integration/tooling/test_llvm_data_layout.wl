// Test: LLVM_DATA_LAYOUT
// File: tests/integration/tooling/test_llvm_data_layout.wl
// Focus: Target metadata is present before LLVM parses aggregate loads and deferred types.

import llvm_target_data_layout, llvm_header_end from "../../../src/compiler/backend/llvm.wl"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"


func check(target: String, bits: Int, expected: String) -> Bool {
    if (llvm_target_data_layout(target) != expected) { return false; }
    let program = new_wir_module(target, bits);
    let type = wir_signed_int_type(ref program, 32);
    let function = wir_add_function(ref program, "value", [], type, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    wir_return(ref program, entry, wir_const_int(ref program, type, UInt128(0U)), no_wir_location());
    let emitted = emit_wir_llvm(program)?;
    catch(err) { return false; }
    let header: String = "target datalayout = \"" + expected + "\"\ntarget triple = \"" + target + "\"\n";
    return emitted.errors.length() == 0 && emitted.text.starts_with(header) && llvm_header_end(emitted.text) == header.length();
}

func main() -> Int {
    if (!check("armv7-unknown-linux-gnueabihf", 32, "e-m:e-p:32:32-Fi8-i64:64-v128:64:128-a:0:32-n32-S64") ||
        !check("i686-pc-windows-msvc", 32, "e-m:x-p:32:32-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32-a:0:32-S32") ||
        !check("i686-unknown-linux-gnu", 32, "e-m:e-p:32:32-p270:32:32-p271:32:32-p272:64:64-i128:128-f64:32:64-f80:32-n8:16:32-S128") ||
        !check("x86_64-pc-windows-msvc", 64, "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128") ||
        !check("x86_64-unknown-linux-gnu", 64, "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128") ||
        !check("aarch64-unknown-linux-gnu", 64, "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32") ||
        !check("x86_64-apple-darwin", 64, "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128") ||
        !check("arm64-apple-darwin", 64, "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32")) {
        print("FAIL: LLVM target data layout");
        return 1;
    }
    if (llvm_header_end("target triple = \"test\"\n\n%record = type { i32 }\n") != 23) {
        print("FAIL: legacy LLVM header boundary");
        return 1;
    }
    print("PASS: LLVM target data layout");
    return 0;
}
