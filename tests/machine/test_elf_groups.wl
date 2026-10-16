// Test: ELF_GROUPS
// File: tests/machine/test_elf_groups.wl
// Focus: Preserve per-section RELA order when input relocations are interleaved.

import * from "../../src/compiler/machine/object.wl"
import elf64_object from "../../src/compiler/machine/elf.wl"


func u32(bytes: Vector(Byte), offset: Int) -> UInt32 {
    return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8U) |
           (UInt32(bytes[offset + 2]) << 16U) | (UInt32(bytes[offset + 3]) << 24U);
}

func main() -> Int {
    let sections: Vector(MachineSection) = [];
    let relocs: Vector(MachineRelocation) = [];
    let i = 0;
    while (i < 256) {
        let data: Vector(Byte) = [];
        let j = 0;
        while (j < 16) {
            data.append(Byte(0));
            j++;
        }
        sections.append(MachineSection(name=".text." + i, bytes=data, alignment=8, executable=true, writable=false));
        i++;
    }

    let round = 0;
    while (round < 2) {
        i = 0;
        while (i < sections.length()) {
            relocs.append(MachineRelocation(section=sections[i].name, offset=UInt32(round * 8), kind=257U, symbol="target", addend=Long(round - 1)));
            i++;
        }
        round++;
    }

    let bytes = elf64_object(MachineObject(machine=183U, sections=sections,
        symbols=[MachineSymbol(name="target", section="", offset=0U, external=true, hidden=false)], relocations=relocs))?;
    catch(err) {
        print("FAIL: grouped ELF relocations");
        return 1;
    }

    let headers = Int(u32(bytes, 40));
    i = 0;
    while (i < sections.length()) {
        // the null header and GNU-stack note precede the RELA headers.
        let header = headers + (sections.length() + 2 + i) * 64;
        let data = Int(u32(bytes, header + 24));
        if (u32(bytes, header + 4) != 4U || u32(bytes, header + 32) != 48U ||
            u32(bytes, header + 44) != UInt32(i + 1) ||
            u32(bytes, data) != 0U || u32(bytes, data + 24) != 8U ||
            u32(bytes, data + 8) != 257U || u32(bytes, data + 12) != 1U ||
            u32(bytes, data + 16) != 4294967295U || u32(bytes, data + 20) != 4294967295U ||
            u32(bytes, data + 40) != 0U || u32(bytes, data + 44) != 0U) {
            print("FAIL: ELF relocation order, section ", i);
            return 1;
        }
        i++;
    }

    print("PASS: ELF relocation groups");
    return 0;
}
