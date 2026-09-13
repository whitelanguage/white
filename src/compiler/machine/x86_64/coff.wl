// compiler/machine/x86_64/coff.wl
import * from "model.wl"

/*
the first writer is deliberately literal: one .text section, one symbol and no
relocations. It gives the encoder a real linkable object before the more general
writer exists, and it makes the offsets below easy to check against the COFF
specification with a hex dump.

COFF stores integers little-endian and does not require section data to follow a
file alignment inside an object file. The timestamp stays zero so two identical
compilations produce identical bytes.
*/

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

func coff_object_for_text(symbol: String, code: Vector(Byte)) -> Vector(Byte)? {
    if (symbol.length() == 0 || symbol.length() > 8 || code.length() == 0) {
        throw Error.InvalidArgument;
    }

    let header_size: Int = 20;
    let section_header_size: Int = 40;
    let raw_offset: Int = header_size + section_header_size;
    let symbol_offset: Int = raw_offset + code.length();
    let symbol_size: Int = 18;
    let string_table_size: Int = 4;
    let object: Vector(Byte) = [];

    // IMAGE_FILE_HEADER, AMD64 with no optional header
    coff_emit_u16(ref object, 34404U);
    coff_emit_u16(ref object, 1U);
    coff_emit_u32(ref object, 0U);
    coff_emit_u32(ref object, UInt32(symbol_offset));
    coff_emit_u32(ref object, 1U);
    coff_emit_u16(ref object, 0U);
    coff_emit_u16(ref object, 4U);

    // .text section header
    if (!coff_emit_name(ref object, ".text", 8)) {
        throw Error.InvalidArgument;
    }

    coff_emit_u32(ref object, 0U);
    coff_emit_u32(ref object, 0U);
    coff_emit_u32(ref object, UInt32(code.length()));
    coff_emit_u32(ref object, UInt32(raw_offset));
    coff_emit_u32(ref object, 0U);
    coff_emit_u32(ref object, 0U);
    coff_emit_u16(ref object, 0U);
    coff_emit_u16(ref object, 0U);
    coff_emit_u32(ref object, 1610612768U);

    // section data
    let i: Int = 0;
    while (i < code.length()) {
        object.append(code[i]);
        i += 1;
    }

    // IMAGE_SYMBOL for the exported text symbol. Value zero is the beginning of
    // section one, storage class 2 is IMAGE_SYM_CLASS_EXTERNAL.
    if (!coff_emit_name(ref object, symbol, 8)) {
        throw Error.InvalidArgument;
    }

    coff_emit_u32(ref object, 0U);
    coff_emit_u16(ref object, 1U);
    coff_emit_u16(ref object, 32U);
    object.append(Byte(2));
    object.append(Byte(0));

    // empty string table, all names fit in their inline fields
    coff_emit_u32(ref object, UInt32(string_table_size));
    return object;
}
