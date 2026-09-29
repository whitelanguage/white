// Test: X86_64_PARAMETER_RETURN
// File: tests/machine/x86_64/test_param_return.wl
// Focus: Lower a Windows x64 integer parameter from RCX into the return register.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "echo", [wir_param("value", int_type)], int_type, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    wir_append(ref program, entry, WirOpcode.Return, program.void_type, [function.parameters[0]], [], no_wir_location());

    let lowered: X86LoweringResult = x86_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: x86_64 parameter lowering failed: ", lowered.errors[0]);
        return 1;
    }
    if (lowered.bytes.length() != 3 || lowered.bytes[0] != Byte(137) || lowered.bytes[1] != Byte(200) || lowered.bytes[2] != Byte(195)) {
        print("FAIL: unexpected parameter return encoding");
        return 1;
    }
    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: could not print parameter WIR");
        return 1;
    }
    print(text);
    print("parameter return bytes: 89 C8 C3");
    print("PASS: Parameter return encoding");
    return 0;
}
