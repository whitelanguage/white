// Test: X86_64_GLOBALS
// File: tests/machine/x86_64/test_globals.wl
// Focus: Link readonly bytes, writable globals, and address relocations without a CRT.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import X86Object, X86CodeSection, X86Symbol from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"

func check(ref program: WirModule, function: WirFuncID, block: WirBlockID, actual: WirValueID, expected: WirValueID, code: Int) -> WirBlockID {
    let next: WirBlockID = wir_add_block(ref program, function, "next_" + code, []);
    let fail: WirBlockID = wir_add_block(ref program, function, "fail_" + code, []);
    let condition: WirValueID = wir_append(ref program, block, WirOpcode.Equal, program.bool_type, [actual, expected], [], no_wir_location());
    wir_append(ref program, block, WirOpcode.Branch, program.void_type, [condition], [wir_edge(next, []), wir_edge(fail, [])], no_wir_location());
    wir_return(ref program, fail, wir_const_int(ref program, wir_signed_int_type(ref program, 32), UInt128(UInt32(code))), no_wir_location());
    return next;
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let u8: WirTypeID = wir_unsigned_int_type(ref program, 8);
    let i32: WirTypeID = wir_signed_int_type(ref program, 32);
    let u64: WirTypeID = wir_unsigned_int_type(ref program, 64);
    let pointer: WirTypeID = wir_pointer_type(ref program, u8);
    let bytes_type: WirTypeID = wir_array_type(ref program, u8, UIntSize(5));
    let bytes_id: WirGlobalID = wir_add_global(ref program, "readonly_utf8_bytes", bytes_type, wir_const_bytes(ref program, bytes_type, "你" + String('\0') + "x"), WirLinkage.Internal, true);
    let bytes_address: WirValueID = wir_global_value(program, bytes_id);
    let counter_id: WirGlobalID = wir_add_aligned_global(ref program, "writable_counter", u64, wir_const_int(ref program, u64, UInt128(4294967299UL)), WirLinkage.Exported, false, 32);
    let record_type: WirTypeID = wir_struct_type(ref program, [u8, u64, pointer]);
    let record_value: WirValueID = wir_const_aggregate(ref program, record_type, [wir_const_int(ref program, u8, UInt128(7U)), wir_const_int(ref program, u64, UInt128(9223372036854775808UL)), wir_const_address(ref program, pointer, bytes_address, 3L)]);
    let record_id: WirGlobalID = wir_add_global(ref program, "padded_record_with_pointer", record_type, record_value, WirLinkage.Internal, true);
    let zero_id: WirGlobalID = wir_add_global(ref program, "zero_counter", u64, wir_const_zero(ref program, u64), WirLinkage.Internal, false);
    let external_id: WirGlobalID = wir_add_global(ref program, "external_counter", u64, NO_WIR_VALUE, WirLinkage.External, false);
    let array_type: WirTypeID = wir_array_type(ref program, i32, UIntSize(3));
    let array_id: WirGlobalID = wir_add_global(ref program, "integer_array", array_type, wir_const_aggregate(ref program, array_type, [wir_const_int(ref program, i32, UInt128(10U)), wir_const_int(ref program, i32, UInt128(20U)), wir_const_int(ref program, i32, UInt128(30U))]), WirLinkage.Internal, true);

    let helper: WirFuncID = wir_add_function(ref program, "read_counter", [], u64, false, WirLinkage.Internal, WirABI.White);
    let helper_entry: WirBlockID = wir_add_block(ref program, helper, "entry", []);
    wir_return(ref program, helper_entry, wir_load(ref program, helper_entry, wir_global_value(program, counter_id), "counter", no_wir_location()), no_wir_location());
    let host: WirFuncID = wir_add_function(ref program, "GetCurrentProcessId", [], i32, false, WirLinkage.External, WirABI.System);
    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32, false, WirLinkage.Exported, WirABI.White);
    let block: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let value: WirValueID = wir_call(ref program, block, wir_function_value(program, helper), [], "counter", no_wir_location());
    block = check(ref program, main_id, block, value, wir_const_int(ref program, u64, UInt128(4294967299UL)), 1);
    wir_store(ref program, block, wir_const_int(ref program, u64, UInt128(55U)), wir_global_value(program, counter_id), no_wir_location());
    value = wir_call(ref program, block, wir_function_value(program, helper), [], "counter", no_wir_location());
    block = check(ref program, main_id, block, value, wir_const_int(ref program, u64, UInt128(55U)), 2);
    let first: WirValueID = wir_index_address(ref program, block, bytes_address, wir_const_int(ref program, i32, UInt128(0U)), "first_byte", no_wir_location());
    block = check(ref program, main_id, block, wir_load(ref program, block, first, "first", no_wir_location()), wir_const_int(ref program, u8, UInt128(228U)), 3);
    let record_address: WirValueID = wir_global_value(program, record_id);
    let wide: WirValueID = wir_field_address(ref program, block, record_address, 1, "wide", no_wir_location());
    block = check(ref program, main_id, block, wir_load(ref program, block, wide, "wide_value", no_wir_location()), wir_const_int(ref program, u64, UInt128(9223372036854775808UL)), 4);
    let pointer_field: WirValueID = wir_field_address(ref program, block, record_address, 2, "pointer_field", no_wir_location());
    let text: WirValueID = wir_load(ref program, block, pointer_field, "text", no_wir_location());
    block = check(ref program, main_id, block, wir_load(ref program, block, text, "embedded_nul", no_wir_location()), wir_const_int(ref program, u8, UInt128(0U)), 5);
    let fourth: WirValueID = wir_const_address(ref program, pointer, bytes_address, 4L);
    block = check(ref program, main_id, block, wir_load(ref program, block, fourth, "last_byte", no_wir_location()), wir_const_int(ref program, u8, UInt128(120U)), 6);
    block = check(ref program, main_id, block, wir_load(ref program, block, wir_global_value(program, zero_id), "zero", no_wir_location()), wir_const_int(ref program, u64, UInt128(0U)), 7);
    let last: WirValueID = wir_index_address(ref program, block, wir_global_value(program, array_id), wir_const_int(ref program, i32, UInt128(2U)), "last", no_wir_location());
    block = check(ref program, main_id, block, wir_load(ref program, block, last, "last_value", no_wir_location()), wir_const_int(ref program, i32, UInt128(30U)), 8);
    let pid: WirValueID = wir_call(ref program, block, wir_function_value(program, host), [], "pid", no_wir_location());
    let exists: WirValueID = wir_append(ref program, block, WirOpcode.NotEqual, program.bool_type, [pid, wir_const_int(ref program, i32, UInt128(0U))], [], no_wir_location());
    block = check(ref program, main_id, block, exists, wir_const_bool(ref program, true), 9);
    let external_value: WirValueID = wir_load(ref program, block, wir_global_value(program, external_id), "external_value", no_wir_location());
    block = check(ref program, main_id, block, external_value, wir_const_int(ref program, u64, UInt128(42U)), 10);
    wir_return(ref program, block, wir_const_int(ref program, i32, UInt128(0U)), no_wir_location());
    // a small native entry keeps the linked test independent of the C startup objects
    let exit_id: WirFuncID = wir_add_function(ref program, "ExitProcess", [WirParam(name="status", type_id=i32)], program.void_type, false, WirLinkage.External, WirABI.System);
    let startup: WirFuncID = wir_add_function(ref program, "mainCRTStartup", [], program.void_type, false, WirLinkage.Exported, WirABI.White);
    let startup_entry: WirBlockID = wir_add_block(ref program, startup, "entry", []);
    let status: WirValueID = wir_call(ref program, startup_entry, wir_function_value(program, main_id), [], "status", no_wir_location());
    wir_call(ref program, startup_entry, wir_function_value(program, exit_id), [status], "", no_wir_location());
    wir_return(ref program, startup_entry, NO_WIR_VALUE, no_wir_location());
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: invalid global test: ", errors[0]);
        return 1;
    }
    let lowered: X86ModuleResult = x86_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: global lowering: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.sections.length() != 3) {
        print("FAIL: globals did not produce separate code, readonly data, and writable data");
        return 1;
    }
    let object: Vector(Byte) = coff_object(X86Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: global COFF output");
        return 1;
    }
    // a separate data-only object supplies the external global
    let host_section: X86CodeSection = X86CodeSection(name=".data", bytes=[Byte(42), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0)], alignment=8, executable=false, writable=true);
    let host_object: Vector(Byte) = coff_object(X86Object(sections=[host_section], symbols=[X86Symbol(name="external_counter", section=".data", offset=0U, external=true)], relocations=[]))?;
    catch(err) {
        print("FAIL: external global fixture COFF output");
        return 1;
    }
    print("PASS: x86_64 globals");
    print("OBJECT-BEGIN");
    let i: Int = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i++;
    }
    print("OBJECT-END");
    print("HOST-BEGIN");
    i = 0;
    while (i < host_object.length()) {
        print(Int(host_object[i]));
        i++;
    }
    print("HOST-END");
    return 0;
}
