// Test: COFF_READER_OVERFLOW
// File: tests/linker/test_coff_overflow.wl
// Focus: Decode extended relocation tables, reject forged counts before allocation.

import * from "../../src/linker/coff/model.wl"
import read_coff, coff_u32 from "../../src/linker/coff/reader.wl"
import * from "../../src/compiler/machine/x86_64/model.wl"
import coff_object from "../../src/compiler/machine/x86_64/coff.wl"


func main() -> Int {
    let data: Vector(Byte) = [];
    let relocs: Vector(X86Relocation) = [];
    let i: Int = 0;
    while (i < 65536) {
        data.append(Byte(0));
        data.append(Byte(0));
        data.append(Byte(0));
        data.append(Byte(0));
        relocs.append(X86Relocation(section=".text", offset=UInt32(i * 4), kind=X86RelocationKind.Rel32, symbol="main", addend=-4L));
        i++;
    }
    let bytes = coff_object(X86Object(
        sections=[X86CodeSection(name=".text", bytes=data, alignment=16, executable=true, writable=false)],
        symbols=[X86Symbol(name="main", section=".text", offset=0U, external=true)],
        relocations=relocs
    ))?;
    catch(err) { print("FAIL: extended relocation fixture"); return 1; }
    let result = read_coff(bytes);
    if (result.object is null) { print("FAIL: extended relocations", result.offset, result.message); return 1; }
    let object: CoffObject = result.object;
    if (object.sections[0].relocs.length() != 65536 || object.sections[0].relocs[65535].offset != 262140U ||
        object.sections[0].relocs[65535].symbol != 0) {
        print("FAIL: overflow sentinel changed relocation count");
        return 1;
    }

    let start: Int = Int(coff_u32(bytes, 44));
    bytes[start] = Byte(255);
    bytes[start + 1] = Byte(255);
    bytes[start + 2] = Byte(255);
    bytes[start + 3] = Byte(255);
    if (read_coff(bytes).status != CoffError.InvalidObject) { print("FAIL: oversized relocation count"); return 1; }

    bytes[start] = Byte(255);
    bytes[start + 1] = Byte(255);
    bytes[start + 2] = Byte(0);
    bytes[start + 3] = Byte(0);
    if (read_coff(bytes).status != CoffError.InvalidObject) { print("FAIL: undersized overflow count"); return 1; }

    bytes[start] = Byte(1);
    bytes[start + 1] = Byte(0);
    bytes[start + 2] = Byte(1);
    bytes[start + 4] = Byte(1);
    if (read_coff(bytes).status != CoffError.InvalidObject) { print("FAIL: overflow sentinel symbol"); return 1; }

    bytes[start + 4] = Byte(0);
    bytes[52] = Byte(1);
    if (read_coff(bytes).status != CoffError.InvalidObject) { print("FAIL: overflow flag without 0xffff header count"); return 1; }

    print("PASS: COFF reader extended relocation counts");
    return 0;
}
