// Test: WIDE_NUMERIC
// File: tests/machine/test_wide_numeric.wl
// Focus: Share i128 Abs and all f32/f64 wide conversions across the three native targets.

import "file"
import * from "../../src/compiler/wir/model.wl"
import * from "../../src/compiler/wir/builder.wl"
import verify_wir from "../../src/compiler/wir/verify.wl"
import optimize_wir from "../../src/compiler/wir/optimize.wl"
import x86_lower_module from "../../src/compiler/machine/x86_64/module.wl"
import X86Object from "../../src/compiler/machine/x86_64/model.wl"
import coff_object from "../../src/compiler/machine/x86_64/coff.wl"
import elf_object from "../../src/compiler/machine/x86_64/elf.wl"
import a64_lower_module from "../../src/compiler/machine/aarch64/module.wl"
import A64Object from "../../src/compiler/machine/aarch64/model.wl"
import a64_elf_object from "../../src/compiler/machine/aarch64/elf.wl"
import machine_lower_wide_conversions from "../../src/compiler/machine/numeric.wl"


func build() -> WirModule {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let signed = wir_signed_int_type(ref program, 128);
    let unsigned = wir_unsigned_int_type(ref program, 128);
    for (let bits = 32; bits <= 64; bits += 32) {
        let float = wir_float_type(ref program, bits);
        if (bits == 32) {
            // user symbols sharing the helper prefix must never be selected as helpers
            wir_add_function(ref program, "$machine.convert." + UInt32(signed) + "." + UInt32(float), [], program.void_type, false, WirLinkage.External, WirABI.C);
        }
        let inputs: Vector(WirTypeID) = [signed, unsigned, float, float];
        let outputs: Vector(WirTypeID) = [float, float, signed, unsigned];
        let names: Vector(String) = ["signed_to_", "unsigned_to_", "to_signed_", "to_unsigned_"];
        for (let i = 0; i < inputs.length(); i++) {
            let function = wir_add_function(ref program, names[i] + bits, [wir_param("value", inputs[i])], outputs[i], false, WirLinkage.Exported, WirABI.C);
            let block = wir_add_block(ref program, function, "entry", []);
            let param = program.arena.functions[wir_id_index(UInt32(function))].parameters[0];
            wir_return(ref program, block, wir_cast(ref program, block, param, outputs[i], "converted", no_wir_location()), no_wir_location());
        }
    }
    let absolute = wir_add_function(ref program, "absolute128", [wir_param("value", signed)], signed, false, WirLinkage.Exported, WirABI.C);
    let entry = wir_add_block(ref program, absolute, "entry", []);
    let value = program.arena.functions[wir_id_index(UInt32(absolute))].parameters[0];
    wir_return(ref program, entry, wir_unary(ref program, entry, WirOpcode.Abs, signed, value, "absolute", no_wir_location()), no_wir_location());
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
    let malformed = build();
    let instruction = malformed.arena.instructions[0];
    instruction.operands = [NO_WIR_VALUE];
    malformed.arena.instructions[0] = instruction;
    if (machine_lower_wide_conversions(ref malformed).length() == 0) {
        print("FAIL: malformed wide conversion was accepted");
        return 1;
    }
    let levels: Vector(String) = ["-O0", "-Oz"];
    for (let i = 0; i < levels.length(); i++) {
        let program = build();
        optimize_wir(ref program, levels[i]);
        let win = x86_lower_module(ref program);
        let errors = verify_wir(program);
        if (win.errors.length() != 0 || errors.length() != 0) {
            for (let e = 0; e < win.errors.length(); e++) { print(win.errors[e]); }
            for (let v = 0; v < errors.length(); v++) { print(errors[v]); }
            return 1;
        }
        let count = program.arena.functions.length();
        let bytes = coff_object(X86Object(sections=win.sections, symbols=win.symbols, relocations=win.relocations))?;
        catch(err) { return 1; }
        if (!save("numeric_win" + i + ".obj", bytes)) { return 1; }
        program.target = "x86_64-unknown-linux-gnu";
        let linux = x86_lower_module(ref program);
        if (linux.errors.length() != 0) { print(linux.errors[0]); return 1; }
        bytes = elf_object(X86Object(sections=linux.sections, symbols=linux.symbols, relocations=linux.relocations))?;
        catch(err) { return 1; }
        if (!save("numeric_x64" + i + ".o", bytes)) { return 1; }
        program.target = "aarch64-unknown-linux-gnu";
        let arm = a64_lower_module(ref program);
        if (arm.errors.length() != 0) { print(arm.errors[0]); return 1; }
        errors = verify_wir(program);
        if (errors.length() != 0) { print(errors[0]); return 1; }
        bytes = a64_elf_object(A64Object(sections=arm.sections, symbols=arm.symbols, relocations=arm.relocations))?;
        catch(err) { return 1; }
        if (!save("numeric_a64" + i + ".o", bytes) || program.arena.functions.length() != count) { return 1; }
    }
    print("PASS: native wide numeric legalization");
    return 0;
}
