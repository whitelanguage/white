// Test: X86_64_STACK_SLOT
// File: tests/machine/x86_64/test_stack.wl
// Focus: Lower WIR stack allocation, store and load through a Win64 frame.

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
    let slot: WirValueID = wir_stack_alloc(ref program, entry, int_type, "value", no_wir_location());
    let answer: WirValueID = wir_const_int(ref program, int_type, UInt128(42U));
    wir_store(ref program, entry, answer, slot, no_wir_location());

    let loaded: WirValueID = wir_load(ref program, entry, slot, "loaded", no_wir_location());
    wir_return(ref program, entry, loaded, no_wir_location());

    let lowered: X86LoweringResult = x86_lower_function(ref program, function_id);

    if (lowered.errors.length() != 0) {
        print("FAIL: x86_64 stack lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.bytes.length() != 33 || lowered.bytes[0] != Byte(85) || lowered.bytes[32] != Byte(195)) {
        print("FAIL: unexpected stack frame encoding");
        return 1;
    }
    let object: Vector(Byte) = coff_object_for_text("main", lowered.bytes)?;
    catch(err) {
        print("FAIL: could not write stack test object");
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: could not print stack WIR");
        return 1;
    }

    print("WIR-BEGIN");
    print(text);
    print("WIR-END");

    print("OBJECT-BEGIN");
    let i: Int = 0;
    while (i < object.length()) {
        print(Int(object[i]));
        i += 1;
    }
    print("OBJECT-END");

    return 0;
}
