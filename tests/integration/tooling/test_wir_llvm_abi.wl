// Test: WIR_LLVM_ABI
// File: tests/integration/tooling/test_wir_llvm_abi.wl
// Focus: Preserving foreign call conventions and the ARC runtime boundary.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func check_x64_abi() -> Bool {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let object_type: WirTypeID = wir_pointer_type(ref program, program.void_type);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let c_id: WirFuncID = wir_add_function(ref program, "c_func", [wir_param("value", object_type)], i32_type, false, WirLinkage.External, WirABI.C);
    let system_id: WirFuncID = wir_add_function(ref program, "system_func", [wir_param("value", i32_type)], object_type, false, WirLinkage.External, WirABI.System);
    let caller_id: WirFuncID = wir_add_function(ref program, "caller", [wir_param("object", object_type)], i32_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, caller_id, "entry", []);
    let caller: WirFunction = program.arena.functions[wir_id_index(UInt32(caller_id))];
    wir_retain(ref program, entry, caller.parameters[0], no_wir_location());
    wir_call(ref program, entry, wir_function_value(program, system_id), [wir_const_int(ref program, i32_type, UInt128(7U))], "handle", no_wir_location());
    let result: WirValueID = wir_call(ref program, entry, wir_function_value(program, c_id), [caller.parameters[0]], "result", no_wir_location());
    wir_release(ref program, entry, caller.parameters[0], no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());

    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) { return false; }
    if (emitted.errors.length() != 0) { return false; }
    let expected: String = "target triple = \"x86_64-pc-windows-msvc\"\n\ndeclare void @__wl_retain(ptr)\ndeclare void @__wl_release(ptr)\n\ndeclare ccc i32 @c_func(ptr)\n\ndeclare win64cc ptr @system_func(i32)\n\ndefine internal i32 @caller(ptr %v5) {\nb1:\n  call void @__wl_retain(ptr %v5)\n  %v8 = call win64cc ptr @system_func(i32 7)\n  %v9 = call ccc i32 @c_func(ptr %v5)\n  call void @__wl_release(ptr %v5)\n  ret i32 %v9\n}\n";
    return emitted.text == expected;
}

func check_indirect_c_abi() -> Bool {
    let program: WirModule = new_wir_module("x86_64-unknown-linux-gnu", 64);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let callee_type: WirTypeID = wir_function_type(ref program, [i32_type], i32_type, false, WirABI.C);
    let caller_id: WirFuncID = wir_add_function(ref program, "call_indirect", [wir_param("callee", callee_type)], i32_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, caller_id, "entry", []);
    let caller: WirFunction = program.arena.functions[wir_id_index(UInt32(caller_id))];
    let result: WirValueID = wir_call(ref program, entry, caller.parameters[0], [wir_const_int(ref program, i32_type, UInt128(9U))], "result", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());

    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) { return false; }
    if (emitted.errors.length() != 0) { return false; }
    let expected: String = "target triple = \"x86_64-unknown-linux-gnu\"\n\ndefine internal i32 @call_indirect(ptr %v1) {\nb1:\n  %v4 = call ccc i32 %v1(i32 9)\n  ret i32 %v4\n}\n";
    return emitted.text == expected;
}

func check_x86_system_abi() -> Bool {
    let program: WirModule = new_wir_module("i686-pc-windows-msvc", 32);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    wir_add_function(ref program, "system_func", [wir_param("value", i32_type)], i32_type, false, WirLinkage.External, WirABI.System);
    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) { return false; }
    if (emitted.errors.length() != 0) { return false; }
    return emitted.text == "target triple = \"i686-pc-windows-msvc\"\n\ndeclare x86_stdcallcc i32 @system_func(i32)\n";
}

func main() -> Int {
    if (!check_x64_abi()) {
        print("FAIL: x64 foreign ABI or ARC boundary was not preserved");
        return 1;
    }
    if (!check_x86_system_abi()) {
        print("FAIL: x86 system ABI was not preserved");
        return 1;
    }
    if (!check_indirect_c_abi()) {
        print("FAIL: indirect C ABI was not preserved");
        return 1;
    }
    print("PASS: WIR LLVM ABI");
    return 0;
}
