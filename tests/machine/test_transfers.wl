// Test: NATIVE_TRANSFERS
// File: tests/machine/test_transfers.wl
// Focus: Large copies, partial tails, indirect results and call-live scalar spills.

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
import A64Register from "../../src/compiler/machine/aarch64/model.wl"
import a64_new_code_buffer from "../../src/compiler/machine/aarch64/encoder.wl"
import a64_copy_memory, a64_zero_memory from "../../src/compiler/machine/aarch64/memory.wl"


func build() -> WirModule {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let byte = wir_unsigned_int_type(ref program, 8);
    let long = wir_signed_int_type(ref program, 64);
    let sizes: Vector(Int) = [65, 97, 257, 4096];
    for (let i = 0; i < sizes.length(); i++) {
        let array = wir_array_type(ref program, byte, UInt64(sizes[i]));
        let pointer = wir_pointer_type(ref program, array);
        let copy = wir_add_function(ref program, "copy" + sizes[i], [wir_param("dst", pointer), wir_param("src", pointer)], program.void_type, false, WirLinkage.Exported, WirABI.C);
        let block = wir_add_block(ref program, copy, "entry", []);
        let params = program.arena.functions[wir_id_index(UInt32(copy))].parameters;
        let value = wir_load(ref program, block, params[1], "bytes", no_wir_location());
        wir_store(ref program, block, value, params[0], no_wir_location());
        wir_return(ref program, block, NO_WIR_VALUE, no_wir_location());

        let clear = wir_add_function(ref program, "zero" + sizes[i], [wir_param("dst", pointer)], program.void_type, false, WirLinkage.Exported, WirABI.C);
        block = wir_add_block(ref program, clear, "entry", []);
        let dst = program.arena.functions[wir_id_index(UInt32(clear))].parameters[0];
        wir_store(ref program, block, wir_const_zero(ref program, array), dst, no_wir_location());
        wir_return(ref program, block, NO_WIR_VALUE, no_wir_location());
    }

    let bytes = wir_array_type(ref program, byte, 257UL);
    let record = wir_struct_type(ref program, [bytes]);
    let echo = wir_add_function(ref program, "echo257", [wir_param("value", record)], record, false, WirLinkage.Internal, WirABI.C);
    let entry = wir_add_block(ref program, echo, "entry", []);
    wir_return(ref program, entry, program.arena.functions[wir_id_index(UInt32(echo))].parameters[0], no_wir_location());

    let wrapper = wir_add_function(ref program, "roundtrip257", [wir_param("value", record)], record, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, wrapper, "entry", []);
    let arg = program.arena.functions[wir_id_index(UInt32(wrapper))].parameters[0];
    let result = wir_call(ref program, entry, wir_function_value(ref program, echo), [arg], "echoed", no_wir_location());
    wir_return(ref program, entry, result, no_wir_location());

    let byte_pointer = wir_pointer_type(ref program, byte);
    let signature: Vector(WirParam) = [];
    for (let a = 0; a < 8; a++) { signature.append(wir_param("arg" + a, long)); }
    signature.append(wir_param("tail", long));
    signature.append(wir_param("name", byte_pointer));
    signature.append(wir_param("record", record));
    let mixed = wir_add_function(ref program, "mixed_stack", signature, long, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, mixed, "entry", []);
    let params = program.arena.functions[wir_id_index(UInt32(mixed))].parameters;
    let name_byte = wir_cast(ref program, entry, wir_load(ref program, entry, params[9], "name", no_wir_location()), long, "name.long", no_wir_location());
    let data = wir_field(ref program, entry, params[10], 0, "data", no_wir_location());
    let first_byte = wir_index(ref program, entry, data, wir_const_int(ref program, long, UInt128(0U)), "first", no_wir_location());
    let first_long = wir_cast(ref program, entry, first_byte, long, "first.long", no_wir_location());
    let total = wir_binary(ref program, entry, WirOpcode.Add, long, params[8], name_byte, "tail.name", no_wir_location());
    total = wir_binary(ref program, entry, WirOpcode.Add, long, total, first_long, "total", no_wir_location());
    wir_return(ref program, entry, total, no_wir_location());

    let barrier = wir_add_function(ref program, "transfer_barrier", [], long, false, WirLinkage.External, WirABI.C);
    let longs = wir_array_type(ref program, long, 20UL);
    let input_type = wir_pointer_type(ref program, longs);
    let pressure = wir_add_function(ref program, "spill_sum", [wir_param("input", input_type)], long, false, WirLinkage.Exported, WirABI.C);
    entry = wir_add_block(ref program, pressure, "entry", []);
    let input = program.arena.functions[wir_id_index(UInt32(pressure))].parameters[0];
    let loaded: Vector(WirValueID) = [];
    for (let j = 0; j < 20; j++) {
        let address = wir_index_address(ref program, entry, input, wir_const_int(ref program, long, UInt128(UInt32(j))), "address", no_wir_location());
        loaded.append(wir_load(ref program, entry, address, "loaded", no_wir_location()));
    }
    let sum = wir_call(ref program, entry, wir_function_value(ref program, barrier), [], "barrier", no_wir_location());
    for (let k = 0; k < loaded.length(); k++) {
        sum = wir_binary(ref program, entry, WirOpcode.Add, long, sum, loaded[k], "sum", no_wir_location());
    }
    wir_return(ref program, entry, sum, no_wir_location());
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
    let code = a64_new_code_buffer();
    if (!a64_copy_memory(ref code, A64Register.X0, 3, A64Register.X1, 1, 4096, A64Register.X9) ||
        !a64_zero_memory(ref code, A64Register.X0, 3, 4096) || code.bytes.length() > 256) {
        print("FAIL: large transfers grew with their byte count");
        return 1;
    }
    if (a64_copy_memory(ref code, A64Register.X0, 0, A64Register.X1, 0, -1, A64Register.X9) ||
        a64_zero_memory(ref code, A64Register.X0, 2147483640, 65)) {
        print("FAIL: invalid transfer bounds were accepted");
        return 1;
    }

    let program = build();
    let errors = verify_wir(program);
    if (errors.length() != 0) { print("FAIL: transfer WIR: ", errors[0]); return 1; }
    let win = x86_lower_module(ref program);
    if (win.errors.length() != 0) { print("FAIL: Win64 transfers: ", win.errors[0]); return 1; }
    let bytes = coff_object(X86Object(sections=win.sections, symbols=win.symbols, relocations=win.relocations))?;
    catch(err) { return 1; }
    if (!save("transfers_win.obj", bytes)) { return 1; }

    // an unused function's unresolved call must disappear with its ELF text section.
    let missing = wir_add_function(ref program, "transfer_missing", [], program.void_type, false, WirLinkage.External, WirABI.C);
    let unused = wir_add_function(ref program, "unused_transfer", [], program.void_type, false, WirLinkage.Exported, WirABI.C);
    let block = wir_add_block(ref program, unused, "entry", []);
    wir_call(ref program, block, wir_function_value(ref program, missing), [], "", no_wir_location());
    wir_return(ref program, block, NO_WIR_VALUE, no_wir_location());

    program.target = "x86_64-unknown-linux-gnu";
    let linux = x86_lower_module(ref program);
    if (linux.errors.length() != 0) { print("FAIL: SysV transfers: ", linux.errors[0]); return 1; }
    bytes = elf_object(X86Object(sections=linux.sections, symbols=linux.symbols, relocations=linux.relocations))?;
    catch(err) { return 1; }
    if (!save("transfers_x64.o", bytes)) { return 1; }

    program.target = "aarch64-unknown-linux-gnu";
    let arm = a64_lower_module(ref program);
    if (arm.errors.length() != 0) { print("FAIL: AArch64 transfers: ", arm.errors[0]); return 1; }
    bytes = a64_elf_object(A64Object(sections=arm.sections, symbols=arm.symbols, relocations=arm.relocations))?;
    catch(err) { return 1; }
    if (!save("transfers_a64.o", bytes)) { return 1; }
    print("PASS: native transfers and call-live spills");
    return 0;
}
