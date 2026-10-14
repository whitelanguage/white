// Test: AARCH64_ELF
// File: tests/machine/aarch64/test_elf.wl
// Focus: Emit an ELF64 AArch64 object with a CALL26 relocation.

import * from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/encoder.wl"
import a64_elf_object from "../../../src/compiler/machine/aarch64/elf.wl"


func read_u16(bytes: Vector(Byte), offset: Int) -> UInt32 {
    return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8U);
}

func read_u32(bytes: Vector(Byte), offset: Int) -> UInt32 {
    return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8U) |
        (UInt32(bytes[offset + 2]) << 16U) | (UInt32(bytes[offset + 3]) << 24U);
}

func read_u64(bytes: Vector(Byte), offset: Int) -> UInt64 {
    return UInt64(read_u32(bytes, offset)) | (UInt64(read_u32(bytes, offset + 4)) << 32UL);
}

func contains(bytes: Vector(Byte), text: String) -> Bool {
    let i: Int = 0;
    while (i + text.length() <= bytes.length()) {
        let equal: Bool = true;
        let j: Int = 0;
        while (j < text.length()) {
            if (bytes[i + j] != text[j]) {
                equal = false;
                break;
            }
            j++;
        }
        if equal { return true; }
        i++;
    }

    return false;
}

func main() -> Int {
    let code: A64CodeBuffer = a64_new_code_buffer();
    if (!a64_branch_symbol(ref code, "puts", true) || !a64_return(ref code, A64Register.X30)) {
        print("FAIL: AArch64 code could not be encoded");
        return 1;
    }

    let symbols: Vector(A64Symbol) = [
        A64Symbol(name="main", section=".text", offset=0U, external=true, hidden=false),
        A64Symbol(name="puts", section="", offset=0U, external=true, hidden=false)
    ];
    let i: Int = 0;
    while (i < 260) {
        symbols.append(A64Symbol(name="function." + i, section=".text", offset=UInt32(code.bytes.length()), external=false, hidden=true));
        if (!a64_return(ref code, A64Register.X30)) {
            print("FAIL: AArch64 function section could not be encoded");
            return 1;
        }
        i++;
    }

    let object: Vector(Byte) = a64_elf_object(A64Object(
        sections=[A64Section(name=".text", bytes=code.bytes, alignment=4, executable=true, writable=false)],
        symbols=symbols,
        relocations=code.relocations
    ))?;
    catch(err) {
        print("FAIL: AArch64 ELF object encoding failed");
        return 1;
    }

    if (object.length() < 64 || read_u16(object, 16) != 1U || read_u16(object, 18) != 183U || read_u16(object, 60) <= 255U ||
        !contains(object, ".text.0") || !contains(object, ".rela.text.0")) {
        print("FAIL: ELF header does not describe an AArch64 relocatable object");
        return 1;
    }

    let section_table: Int = Int(read_u64(object, 40));
    let section_count: Int = Int(read_u16(object, 60));
    let symbol_table: Int = -1;
    i = 0;
    while (i < section_count) {
        let header: Int = section_table + i * 64;
        if (read_u32(object, header + 4) == 2U) {
            symbol_table = Int(read_u64(object, header + 24));
            break;
        }
        i++;
    }
    if (symbol_table < 0 || object[symbol_table + 3 * 24 + 5] != Byte(2)) {
        print("FAIL: internal AArch64 symbols are not hidden from ELF preemption");
        return 1;
    }

    print("PASS: AArch64 ELF object encoding");
    return 0;
}
