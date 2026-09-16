// Test: X86_64_DIRECT_CALLS
// File: tests/machine/x86_64/test_calls.wl
// Focus: Lower a direct function call, Win64 shadow space and the returned value.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let main_id: WirFuncID = wir_add_function(ref program, "main", [], int_type, false, WirLinkage.Exported, WirABI.White);
    let main_entry: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let helper_id: WirFuncID = wir_add_function(ref program, "helper", [], int_type, false, WirLinkage.Internal, WirABI.White);
    let helper_entry: WirBlockID = wir_add_block(ref program, helper_id, "entry", []);
    let seven: WirValueID = wir_const_int(ref program, int_type, UInt128(7U));
    wir_return(ref program, helper_entry, seven, no_wir_location());

    let value: WirValueID = wir_call(ref program, main_entry, WirValueID(program.arena.functions[wir_id_index(UInt32(helper_id))].address), [], "value", no_wir_location());
    let answer: WirValueID = wir_binary(ref program, main_entry, WirOpcode.Add, int_type, value, wir_const_int(ref program, int_type, UInt128(35U)), "answer", no_wir_location());
    wir_return(ref program, main_entry, answer, no_wir_location());

    let lowered: X86ModuleResult = x86_lower_module(program);
    if (lowered.errors.length() != 0) {
        print("FAIL: x86_64 direct call lowering failed: ", lowered.errors[0]);
        return 1;
    }
    let object: Vector(Byte) = coff_object_for_text("main", lowered.bytes)?;
    catch(err) {
        print("FAIL: could not write direct call object");
        return 1;
    }
    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: could not print direct call WIR");
        return 1;
    }

    // print("WIR-BEGIN");
    // print(text);
    // print("WIR-END");

    // print("OBJECT-BEGIN");
    // let i = 0;
    // while (i < object.length()) {
    //     print(Int(object[i]));
    //     i++;
    // }
    // print("OBJECT-END");
    return 0;
}
