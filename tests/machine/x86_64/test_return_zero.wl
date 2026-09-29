// Test: X86_64_RETURN_ZERO
// File: tests/machine/x86_64/test_return_zero.wl
// Focus: Lower a minimal WIR function directly to Windows x86_64 machine code.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "main", [], int_type, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let zero: WirValueID = wir_const_int(ref program, int_type, UInt128(0U));
    wir_append(ref program, entry, WirOpcode.Return, program.void_type, [zero], [], no_wir_location());

    let wir_text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: could not print WIR");
        return 1;
    }
    let lowered: X86LoweringResult = x86_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: x86_64 lowering failed: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object_for_text("main", lowered.bytes)?;
    catch(err) {
        print("FAIL: could not write COFF object");
        return 1;
    }

    print("WIR-BEGIN");
    print(wir_text);
    print("WIR-END");

    print("BYTES-BEGIN");
    let i = 0;
    while (i < lowered.bytes.length()) {
        print(Int(lowered.bytes[i]));
        i++;
    }
    print("BYTES-END");

    print("OBJECT-BEGIN");
    i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i += 1;
    }
    print("OBJECT-END");
    print("PASS: Zero return lowering");
    return 0;
}
