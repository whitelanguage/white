// Test: AARCH64_INTEGER_LOWERING
// File: tests/machine/aarch64/test_lowering.wl
// Focus: Lower scalar parameters, integer arithmetic and a return into AArch64 code.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/lowering.wl"
import a64_elf_object from "../../../src/compiler/machine/aarch64/elf.wl"


func read_u32(bytes: Vector(Byte), offset: Int) -> UInt32 {
    return UInt32(bytes[offset]) |
        (UInt32(bytes[offset + 1]) << 8U) |
        (UInt32(bytes[offset + 2]) << 16U) |
        (UInt32(bytes[offset + 3]) << 24U);
}

func contains_word(bytes: Vector(Byte), value: UInt32) -> Bool {
    let offset: Int = 0;
    while (offset + 4 <= bytes.length()) {
        if (read_u32(bytes, offset) == value) { return true; }
        offset += 4;
    }

    return false;
}

func main() -> Int {
    let program: WirModule = new_wir_module("aarch64-unknown-linux-gnu", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let function_id: WirFuncID = wir_add_function(
        ref program,
        "add",
        [wir_param("left", int_type), wir_param("right", int_type)],
        int_type,
        false,
        WirLinkage.Exported,
        WirABI.C
    );
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let sum: WirValueID = wir_append(
        ref program,
        entry,
        WirOpcode.Add,
        int_type,
        [function.parameters[0], function.parameters[1]],
        [],
        no_wir_location()
    );
    wir_append(ref program, entry, WirOpcode.Return, program.void_type, [sum], [], no_wir_location());

    let lowered: A64ModuleResult = a64_lower_module(ref program);
    if (lowered.errors.length() != 0) {
        print("FAIL: AArch64 lowering failed: ", lowered.errors[0]);
        return 1;
    }

    let bytes: Vector(Byte) = lowered.sections[0].bytes;
    if (bytes.length() < 32 || bytes.length() % 4 != 0 ||
        read_u32(bytes, 0) != 0xA9BF7BFDU ||
        !contains_word(bytes, 0x0B0A012BU) ||
        read_u32(bytes, bytes.length() - 4) != 0xD65F03C0U) {
        print("FAIL: AArch64 add function has unexpected instructions");
        return 1;
    }

    let object: Vector(Byte) = a64_elf_object(A64Object(
        sections=lowered.sections,
        symbols=lowered.symbols,
        relocations=lowered.relocations
    ))?;
    catch(err) {
        print("FAIL: lowered AArch64 function could not be written as ELF");
        return 1;
    }
    if (object.length() < 64) {
        print("FAIL: lowered AArch64 ELF object is empty");
        return 1;
    }

    print("PASS: AArch64 scalar integer lowering");
    return 0;
}
