// Test: X86_64_REGISTER_SPILLS
// File: tests/machine/x86_64/test_spills.wl
// Focus: Spill live integer values and reload them for register-register arithmetic.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/machine/x86_64/lowering.wl"
import * from "../../../src/compiler/machine/x86_64/allocator.wl"
import * from "../../../src/compiler/machine/x86_64/coff.wl"
import X86Register, X86Opcode from "../../../src/compiler/machine/x86_64/model.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(ref program, "main", [], int_type, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);

    let a: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, int_type, wir_const_int(ref program, int_type, UInt128(10U)), wir_const_int(ref program, int_type, UInt128(1U)), "a", no_wir_location());
    let b: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, int_type, wir_const_int(ref program, int_type, UInt128(20U)), wir_const_int(ref program, int_type, UInt128(2U)), "b", no_wir_location());
    let c: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, int_type, wir_const_int(ref program, int_type, UInt128(30U)), wir_const_int(ref program, int_type, UInt128(3U)), "c", no_wir_location());
    let d: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, int_type, wir_const_int(ref program, int_type, UInt128(40U)), wir_const_int(ref program, int_type, UInt128(4U)), "d", no_wir_location());
    let ab: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, int_type, a, b, "ab", no_wir_location());
    let cd: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, int_type, c, d, "cd", no_wir_location());
    let sum: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, int_type, ab, cd, "sum", no_wir_location());
    wir_return(ref program, entry, sum, no_wir_location());

    let order: Vector(WirBlockID) = [entry];
    let uses: X86UseTable = x86_collect_uses(ref program, order);
    if (x86_spill_capacity(ref program, order, uses, 3) < 1) {
        print("FAIL: x86_64 spill planner did not detect register pressure");
        return 1;
    }

    let registers: X86RegisterPlan = x86_register_plan(uses);
    let spills: X86SpillPlan = x86_new_spill_plan([-8, -16]);
    x86_claim_spill(spills, a);
    x86_claim_spill(spills, b);
    x86_bind_register(registers, X86Register.RAX, a);
    let state: X86BlockState = X86BlockState(accumulator=NO_WIR_VALUE, flags_value=NO_WIR_VALUE, flags_opcode=X86Opcode.Invalid, registers=registers, spills=spills, stack=X86StackIndex(base=0, dense_count=0, sparse=[], offsets=[], sizes=[]), layouts=[], retain_function=NO_WIR_FUNC, release_function=NO_WIR_FUNC, return_pointer=0, position=0, message="");
    if (x86_claim_register_spill(ref state, c) != -8 || x86_spill_offset(spills, b) != -16 || x86_spill_offset(spills, a) != 0) {
        print("FAIL: reloaded spill copy was not reclaimed");
        return 1;
    }
    if (x86_claim_register_spill(ref state, d) != 0 || x86_claim_register_spill(ref state, c) != -8) {
        print("FAIL: spill allocation discarded a value without a register copy");
        return 1;
    }

    let lowered: X86LoweringResult = x86_lower_function(ref program, function_id);
    if (lowered.errors.length() != 0) {
        print("FAIL: x86_64 spill lowering failed: ", lowered.errors[0]);
        return 1;
    }

    let object: Vector(Byte) = coff_object_for_text("main", lowered.bytes)?;
    catch(err) {
        print("FAIL: could not write spill test object");
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: could not print spill test WIR");
        return 1;
    }

    // print("WIR-BEGIN");
    // print(text);
    // print("WIR-END");

    // print("OBJECT-BEGIN");
    // let i: Int = 0;
    // while (i < object.length()) {
    //     print(Int(object[i]));
    //     i += 1;
    // }
    // print("OBJECT-END");

    return 0;
}
