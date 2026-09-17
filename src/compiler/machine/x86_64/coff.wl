// compiler/machine/x86_64/coff.wl
import * from "model.wl"

// COFF object fields are little-endian. The timestamp below is left at zero,
// otherwise the same input would produce a different object on every build.

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

func coff_string_offset(name: String, long_names: Vector(String)) -> Int {
    let offset: Int = 4;
    let i: Int = 0;
    while (i < long_names.length()) {
        if (long_names[i] == name) {
            return offset;
        }

        offset += long_names[i].length() + 1;
        i += 1;
    }
    return 0;
}

func coff_emit_symbol_name(ref output: Vector(Byte), name: String, long_names: Vector(String)) -> Bool {
    if (name.length() <= 8) {
        return coff_emit_name(ref output, name, 8);
    }

    let offset: Int = coff_string_offset(name, long_names);
    if (offset == 0) {
        return false;
    }

    // an inline zero followed by an offset means the name lives in the string table
    coff_emit_u32(ref output, 0U);
    coff_emit_u32(ref output, UInt32(offset));

    return true;
}

func coff_object_for_text_symbols(code: Vector(Byte), symbols: Vector(X86Symbol), relocations: Vector(X86Relocation)) -> Vector(Byte)? {
    if (code.length() == 0 || symbols.length() == 0) {
        throw Error.InvalidArgument;
    }

    let long_names: Vector(String) = [];
    let symbol_index: Int = 0;
    while (symbol_index < symbols.length()) {
        if (symbols[symbol_index].name.length() == 0) {
            throw Error.InvalidArgument;
        }

        if (symbols[symbol_index].name.length() > 8 &&
            coff_find_name(long_names, symbols[symbol_index].name) < 0) {
            long_names.append(symbols[symbol_index].name);
        }

        symbol_index += 1;
    }

    let relocation_index: Int = 0;
    while (relocation_index < relocations.length()) {
        let relocation: X86Relocation = relocations[relocation_index];
        if (relocation.section != ".text" || relocation.kind != X86RelocationKind.Rel32 ||
            relocation.offset + 4U > UInt32(code.length()) ||
            coff_find_symbol(symbols, relocation.symbol) < 0) {
            throw Error.InvalidArgument;
        }
        relocation_index += 1;
    }

    let header_size: Int = 20;
    let section_header_size: Int = 40;

    // calculate every file offset first. COFF headers point forward into section
    // data, relocations and symbols, writing first and patching later was harder
    // to inspect when the initial backend still produced broken objects.
    let raw_offset: Int = header_size + section_header_size;
    let relocation_offset: Int = raw_offset + code.length();

    let symbol_offset: Int = relocation_offset + relocations.length() * 10;
    let string_table_size: Int = 4;

    let long_index: Int = 0;
    while (long_index < long_names.length()) {
        string_table_size += long_names[long_index].length() + 1;
        long_index += 1;
    }

    let object: Vector(Byte) = [];

    coff_emit_u16(ref object, 34404U);
    coff_emit_u16(ref object, 1U);
    coff_emit_u32(ref object, 0U);
    coff_emit_u32(ref object, UInt32(symbol_offset));
    coff_emit_u32(ref object, UInt32(symbols.length()));
    coff_emit_u16(ref object, 0U);
    coff_emit_u16(ref object, 4U);

    if (!coff_emit_name(ref object, ".text", 8)) {
        throw Error.InvalidArgument;
    }

    coff_emit_u32(ref object, 0U);
    coff_emit_u32(ref object, 0U);
    coff_emit_u32(ref object, UInt32(code.length()));
    coff_emit_u32(ref object, UInt32(raw_offset));

    if (relocations.length() > 0) {
        coff_emit_u32(ref object, UInt32(relocation_offset));
    } else {
        coff_emit_u32(ref object, 0U);
    }

    coff_emit_u32(ref object, 0U);
    coff_emit_u16(ref object, UInt32(relocations.length()));
    coff_emit_u16(ref object, 0U);
    coff_emit_u32(ref object, 1610612768U);

    let i = 0;
    while (i < code.length()) {
        object.append(code[i]);
        i += 1;
    }

    relocation_index = 0;
    while (relocation_index < relocations.length()) {
        let relocation: X86Relocation = relocations[relocation_index];
        let target: Int = coff_find_symbol(symbols, relocation.symbol);
        if (target < 0) {
            throw Error.InvalidArgument;
        }

        coff_emit_u32(ref object, relocation.offset);
        coff_emit_u32(ref object, UInt32(target));
        coff_emit_u16(ref object, 4U);

        relocation_index += 1;
    }

    symbol_index = 0;
    while (symbol_index < symbols.length()) {
        let symbol: X86Symbol = symbols[symbol_index];
        if (!coff_emit_symbol_name(ref object, symbol.name, long_names)) {
            throw Error.InvalidArgument;
        }

        if (symbol.section == ".text") {
            coff_emit_u32(ref object, symbol.offset);
        } else {
            coff_emit_u32(ref object, 0U);
        }
        if (symbol.section == ".text") {
            coff_emit_u16(ref object, 1U);
        } else {
            coff_emit_u16(ref object, 0U);
        }
        if (symbol.section == ".text") {
            coff_emit_u16(ref object, 32U);
        } else {
            coff_emit_u16(ref object, 0U);
        }

        if (symbol.external) {
            object.append(Byte(2));
        } else {
            object.append(Byte(3));
        }

        object.append(Byte(0));
        symbol_index += 1;
    }

    coff_emit_u32(ref object, UInt32(string_table_size));
    long_index = 0;
    while (long_index < long_names.length()) {
        i = 0;
        while (i < long_names[long_index].length()) {
            object.append(long_names[long_index][i]);
            i++;
        }

        object.append(Byte(0));
        long_index += 1;
    }
    return object;
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
