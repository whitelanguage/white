// Test: COFF_EXPORTS
// File: tests/machine/x86_64/test_exports.wl
// Focus: Explicit native exports and linker-only COFF directive sections.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/x86_64/model.wl"
import coff_object from "../../../src/compiler/machine/x86_64/coff.wl"
import x86_lower_module from "../../../src/compiler/machine/x86_64/module.wl"


func read_u32(bytes: Vector(Byte), offset: Int) -> UInt32 {
    return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8U) | (UInt32(bytes[offset + 2]) << 16U) | (UInt32(bytes[offset + 3]) << 24U);
}

func main() -> Int {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type = wir_signed_int_type(ref program, 32);
    let function = wir_add_function(ref program, "visible", [], int_type, false, WirLinkage.Exported, WirABI.C);
    program.arena.functions[wir_id_index(UInt32(function))].export_symbol = true;
    let entry = wir_add_block(ref program, function, "entry", []);
    let zero = wir_const_int(ref program, int_type, UInt128(0U));
    wir_return(ref program, entry, zero, no_wir_location());
    let global = wir_add_global(ref program, "visible_data", int_type, zero, WirLinkage.Exported, false);
    program.arena.globals[wir_id_index(UInt32(global))].export_symbol = true;
    let plain = wir_add_function(ref program, "plain", [], int_type, false, WirLinkage.Exported, WirABI.White);
    let plain_entry = wir_add_block(ref program, plain, "entry", []);
    wir_return(ref program, plain_entry, zero, no_wir_location());

    let result = x86_lower_module(ref program);
    if (result.errors.length() != 0) { print("FAIL: export module lowering"); return 1; }
    let object = coff_object(X86Object(sections=result.sections, symbols=result.symbols, relocations=result.relocations))?;
    catch(err) { print("FAIL: export COFF object"); return 1; }
    let i: Int = 0;
    while (i < result.sections.length()) {
        let section = result.sections[i];
        if (section.name == ".drectve") {
            let text: String = "";
            for (let j = 0; j < section.bytes.length(); j++) { text += String(Char(section.bytes[j])); }
            if (text != " -export:\"visible\" -export:\"visible_data\",DATA" || (read_u32(object, 20 + i * 40 + 36) & 2560U) != 2560U) {
                print("FAIL: export directives or section flags");
                return 1;
            }
            print("PASS: explicit COFF exports");
            return 0;
        }
        i++;
    }
    print("FAIL: missing export directives");
    return 1;
}
