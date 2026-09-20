// compiler/machine/x86_64/coff.wl
import * from "model.wl"

// COFF object fields are little-endian. The timestamp is always zero, this also
// keeps objects made from the same WIR byte-for-byte reproducible.

func coff_emit_u16(ref output: Vector(Byte), value: UInt32) -> Void {
    output.append(Byte(value & 255U));
    output.append(Byte((value >> 8U) & 255U));
}

func coff_emit_u32(ref output: Vector(Byte), value: UInt32) -> Void {
    output.append(Byte(value & 255U));
    output.append(Byte((value >> 8U) & 255U));
    output.append(Byte((value >> 16U) & 255U));
    output.append(Byte((value >> 24U) & 255U));
}

func coff_emit_name(ref output: Vector(Byte), name: String, width: Int) -> Bool {
    if (name.length() > width) {
        return false;
    }

    let i = 0;
    while (i < name.length()) {
        output.append(name[i]);
        i += 1;
    }
    while (i < width) {
        output.append(Byte(0));
        i += 1;
    }

    return true;
}

func coff_find_name(names: Vector(String), name: String) -> Int {
    let i = 0;
    while (i < names.length()) {
        if (names[i] == name) {
            return i;
        }

        i++;
    }
    return -1;
}

func coff_find_symbol(symbols: Vector(X86Symbol), name: String) -> Int {
    let i = 0;
    while (i < symbols.length()) {
        if (symbols[i].name == name) {
            return i;
        }

        i++;
    }
    return -1;
}

func coff_emit_symbol_name(ref output: Vector(Byte), name: String, offsets: Dict(String, Int)) -> Bool {
    if (name.length() <= 8) {
        return coff_emit_name(ref output, name, 8);
    }

    let offset: Int = offsets.lookup(name);
    if (offset == 0) {
        return false;
    }

    // zero in the first four bytes selects the string table form
    coff_emit_u32(ref output, 0U);
    coff_emit_u32(ref output, UInt32(offset));

    return true;
}

func coff_section_index(sections: Vector(X86CodeSection), name: String) -> Int {
    let i: Int = 0;
    while (i < sections.length()) {
        if (sections[i].name == name) {
            return i;
        }
        i++;
    }
    return -1;
}

func coff_alignment_bits(alignment: Int) -> UInt32 {
    if (alignment == 0) {
        return 0U;
    }
    let power: Int = 1;
    let code: UInt32 = 1U;
    while (power < alignment) {
        power <<= 1;
        code++;
    }
    return code << 20U;
}

func coff_object(input: X86Object) -> Vector(Byte)? {
    if (input.sections.length() == 0 || input.sections.length() > 32767 ||
        input.symbols.length() == 0) {
        throw Error.InvalidArgument;
    }
    let long_names: Vector(String) = [];
    let symbol_indices: Dict(String, Int) = Dict();
    let name_offsets: Dict(String, Int) = Dict();
    let string_table_size: Long = 4L;
    let i: Int = 0;
    while (i < input.sections.length()) {
        let section: X86CodeSection = input.sections[i];
        if (section.name.length() == 0 || section.name.length() > 8 ||
            coff_section_index(input.sections, section.name) != i) {
            throw Error.InvalidArgument;
        }
        if (section.alignment < 0 || section.alignment > 8192 ||
            (section.alignment != 0 && (section.alignment & (section.alignment - 1)) != 0)) {
            throw Error.InvalidArgument;
        }
        i++;
    }
    i = 0;
    while (i < input.symbols.length()) {
        let symbol: X86Symbol = input.symbols[i];
        if (symbol.name.length() == 0 || symbol_indices.contains_key(symbol.name)) { throw Error.InvalidArgument; }
        symbol_indices.put(symbol.name, i + 1);
        let section: Int = coff_section_index(input.sections, symbol.section);
        if (symbol.section.length() != 0 && (section < 0 || symbol.offset > UInt32(input.sections[section].bytes.length()))) { throw Error.InvalidArgument; }
        if (symbol.name.length() > 8) {
            name_offsets.put(symbol.name, Int(string_table_size));
            string_table_size += Long(symbol.name.length()) + 1L;
            if (string_table_size > 2147483647L) { throw Error.Overflow; }
            long_names.append(symbol.name);
        }
        i++;
    }

    let counts: Vector(Int) = [];
    i = 0;
    while (i < input.sections.length()) { counts.append(0); i++; }
    i = 0;
    while (i < input.relocations.length()) {
        let relocation: X86Relocation = input.relocations[i];
        let section: Int = coff_section_index(input.sections, relocation.section);
        let width: UInt64 = 4UL;
        if (relocation.kind == X86RelocationKind.Abs64) {
            width = 8UL;
        } else if (relocation.kind != X86RelocationKind.Rel32) {
            throw Error.InvalidArgument;
        }
        if (section < 0 ||
            UInt64(relocation.offset) + width > UInt64(input.sections[section].bytes.length()) ||
            symbol_indices.lookup(relocation.symbol) == 0) {
            throw Error.InvalidArgument;
        }
        if (relocation.kind == X86RelocationKind.Rel32 &&
            (relocation.addend < -2147483648L || relocation.addend > 2147483647L)) {
            throw Error.InvalidArgument;
        }
        counts[section] = counts[section] + 1;
        i++;
    }

    // work out the whole file layout before writing the first header. Relocation
    // and symbol offsets point forward, keeping them here avoids a patching pass.
    let raw_offsets: Vector(UInt32) = [];
    let relocation_offsets: Vector(UInt32) = [];
    let offset: Long = 20L + Long(input.sections.length()) * 40L;
    i = 0;
    while (i < input.sections.length()) {
        raw_offsets.append(UInt32(offset));
        offset += Long(input.sections[i].bytes.length());
        relocation_offsets.append(UInt32(offset));
        offset += Long(counts[i]) * 10L;
        if (counts[i] > 65535) { offset += 10L; }
        if (offset > 2147483647L) { throw Error.Overflow; }
        i++;
    }
    let symbol_offset: UInt32 = UInt32(offset);
    offset += Long(input.symbols.length()) * 18L;
    if (offset + string_table_size > 2147483647L) { throw Error.Overflow; }

    let output: Vector(Byte) = [];
    coff_emit_u16(ref output, 34404U);
    coff_emit_u16(ref output, UInt32(input.sections.length()));
    coff_emit_u32(ref output, 0U);
    coff_emit_u32(ref output, symbol_offset);
    coff_emit_u32(ref output, UInt32(input.symbols.length()));
    coff_emit_u16(ref output, 0U);
    coff_emit_u16(ref output, 4U);

    i = 0;
    while (i < input.sections.length()) {
        let section: X86CodeSection = input.sections[i];
        if (!coff_emit_name(ref output, section.name, 8)) { throw Error.InvalidArgument; }
        coff_emit_u32(ref output, 0U);
        coff_emit_u32(ref output, 0U);
        coff_emit_u32(ref output, UInt32(section.bytes.length()));
        if (section.bytes.length() == 0) { coff_emit_u32(ref output, 0U); }
        else { coff_emit_u32(ref output, raw_offsets[i]); }
        if (counts[i] == 0) { coff_emit_u32(ref output, 0U); }
        else { coff_emit_u32(ref output, relocation_offsets[i]); }
        coff_emit_u32(ref output, 0U);
        if (counts[i] > 65535) { coff_emit_u16(ref output, 65535U); }
        else { coff_emit_u16(ref output, UInt32(counts[i])); }
        coff_emit_u16(ref output, 0U);
        let flags: UInt32 = 1073741888U;
        if (section.executable) { flags = 1610612768U; }
        if (section.writable) { flags |= 2147483648U; }
        if (counts[i] > 65535) { flags |= 16777216U; }
        flags |= coff_alignment_bits(section.alignment);
        coff_emit_u32(ref output, flags);
        i++;
    }

    i = 0;
    while (i < input.sections.length()) {
        let section: X86CodeSection = input.sections[i];
        let j: Int = 0;
        while (j < section.bytes.length()) {
            output.append(section.bytes[j]);
            j++;
        }
        // the overflow record counts itself but is not a relocation to be applied
        if (counts[i] > 65535) {
            coff_emit_u32(ref output, UInt32(counts[i]) + 1U);
            coff_emit_u32(ref output, 0U);
            coff_emit_u16(ref output, 0U);
        }
        j = 0;
        while (j < input.relocations.length()) {
            let relocation: X86Relocation = input.relocations[j];
            if (relocation.section == section.name) {
                // COFF stores the addend in the section bytes, not in the relocation record
                let width: Int = 4;
                let kind: UInt32 = 4U;
                if (relocation.kind == X86RelocationKind.Abs64) {
                    width = 8;
                    kind = 1U;
                }
                let k: Int = 0;
                while (k < width) {
                    output[Int(raw_offsets[i] + relocation.offset) + k] = Byte((relocation.addend >> Long(k * 8)) & 255L);
                    k++;
                }
                coff_emit_u32(ref output, relocation.offset);
                coff_emit_u32(ref output, UInt32(symbol_indices.lookup(relocation.symbol) - 1));
                coff_emit_u16(ref output, kind);
            }
            j++;
        }
        i++;
    }

    i = 0;
    while (i < input.symbols.length()) {
        let symbol: X86Symbol = input.symbols[i];
        if (!coff_emit_symbol_name(ref output, symbol.name, name_offsets)) { throw Error.InvalidArgument; }
        let section: Int = coff_section_index(input.sections, symbol.section);
        if (section < 0) { coff_emit_u32(ref output, 0U); }
        else { coff_emit_u32(ref output, symbol.offset); }
        coff_emit_u16(ref output, UInt32(section + 1));
        if (symbol.section == ".text") { coff_emit_u16(ref output, 32U); }
        else { coff_emit_u16(ref output, 0U); }
        if (symbol.external) { output.append(Byte(2)); }
        else { output.append(Byte(3)); }
        output.append(Byte(0));
        i++;
    }
    coff_emit_u32(ref output, UInt32(string_table_size));
    i = 0;
    while (i < long_names.length()) {
        let j: Int = 0;
        while (j < long_names[i].length()) { output.append(long_names[i][j]); j++; }
        output.append(Byte(0));
        i++;
    }
    return output;
}

func coff_object_for_text_symbols(code: Vector(Byte), symbols: Vector(X86Symbol), relocations: Vector(X86Relocation)) -> Vector(Byte)? {
    if (code.length() == 0 || symbols.length() == 0) {
        throw Error.InvalidArgument;
    }

    let section: X86CodeSection = X86CodeSection(name=".text", bytes=code, alignment=0, executable=true, writable=false);

    return coff_object(X86Object(sections=[section], symbols=symbols, relocations=relocations))?;
}

func coff_object_for_text(symbol: String, code: Vector(Byte)) -> Vector(Byte)? {
    if (symbol.length() == 0 || code.length() == 0) {
        throw Error.InvalidArgument;
    }

    return coff_object_for_text_symbols(code, [X86Symbol(name=symbol, section=".text", offset=0U, external=true)], [])?;
}

func coff_object_for_text_relocations(symbol: String, code: Vector(Byte), relocations: Vector(X86Relocation)) -> Vector(Byte)? {
    if (symbol.length() == 0 || code.length() == 0) {
        throw Error.InvalidArgument;
    }

    let symbols: Vector(X86Symbol) = [X86Symbol(name=symbol, section=".text", offset=0U, external=true)];
    let i = 0;
    while (i < relocations.length()) {
        if (coff_find_symbol(symbols, relocations[i].symbol) < 0) {
            symbols.append(X86Symbol(name=relocations[i].symbol, section="", offset=0U, external=true));
        }
        i += 1;
    }

    return coff_object_for_text_symbols(code, symbols, relocations)?;
}
