// Test: NATIVE_CONSTANTS
// File: tests/machine/test_constants.wl
// Focus: Share nested aggregate, edge, call and return constants across native targets.

import "file"
import * from "../../src/compiler/wir/model.wl"
import * from "../../src/compiler/wir/builder.wl"
import verify_wir from "../../src/compiler/wir/verify.wl"
import x86_lower_module from "../../src/compiler/machine/x86_64/module.wl"
import X86Object from "../../src/compiler/machine/x86_64/model.wl"
import coff_object from "../../src/compiler/machine/x86_64/coff.wl"
import elf_object from "../../src/compiler/machine/x86_64/elf.wl"
import a64_lower_module from "../../src/compiler/machine/aarch64/module.wl"
import A64Object from "../../src/compiler/machine/aarch64/model.wl"
import a64_elf_object from "../../src/compiler/machine/aarch64/elf.wl"


func build() -> WirModule {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int = wir_signed_int_type(ref program, 32);
    let long = wir_signed_int_type(ref program, 64);
    let byte = wir_unsigned_int_type(ref program, 8);
    let small = wir_struct_type(ref program, [int]);
    let pair = wir_struct_type(ref program, [byte, long]);
    let array = wir_array_type(ref program, pair, 2UL);
    let nested = wir_struct_type(ref program, [byte, array]);
    let answer = wir_const_int(ref program, long, UInt128(42U));
    let contents = wir_const_aggregate(ref program, pair, [wir_const_int(ref program, byte, UInt128(9U)), answer]);
    let list = wir_const_aggregate(ref program, array, [contents, contents]);
    let value = wir_const_aggregate(ref program, nested, [wir_const_int(ref program, byte, UInt128(7U)), list]);

    let identity = wir_add_function(ref program, "const_identity", [wir_param("value", pair)], pair, false, WirLinkage.Internal, WirABI.C);
    let entry = wir_add_block(ref program, identity, "entry", []);
    wir_return(ref program, entry, program.arena.functions[wir_id_index(UInt32(identity))].parameters[0], no_wir_location());

    let returned = wir_add_function(ref program, "const_return", [], pair, false, WirLinkage.Internal, WirABI.C);
    entry = wir_add_block(ref program, returned, "entry", []);
    wir_return(ref program, entry, contents, no_wir_location());

    let caller = wir_add_function(ref program, "const_call", [], long, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, caller, "entry", []);
    let received = wir_call(ref program, entry, wir_function_value(ref program, returned), [], "received", no_wir_location());
    let echoed = wir_call(ref program, entry, wir_function_value(ref program, identity), [contents], "echoed", no_wir_location());
    let left = wir_field(ref program, entry, received, 1, "left", no_wir_location());
    let right = wir_field(ref program, entry, echoed, 1, "right", no_wir_location());
    let sum = wir_binary(ref program, entry, WirOpcode.Add, long, left, right, "sum", no_wir_location());
    wir_return(ref program, entry, sum, no_wir_location());

    let edge = wir_add_function(ref program, "const_edge", [], long, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, edge, "entry", []);
    let exit = wir_add_block(ref program, edge, "exit", [wir_param("value", nested)]);
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(exit, [value])], no_wir_location());
    let param = program.arena.blocks[wir_id_index(UInt32(exit))].parameters[0];
    let items = wir_field(ref program, exit, param, 1, "items", no_wir_location());
    let second = wir_index(ref program, exit, items, wir_const_int(ref program, int, UInt128(1U)), "second", no_wir_location());
    wir_return(ref program, exit, wir_field(ref program, exit, second, 1, "answer", no_wir_location()), no_wir_location());

    let small_return = wir_add_function(ref program, "const_small", [], small, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, small_return, "entry", []);
    wir_return(ref program, entry, wir_const_aggregate(ref program, small, [wir_const_int(ref program, int, UInt128(42U))]), no_wir_location());

    let pointer = wir_pointer_type(ref program, int);
    let global = wir_add_global(ref program, "const_data", int, wir_const_int(ref program, int, UInt128(42U)), WirLinkage.Internal, true);
    let record = wir_struct_type(ref program, [pointer, pair]);
    let address = wir_const_address(ref program, pointer, wir_global_value(ref program, global), 0L);
    let pointer_value = wir_const_aggregate(ref program, record, [address, contents]);
    let load = wir_add_function(ref program, "const_pointer", [], int, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, load, "entry", []);
    let data = wir_field(ref program, entry, pointer_value, 0, "data", no_wir_location());
    wir_return(ref program, entry, wir_load(ref program, entry, data, "loaded", no_wir_location()), no_wir_location());

    let bytes_type = wir_array_type(ref program, byte, 4UL);
    let raw = wir_const_bytes(ref program, bytes_type, "\0Aé");
    let bytes_function = wir_add_function(ref program, "const_bytes", [], byte, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, bytes_function, "entry", []);
    let bytes_exit = wir_add_block(ref program, bytes_function, "exit", [wir_param("value", bytes_type)]);
    wir_append(ref program, entry, WirOpcode.Jump, program.void_type, [], [wir_edge(bytes_exit, [raw])], no_wir_location());
    let bytes_param = program.arena.blocks[wir_id_index(UInt32(bytes_exit))].parameters[0];
    wir_return(ref program, bytes_exit, wir_index(ref program, bytes_exit, bytes_param, wir_const_int(ref program, int, UInt128(3U)), "byte", no_wir_location()), no_wir_location());

    let nested_bytes = wir_struct_type(ref program, [byte, bytes_type]);
    let raw_record = wir_const_aggregate(ref program, nested_bytes, [wir_const_int(ref program, byte, UInt128(7U)), raw]);
    let nested_function = wir_add_function(ref program, "const_nested_bytes", [], byte, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, nested_function, "entry", []);
    let bytes_field = wir_field(ref program, entry, raw_record, 1, "raw", no_wir_location());
    wir_return(ref program, entry, wir_index(ref program, entry, bytes_field, wir_const_int(ref program, int, UInt128(2U)), "byte", no_wir_location()), no_wir_location());

    return program;
}

func save(path: String, bytes: Vector(Byte)) -> Bool {
    let output = file.create(path)?;
    catch(err) { return false; }
    output.write_bytes(bytes)?;
    catch(err) { return false; }
    output.close();
    return true;
}

func main() -> Int {
    let program = build();
    let errors = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: constant WIR: ", errors[0]);
        return 1;
    }

    let win = x86_lower_module(ref program);
    if (win.errors.length() != 0) {
        print("FAIL: Win64 constants: ", win.errors[0]);
        return 1;
    }
    let bytes = coff_object(X86Object(sections=win.sections, symbols=win.symbols, relocations=win.relocations))?;
    catch(err) { return 1; }
    if (!save("constants_win.obj", bytes)) { return 1; }

    program.target = "x86_64-unknown-linux-gnu";
    let linux = x86_lower_module(ref program);
    if (linux.errors.length() != 0) {
        print("FAIL: SysV constants: ", linux.errors[0]);
        return 1;
    }
    bytes = elf_object(X86Object(sections=linux.sections, symbols=linux.symbols, relocations=linux.relocations))?;
    catch(err) { return 1; }
    if (!save("constants_x86.o", bytes)) { return 1; }

    program.target = "aarch64-unknown-linux-gnu";
    let arm = a64_lower_module(ref program);
    if (arm.errors.length() != 0) {
        print("FAIL: AArch64 constants: ", arm.errors[0]);
        return 1;
    }
    bytes = a64_elf_object(A64Object(sections=arm.sections, symbols=arm.symbols, relocations=arm.relocations))?;
    catch(err) { return 1; }
    if (!save("constants_a64.o", bytes)) { return 1; }

    print("PASS: native aggregate constants");
    return 0;
}
