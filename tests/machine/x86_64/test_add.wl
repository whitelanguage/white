// Test: X86_64_INTEGER_ADD
// File: tests/machine/x86_64/test_add.wl
// Focus: Lower a constant integer expression and preserve its result in a COFF object.

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
    let left: WirValueID = wir_const_int(ref program, int_type, UInt128(40U));
    let right: WirValueID = wir_const_int(ref program, int_type, UInt128(2U));
    let sum: WirValueID = wir_append(ref program, entry, WirOpcode.Add, int_type, [left, right], [], no_wir_location());
    wir_append(ref program, entry, WirOpcode.Return, program.void_type, [sum], [], no_wir_location());

    let wir_text: String = print_wir(program)?;
    catch(e) {
        print("FAIL: could not print WIR");
        return 1;
    }
    let lowered: X86LoweringResult = x86_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: x86_64 lowering failed: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object_for_text("main", lowered.bytes)?;
    catch(e) {
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
        i += 1;
    }
    print("BYTES-END");
    print("OBJECT-BEGIN");
    i = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i += 1;
    }
    print("OBJECT-END");
    print("PASS: Integer addition lowering");
    return 0;
}
