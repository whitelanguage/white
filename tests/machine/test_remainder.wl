// Test: NATIVE_REMAINDER
// File: tests/machine/test_remainder.wl
// Focus: Lower raw f32/f64 remainders through shared helpers and native object writers.

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


func build(level: String) -> WirModule {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    for (let bits = 32; bits <= 64; bits += 32) {
        let type = wir_float_type(ref program, bits);
        let function = wir_add_function(ref program, "rem" + bits, [wir_param("x", type), wir_param("y", type)], type, false, WirLinkage.Exported, WirABI.C);
        let params = program.arena.functions[wir_id_index(UInt32(function))].parameters;
        let block = wir_add_block(ref program, function, "entry", []);
        let result = wir_binary(ref program, block, WirOpcode.FloatRemainder, type, params[0], params[1], "remainder", no_wir_location());
        wir_return(ref program, block, result, no_wir_location());
    }
    // a user-supplied symbol cannot be mistaken for the generated helper.
    wir_add_function(ref program, "$machine.frem.f64", [], program.void_type, false, WirLinkage.External, WirABI.C);
    optimize_wir(ref program, level);
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
    let levels: Vector(String) = ["-O0", "-Oz"];
    for (let i = 0; i < levels.length(); i++) {
        let program = build(levels[i]);
        let win = x86_lower_module(ref program);
        let errors = verify_wir(program);
        if (win.errors.length() != 0 || errors.length() != 0 || program.arena.functions.length() != 5) {
            if (win.errors.length() != 0) { print(win.errors[0]); }
            for (let j = 0; j < errors.length(); j++) { print(errors[j]); }
            print("FAIL: native remainder legalization");
            return 1;
        }
        let bytes = coff_object(X86Object(sections=win.sections, symbols=win.symbols, relocations=win.relocations))?;
        catch(err) { return 1; }
        if (!save("remainder_win" + i + ".obj", bytes)) { return 1; }

        program.target = "x86_64-unknown-linux-gnu";
        let linux = x86_lower_module(ref program);
        if (linux.errors.length() != 0) { print(linux.errors[0]); return 1; }
        bytes = elf_object(X86Object(sections=linux.sections, symbols=linux.symbols, relocations=linux.relocations))?;
        catch(err) { return 1; }
        if (!save("remainder_x64" + i + ".o", bytes)) { return 1; }

        program.target = "aarch64-unknown-linux-gnu";
        let arm = a64_lower_module(ref program);
        if (arm.errors.length() != 0) { print(arm.errors[0]); return 1; }
        bytes = a64_elf_object(A64Object(sections=arm.sections, symbols=arm.symbols, relocations=arm.relocations))?;
        catch(err) { return 1; }
        if (!save("remainder_a64" + i + ".o", bytes)) { return 1; }
        if (program.arena.functions.length() != 5) { return 1; }
    }
    print("PASS: native floating remainder");
    return 0;
}
