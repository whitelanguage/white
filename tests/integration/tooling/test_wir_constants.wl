// Test: WIR_CONSTANTS
// File: tests/integration/tooling/test_wir_constants.wl
// Focus: Representing static bytes, aggregate constants, symbol addresses, relocations, and alignment.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let u8_type: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let byte_pointer: WirTypeID = wir_pointer_type(ref program, u8_type);
    let bytes_type: WirTypeID = wir_array_type(ref program, u8_type, UIntSize(6U));
    let string_type: WirTypeID = wir_declare_struct(ref program, "String");
    wir_define_struct(ref program, string_type, [byte_pointer, i32_type, i32_type]);

    let bytes: WirValueID = wir_const_bytes(ref program, bytes_type, "White" + '\0');
    let bytes_global: WirGlobalID = wir_add_aligned_global(ref program, ".str.bytes", bytes_type, bytes, WirLinkage.Private, true, 1);
    let address: WirValueID = wir_const_address(ref program, byte_pointer, wir_global_value(program, bytes_global), 0L);
    let tail: WirValueID = wir_const_address(ref program, byte_pointer, wir_global_value(program, bytes_global), 2L);
    wir_add_global(ref program, ".str.tail", byte_pointer, tail, WirLinkage.Private, true);
    let length: WirValueID = wir_const_int(ref program, i32_type, UInt128(5U));
    let string: WirValueID = wir_const_aggregate(ref program, string_type, [address, length, length]);
    wir_add_aligned_global(ref program, ".str", string_type, string, WirLinkage.Exported, true, 8);
    let buffer_type: WirTypeID = wir_array_type(ref program, u8_type, UIntSize(4096U));
    let buffer: WirValueID = wir_const_zero(ref program, buffer_type);
    wir_add_aligned_global(ref program, "buffer", buffer_type, buffer, WirLinkage.Private, false, 16);

    let text: String = print_wir(program)?;
    catch(err) { print("FAIL: static WIR could not be printed"); return 1; }
    let expected: String = "type !String = {ptr<u8>, i32, i32}\n\nconst @.str.bytes:[u8; 6] align 1 = b\"White\\00\"\nconst @.str.tail:ptr<u8> = addr @.str.bytes + 2\npub const @.str:!String align 8 = {addr @.str.bytes, 5, 5}\nglobal @buffer:[u8; 4096] align 16 = zero\n";
    if (text != expected) { print("FAIL: static WIR text is not stable"); print(text); return 1; }

    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) { print("FAIL: static LLVM emission failed"); return 1; }
    if (emitted.errors.length() != 0) { print("FAIL: static WIR was rejected: ", emitted.errors[0]); return 1; }
    let expected_llvm: String = "target triple = \"x86_64-pc-windows-msvc\"\n\n%wir.t7 = type { ptr, i32, i32 }\n\n@.str.bytes = private constant [6 x i8] c\"White\\00\", align 1\n@.str.tail = private constant ptr getelementptr (i8, ptr @.str.bytes, i64 2)\n@.str = constant %wir.t7 {ptr @.str.bytes, i32 5, i32 5}, align 8\n@buffer = private global [4096 x i8] zeroinitializer, align 16\n\n";
    if (emitted.text != expected_llvm) { print("FAIL: static LLVM output is not stable"); print(emitted.text); return 1; }

    print("PASS: WIR static constants");
    return 0;
}
