// Test: COFF_READER
// File: tests/linker/test_coff_reader.wl
// Focus: Object spans, auxiliary indices and malformed inputs without runtime traps.

import * from "../../src/linker/coff/model.wl"
import read_coff, coff_name_matches, coff_u32 from "../../src/linker/coff/reader.wl"
import * from "../../src/compiler/machine/x86_64/model.wl"
import coff_object, coff_emit_u16, coff_emit_u32, coff_emit_name from "../../src/compiler/machine/x86_64/coff.wl"


func copy_bytes(bytes: Vector(Byte), count: Int) -> Vector(Byte) {
    let result: Vector(Byte) = [];
    let i: Int = 0;
    while (i < count) {
        result.append(bytes[i]);
        i++;
    }
    return result;
}

func put_u32(bytes: Vector(Byte), offset: Int, value: UInt32) -> Void {
    let i: Int = 0;
    while (i < 4) {
        bytes[offset + i] = Byte((value >> UInt32(i * 8)) & 255U);
        i++;
    }
}

func bad_u32(bytes: Vector(Byte), offset: Int, value: UInt32) -> Bool {
    let copy = copy_bytes(bytes, bytes.length());
    put_u32(copy, offset, value);
    let result = read_coff(copy);
    return result.status == CoffError.InvalidObject && result.object is null && result.message.length() > 0;
}

func aux_object() -> Vector(Byte) {
    let bytes: Vector(Byte) = [];
    coff_emit_u16(ref bytes, 34404U);
    coff_emit_u16(ref bytes, 1U);
    coff_emit_u32(ref bytes, 0U);
    coff_emit_u32(ref bytes, 78U);
    coff_emit_u32(ref bytes, 3U);
    coff_emit_u16(ref bytes, 0U);
    coff_emit_u16(ref bytes, 0U);

    coff_emit_name(ref bytes, ".text", 8);
    coff_emit_u32(ref bytes, 0U);
    coff_emit_u32(ref bytes, 0U);
    coff_emit_u32(ref bytes, 8U);
    coff_emit_u32(ref bytes, 60U);
    coff_emit_u32(ref bytes, 68U);
    coff_emit_u32(ref bytes, 0U);
    coff_emit_u16(ref bytes, 1U);
    coff_emit_u16(ref bytes, 0U);
    coff_emit_u32(ref bytes, 0x60500020U);

    coff_emit_u32(ref bytes, 0U);
    coff_emit_u32(ref bytes, 0U);
    coff_emit_u32(ref bytes, 0U);
    coff_emit_u32(ref bytes, 2U);
    coff_emit_u16(ref bytes, 1U);

    coff_emit_name(ref bytes, ".text", 8);
    coff_emit_u32(ref bytes, 0U);
    coff_emit_u16(ref bytes, 1U);
    coff_emit_u16(ref bytes, 0U);
    bytes.append(Byte(3));
    bytes.append(Byte(1));
    let i: Int = 0;
    while (i < 18) {
        bytes.append(Byte(0));
        i++;
    }

    coff_emit_name(ref bytes, "target", 8);
    coff_emit_u32(ref bytes, 0U);
    coff_emit_u16(ref bytes, 0U);
    coff_emit_u16(ref bytes, 0U);
    bytes.append(Byte(2));
    bytes.append(Byte(0));
    coff_emit_u32(ref bytes, 4U);
    return bytes;
}

func main() -> Int {
    let code: Vector(Byte) = [];
    let i: Int = 0;
    while (i < 16) {
        code.append(Byte(0));
        i++;
    }
    let source: X86Object = X86Object(
        sections=[X86CodeSection(name=".text", bytes=code, alignment=16, executable=true, writable=false)],
        symbols=[X86Symbol(name="entry", section=".text", offset=0U, external=true), X86Symbol(name="long_external_target", section="", offset=0U, external=true)],
        relocations=[X86Relocation(section=".text", offset=0U, kind=X86RelocationKind.Abs64, symbol="long_external_target", addend=7L), X86Relocation(section=".text", offset=8U, kind=X86RelocationKind.Rel32, symbol="entry", addend=-4L)]
    );
    let bytes = coff_object(source)?;
    catch(err) { print("FAIL: fixture writer"); return 1; }
    let result = read_coff(bytes);
    if (result.object is null || result.status != CoffError.None) {
        print("FAIL: read writer object", result.offset, result.message);
        return 1;
    }
    let object: CoffObject = result.object;
    if (object.sections.length() != 1 || object.symbols.length() != 2 || object.sections[0].alignment != 16 || object.sections[0].relocs.length() != 2 ||
        !coff_name_matches(object, object.sections[0].name, ".text") || !coff_name_matches(object, object.symbols[1].name, "long_external_target") ||
        object.sections[0].relocs[0].symbol != 1 || object.sections[0].relocs[1].symbol != 0 || bytes[object.sections[0].data.offset] != Byte(7)) {
        print("FAIL: decoded object changed names, alignment, addends or symbol indices");
        return 1;
    }

    i = 0;
    while (i < bytes.length()) {
        let truncated = read_coff(copy_bytes(bytes, i));
        if (truncated.object is !null || truncated.status == CoffError.None) {
            print("FAIL: accepted truncated fixture", i);
            return 1;
        }
        i++;
    }
    let symbol_start: Int = Int(coff_u32(bytes, 8));
    let reloc_start: Int = Int(coff_u32(bytes, 44));
    let string_start: Int = symbol_start + 36;
    if (!bad_u32(bytes, 8, 4294967295U) || !bad_u32(bytes, 12, 4294967295U) || !bad_u32(bytes, 40, 4294967295U) ||
        !bad_u32(bytes, 44, 4294967295U) || !bad_u32(bytes, 36, 4294967295U) || !bad_u32(bytes, 8, 20U) ||
        !bad_u32(bytes, string_start, 3U) || !bad_u32(bytes, string_start, 4294967295U) ||
        !bad_u32(bytes, symbol_start + 22, 3U) || !bad_u32(bytes, symbol_start + 22, 4294967295U) ||
        !bad_u32(bytes, reloc_start, 9U) || !bad_u32(bytes, reloc_start + 4, 2U) || !bad_u32(bytes, 56, 0x60F00020U)) {
        print("FAIL: malformed table, name or relocation passed validation");
        return 1;
    }
    let missing_end = copy_bytes(bytes, bytes.length());
    missing_end[missing_end.length() - 1] = Byte(65);
    if (read_coff(missing_end).status != CoffError.InvalidObject) { print("FAIL: unterminated string"); return 1; }

    let aux = aux_object();
    result = read_coff(aux);
    if (result.object is null) { print("FAIL: auxiliary record fixture", result.message); return 1; }
    object = result.object;
    if (object.symbols.length() != 2 || object.symbol_map.length() != 3 || object.symbol_map[1] != -1 || object.symbol_map[2] != 1 ||
        object.symbols[0].aux.size != 18 || object.symbols[1].table_index != 2 || object.sections[0].relocs[0].symbol != 1) {
        print("FAIL: auxiliary symbols changed relocation indices");
        return 1;
    }
    if (!bad_u32(aux, 72, 1U) || !bad_u32(aux, 72, 3U)) { print("FAIL: relocation to auxiliary or missing symbol"); return 1; }
    let excess_aux = copy_bytes(aux, aux.length());
    excess_aux[95] = Byte(3);
    if (read_coff(excess_aux).status != CoffError.InvalidObject) { print("FAIL: auxiliary count"); return 1; }

    let bad_section = copy_bytes(aux, aux.length());
    bad_section[90] = Byte(2);
    if (read_coff(bad_section).status != CoffError.InvalidObject) { print("FAIL: symbol section index"); return 1; }
    bad_section[90] = Byte(255);
    bad_section[91] = Byte(255);
    if (read_coff(bad_section).status != CoffError.None) { print("FAIL: absolute symbol"); return 1; }
    bad_section[90] = Byte(254);
    if (read_coff(bad_section).status != CoffError.None) { print("FAIL: debug symbol"); return 1; }
    bad_section[90] = Byte(253);
    if (read_coff(bad_section).status != CoffError.InvalidObject) { print("FAIL: reserved symbol section"); return 1; }

    let padding = copy_bytes(aux, aux.length());
    padding[76] = Byte(0);
    put_u32(padding, 68, 4294967295U);
    put_u32(padding, 72, 4294967295U);
    result = read_coff(padding);
    if (result.object is null) { print("FAIL: ABSOLUTE relocation padding"); return 1; }
    object = result.object;
    if (object.sections[0].relocs.length() != 0) { print("FAIL: applied padding as a relocation"); return 1; }

    let based = copy_bytes(aux, aux.length());
    put_u32(based, 32, 4096U);
    put_u32(based, 68, 4096U);
    result = read_coff(based);
    if (result.object is null) { print("FAIL: section-relative relocation"); return 1; }
    object = result.object;
    if (object.sections[0].address != 4096U || object.sections[0].relocs[0].offset != 0U) { print("FAIL: lost section address"); return 1; }
    put_u32(based, 68, 4095U);
    if (read_coff(based).status != CoffError.InvalidObject) { print("FAIL: relocation before section base"); return 1; }

    // a pointer with zero records is unused, a nonzero count must validate it.
    let lines = copy_bytes(aux, aux.length());
    put_u32(lines, 48, 4294967295U);
    if (read_coff(lines).status != CoffError.None) { print("FAIL: unused line pointer"); return 1; }
    lines[54] = Byte(1);
    if (read_coff(lines).status != CoffError.InvalidObject) { print("FAIL: line number table"); return 1; }

    // move a short name to /4 in the section header, the symbol shares its bytes.
    let long_section = copy_bytes(bytes, bytes.length());
    i = 20;
    while (i < 28) { long_section[i] = Byte(0); i++; }
    long_section[20] = Byte(47);
    long_section[21] = Byte(52);
    result = read_coff(long_section);
    if (result.object is null) { print("FAIL: long section name"); return 1; }
    object = result.object;
    if (!coff_name_matches(object, object.sections[0].name, "long_external_target")) { print("FAIL: string table section name"); return 1; }

    // BSS has a logical size but no bytes in the object file.
    let bss = copy_bytes(aux, aux.length());
    put_u32(bss, 40, 0U);
    put_u32(bss, 56, 0xC0500080U);
    bss[52] = Byte(0);
    result = read_coff(bss);
    if (result.object is null) { print("FAIL: BSS section"); return 1; }
    object = result.object;
    if (object.sections[0].size != 8U || object.sections[0].data.size != 0) { print("FAIL: BSS storage"); return 1; }

    let unknown = copy_bytes(aux, aux.length());
    unknown[76] = Byte(255);
    if (read_coff(unknown).status != CoffError.UnsupportedObject) { print("FAIL: unsupported relocation"); return 1; }
    unknown = copy_bytes(aux, aux.length());
    unknown[0] = Byte(76);
    unknown[1] = Byte(1);
    if (read_coff(unknown).status != CoffError.UnsupportedObject) { print("FAIL: unsupported machine"); return 1; }

    unknown = copy_bytes(aux, aux.length());
    unknown[0] = Byte(77);
    unknown[1] = Byte(90);
    if (read_coff(unknown).status != CoffError.UnsupportedObject) { print("FAIL: PE image"); return 1; }
    unknown[0] = Byte(0);
    unknown[1] = Byte(0);
    unknown[2] = Byte(255);
    unknown[3] = Byte(255);
    if (read_coff(unknown).status != CoffError.UnsupportedObject) { print("FAIL: bigobj or import object"); return 1; }
    unknown = copy_bytes(aux, aux.length());
    unknown[16] = Byte(1);
    if (read_coff(unknown).status != CoffError.UnsupportedObject) { print("FAIL: optional header"); return 1; }
    unknown = copy_bytes(aux, aux.length());
    unknown[20] = Byte(47);
    unknown[21] = Byte(47);
    if (read_coff(unknown).status != CoffError.UnsupportedObject) { print("FAIL: unsupported section name encoding"); return 1; }

    let archive: Vector(Byte) = [Byte(33), Byte(60), Byte(97), Byte(114), Byte(99), Byte(104), Byte(62), Byte(10)];
    if (read_coff(archive).status != CoffError.UnsupportedObject) { print("FAIL: archive diagnostic"); return 1; }

    // mutate structural bytes as well as the fixed cases above, no failure may
    // return a partial object, and no random count may reach an unchecked read.
    let state: UInt32 = 12345U;
    i = 0;
    while (i < 2000) {
        let mutated = copy_bytes(aux, aux.length());
        let j: Int = 0;
        while (j < 4) {
            state = state * 1664525U + 1013904223U;
            let offset: Int = Int(state % UInt32(mutated.length()));
            state = state * 1664525U + 1013904223U;
            mutated[offset] = Byte(state & 255U);
            j++;
        }
        result = read_coff(mutated);
        if ((result.status == CoffError.None) != (result.object is !null)) { print("FAIL: partial malformed object"); return 1; }
        i++;
    }

    print("PASS: COFF reader bounds, names, auxiliary records and malformed inputs");
    return 0;
}
