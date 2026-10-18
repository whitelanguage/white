// Test: NATIVE_REACHABILITY
// File: tests/machine/aarch64/test_reachability.wl
// Focus: Native emission keeps exported and addressed symbols, including nested data and cycles.

import "file"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import verify_wir from "../../../src/compiler/wir/verify.wl"
import A64Object from "../../../src/compiler/machine/aarch64/model.wl"
import a64_lower_module from "../../../src/compiler/machine/aarch64/lowering.wl"
import a64_elf_object from "../../../src/compiler/machine/aarch64/elf.wl"
import X86Object from "../../../src/compiler/machine/x86_64/model.wl"
import x86_lower_module from "../../../src/compiler/machine/x86_64/lowering.wl"
import elf_object from "../../../src/compiler/machine/x86_64/elf.wl"


func leaf(ref program: WirModule, name: String) -> WirFuncID {
    let int = wir_signed_int_type(ref program, 32);
    let id = wir_add_function(ref program, name, [], int, false, WirLinkage.Internal, WirABI.C);
    let block = wir_add_block(ref program, id, "entry", []);
    wir_return(ref program, block, wir_const_int(ref program, int, UInt128(42U)), no_wir_location());
    return id;
}

func write_object(path: String, bytes: Vector(Byte)) -> Bool {
    let output = file.create(path)?;
    catch(err) { return false; }
    output.write_bytes(bytes)?;
    catch(err) { return false; }
    output.close();
    return true;
}

func check_empty() -> Bool {
    let program = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int = wir_signed_int_type(ref program, 32);
    leaf(ref program, "unrooted");
    wir_add_global(ref program, "unrooted_data", int, wir_const_int(ref program, int, UInt128(9U)), WirLinkage.Internal, true);
    let arm = a64_lower_module(ref program);
    if (arm.errors.length() != 0 || arm.symbols.length() != 0 || arm.relocations.length() != 0) { return false; }
    let bytes = a64_elf_object(A64Object(sections=arm.sections, symbols=arm.symbols, relocations=arm.relocations))?;
    catch(err) { return false; }
    if (!write_object("a64_empty.o", bytes)) { return false; }

    program.target = "x86_64-unknown-linux-gnu";
    let x86 = x86_lower_module(ref program);
    if (x86.errors.length() != 0 || x86.symbols.length() != 0 || x86.relocations.length() != 0) { return false; }
    bytes = elf_object(X86Object(sections=x86.sections, symbols=x86.symbols, relocations=x86.relocations))?;
    catch(err) { return false; }
    if (!write_object("x86_empty.o", bytes)) { return false; }

    program.target = "aarch64-unknown-linux-gnu";
    wir_add_global(ref program, "exported_data", int, wir_const_int(ref program, int, UInt128(42U)), WirLinkage.Exported, true);
    arm = a64_lower_module(ref program);
    if (arm.errors.length() != 0 || arm.symbols.length() != 1 || arm.symbols[0].name != "exported_data") { return false; }
    bytes = a64_elf_object(A64Object(sections=arm.sections, symbols=arm.symbols, relocations=arm.relocations))?;
    catch(err) { return false; }
    if (!write_object("a64_data_only.o", bytes)) { return false; }

    // unnamed code still cannot be split into per-function sections.
    arm.sections[0].bytes = [Byte(192), Byte(3), Byte(95), Byte(214)];
    let unnamed = A64Object(sections=[arm.sections[0]], symbols=[], relocations=[]);
    a64_elf_object(unnamed)?;
    catch(err) { return true; }
    return false;
}

func main() -> Int {
    if (!check_empty()) {
        print("FAIL: empty or data-only native module");
        return 1;
    }

    let program = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int = wir_signed_int_type(ref program, 32);
    let raw = wir_pointer_type(ref program, program.void_type);
    let int_ptr = wir_pointer_type(ref program, int);
    let host = wir_add_function(ref program, "host_increment", [wir_param("value", int)], int, false, WirLinkage.External, WirABI.C);
    wir_add_function(ref program, "dead_api", [], int, false, WirLinkage.External, WirABI.C);
    leaf(ref program, "dead_fn");
    wir_add_global(ref program, "dead_global", int, wir_const_int(ref program, int, UInt128(99U)), WirLinkage.Internal, true);
    wir_add_global(ref program, "dead_import", int, NO_WIR_VALUE, WirLinkage.External, false);

    let payload = wir_add_global(ref program, "payload", int, wir_const_int(ref program, int, UInt128(7U)), WirLinkage.Internal, false);
    let callback = wir_add_function(ref program, "callback", [], int, false, WirLinkage.Internal, WirABI.C);
    let block = wir_add_block(ref program, callback, "entry", []);
    let value = wir_load(ref program, block, wir_global_value(ref program, payload), "value", no_wir_location());
    let incremented = wir_call(ref program, block, wir_function_value(ref program, host), [value], "next", no_wir_location());
    wir_return(ref program, block, incremented, no_wir_location());

    let callback_type = wir_value_type(ref program, wir_function_value(ref program, callback));
    let inner = wir_struct_type(ref program, [int_ptr, callback_type]);
    let outer = wir_struct_type(ref program, [int, inner]);
    let address = wir_const_address(ref program, int_ptr, wir_global_value(ref program, payload), 0L);
    let contents = wir_const_aggregate(ref program, inner, [address, wir_function_value(ref program, callback)]);
    let table = wir_const_aggregate(ref program, outer, [wir_const_int(ref program, int, UInt128(123U)), contents]);
    wir_add_global(ref program, "exported_table", outer, table, WirLinkage.Exported, true);

    let entry = leaf(ref program, "entry");
    program.arena.functions[wir_id_index(UInt32(entry))].linkage = WirLinkage.Exported;
    let flagged = leaf(ref program, "flagged");
    program.arena.functions[wir_id_index(UInt32(flagged))].export_symbol = true;
    let flagged_global = wir_add_global(ref program, "flagged_global", int, wir_const_int(ref program, int, UInt128(5U)), WirLinkage.Internal, true);
    program.arena.globals[wir_id_index(UInt32(flagged_global))].export_symbol = true;

    let first = wir_add_global(ref program, "cycle_a", raw, wir_null(ref program, raw), WirLinkage.Exported, true);
    let second = wir_add_global(ref program, "cycle_b", raw, wir_const_address(ref program, raw, wir_global_value(ref program, first), 0L), WirLinkage.Internal, true);
    program.arena.globals[wir_id_index(UInt32(first))].initializer = wir_const_address(ref program, raw, wir_global_value(ref program, second), 0L);

    let errors = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: reachability WIR: ", errors[0]);
        return 1;
    }

    let arm = a64_lower_module(ref program);
    if (arm.errors.length() != 0) {
        print("FAIL: AArch64 reachability: ", arm.errors[0]);
        return 1;
    }
    program.target = "x86_64-unknown-linux-gnu";
    let x86 = x86_lower_module(ref program);
    if (x86.errors.length() != 0) {
        print("FAIL: x86 reachability: ", x86.errors[0]);
        return 1;
    }

    let names: Vector(String) = ["entry", "callback", "host_increment", "flagged", "exported_table", "payload", "cycle_a", "cycle_b", "flagged_global"];
    if (arm.symbols.length() != names.length() || x86.symbols.length() != names.length()) {
        print("FAIL: native emission kept unused symbols");
        return 1;
    }
    let i = 0;
    while (i < names.length()) {
        let arm_found = false;
        let x86_found = false;
        let j = 0;
        while (j < names.length()) {
            if (arm.symbols[j].name == names[i]) { arm_found = true; }
            if (x86.symbols[j].name == names[i]) { x86_found = true; }
            j++;
        }
        if (!arm_found || !x86_found) {
            print("FAIL: lost reachable symbol ", names[i]);
            return 1;
        }
        i++;
    }

    let bytes = a64_elf_object(A64Object(sections=arm.sections, symbols=arm.symbols, relocations=arm.relocations))?;
    catch(err) { return 1; }
    if (!write_object("a64_reachability.o", bytes)) { return 1; }
    bytes = elf_object(X86Object(sections=x86.sections, symbols=x86.symbols, relocations=x86.relocations))?;
    catch(err) { return 1; }
    if (!write_object("x86_reachability.o", bytes)) { return 1; }

    print("PASS: native symbol reachability and empty ELF objects");
    return 0;
}
