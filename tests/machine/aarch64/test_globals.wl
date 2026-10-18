// Test: AARCH64_GLOBAL_DATA
// File: tests/machine/aarch64/test_globals.wl
// Focus: Emit initialized data and address it through ADRP/ADD relocations.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import a64_elf_object from "../../../src/compiler/machine/aarch64/elf.wl"


func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let int_pointer: WirTypeID = wir_pointer_type(ref program, int_type);
    let global_id: WirGlobalID = wir_add_global(ref program, "answer", int_type, wir_const_int(ref program, int_type, UInt128(42U)), WirLinkage.Internal, false);
    let answer_address: WirValueID = wir_const_address(ref program, int_pointer, wir_global_value(ref program, global_id), 0L);
    wir_add_global(ref program, "answer_pointer", int_pointer, answer_address, WirLinkage.Exported, true);

    let function_id: WirFuncID = wir_add_function(ref program, "read_answer", [], int_type, false, WirLinkage.Exported, WirABI.C);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let loaded: WirValueID = wir_load(ref program, entry, wir_global_value(ref program, global_id), "loaded", no_wir_location());
    wir_return(ref program, entry, loaded, no_wir_location());

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 global lowering failed: ", lowered.errors[0]);
        return 1;
    }

    let data_found: Bool = false;
    let i: Int = 0;
    while (i < lowered.sections.length()) {
        if (lowered.sections[i].name == ".data" && lowered.sections[i].bytes.length() == 4) {
            data_found = lowered.sections[i].bytes[0] == Byte(42);
        }
        i++;
    }
    let address_found: Bool = false;
    i = 0;
    while (i < lowered.relocations.length()) {
        let relocation: A64Relocation = lowered.relocations[i];
        if (relocation.section == ".data.rel.ro" && relocation.kind == A64RelocationKind.Abs64 && relocation.symbol == "answer") {
            address_found = true;
        }
        i++;
    }

    if (!data_found || !address_found || lowered.relocations.length() != 3 ||
        lowered.relocations[0].kind != A64RelocationKind.Page21 ||
        lowered.relocations[1].kind != A64RelocationKind.PageOffset12) {
        print("FAIL: AArch64 global sections or address relocations are incorrect");
        return 1;
    }

    a64_elf_object(A64Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) {
        print("FAIL: AArch64 global object could not be encoded");
        return 1;
    }

    print("PASS: AArch64 global data");
    return 0;
}
