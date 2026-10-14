// Test: AARCH64_ELF
// File: tests/machine/aarch64/test_elf.wl
// Focus: Emit an ELF64 AArch64 object with a CALL26 relocation.

import * from "../../../src/compiler/machine/aarch64/model.wl"
import * from "../../../src/compiler/machine/aarch64/encoder.wl"
import a64_elf_object from "../../../src/compiler/machine/aarch64/elf.wl"


func read_u16(bytes: Vector(Byte), offset: Int) -> UInt32 {
    return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8U);
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
        A64Symbol(name="main", section=".text", offset=0U, external=true),
        A64Symbol(name="puts", section="", offset=0U, external=true)
    ];
    let i: Int = 0;
    while (i < 260) {
        symbols.append(A64Symbol(name="function." + i, section=".text", offset=UInt32(code.bytes.length()), external=false));
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

    print("PASS: AArch64 ELF object encoding");
    return 0;
}
