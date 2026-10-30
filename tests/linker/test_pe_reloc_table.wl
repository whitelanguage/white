// Test: PE_RELOC_TABLE
// File: tests/linker/test_pe_reloc_table.wl
// Focus: Ordered and unordered base fixups, page grouping, padding and invalid fields.
import CoffBaseReloc from "../../src/linker/coff/link_model.wl"
import coff_u16, coff_u32 from "../../src/linker/coff/reader.wl"
import pe_base_relocs from "../../src/linker/pe/reloc.wl"


func main() -> Int {
    let input: Vector(CoffBaseReloc) = [CoffBaseReloc(8192U, 10U), CoffBaseReloc(4104U, 10U), CoffBaseReloc(4096U, 3U), CoffBaseReloc(16382U, 10U)];
    let result = pe_base_relocs(input);
    if (result.message.length() != 0 || result.bytes.length() != 36 || input[0].rva != 8192U || input[2].rva != 4096U ||
        coff_u32(result.bytes, 0) != 4096U || coff_u32(result.bytes, 4) != 12U ||
        coff_u16(result.bytes, 8) != 12288U || coff_u16(result.bytes, 10) != 40968U ||
        coff_u32(result.bytes, 12) != 8192U || coff_u32(result.bytes, 16) != 12U ||
        coff_u16(result.bytes, 20) != 40960U || coff_u16(result.bytes, 22) != 0U ||
        coff_u32(result.bytes, 24) != 12288U || coff_u16(result.bytes, 32) != 45054U || coff_u16(result.bytes, 34) != 0U) {
        print("FAIL: base relocation pages or padding");
        return 1;
    }
    result = pe_base_relocs([CoffBaseReloc(4096U, 10U), CoffBaseReloc(4096U, 10U)]);
    if (result.message.length() == 0) { print("FAIL: duplicate base fixup accepted"); return 1; }
    result = pe_base_relocs([CoffBaseReloc(4096U, 2U)]);
    if (result.message.length() == 0) { print("FAIL: unsupported base fixup accepted"); return 1; }
    result = pe_base_relocs([]);
    if (result.bytes.length() != 0 || result.message.length() != 0) { return 1; }

    let many: Vector(CoffBaseReloc) = [];
    let i = 1023;
    while (i >= 0) { many.append(CoffBaseReloc(UInt32(4096 + i * 8), 10U)); i--; }
    result = pe_base_relocs(many);
    if (result.message.length() != 0 || result.bytes.length() != 2064 ||
        coff_u32(result.bytes, 0) != 4096U || coff_u32(result.bytes, 4) != 1032U ||
        coff_u32(result.bytes, 1032) != 8192U || coff_u32(result.bytes, 1036) != 1032U || many[0].rva != 12280U) {
        print("FAIL: large unordered base relocation table");
        return 1;
    }
    print("PASS: PE base relocation encoding");
    return 0;
}
