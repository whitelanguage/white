// src/linker/coff/reader.wl
// format reference: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
import * from "model.wl"


func coff_range(size: Int, offset: Long, count: Long, width: Int) -> Bool {
// divide the available bytes before multiplying an untrusted record count
    return offset >= 0L && offset <= Long(size) && count >= 0L && width > 0 && count <= (Long(size) - offset) / Long(width);
}

func coff_u16(bytes: Vector(Byte), offset: Int) -> UInt32 {
// callers prove the containing record is in bounds before reading its fields
    return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8U);
}

func coff_u32(bytes: Vector(Byte), offset: Int) -> UInt32 {
    return coff_u16(bytes, offset) | (coff_u16(bytes, offset + 2) << 16U);
}

func coff_invalid(offset: Int, message: String) -> CoffResult {
    return CoffResult(status=CoffError.InvalidObject, offset=offset, message=message);
}

func coff_unsupported(offset: Int, message: String) -> CoffResult {
    return CoffResult(status=CoffError.UnsupportedObject, offset=offset, message=message);
}

func coff_short_name(bytes: Vector(Byte), offset: Int) -> CoffSpan {
    let size: Int = 0;
    while (size < 8 && bytes[offset + size] != Byte(0)) { size++; }
    return CoffSpan(offset, size);
}

func coff_long_name(offset: UInt32, table: CoffSpan, ends: Vector(Int)) -> CoffSpan {
// the table is scanned once, shared names and suffixes must not rescan long strings
    if (offset < 4U || Long(offset) >= Long(table.size)) { return CoffSpan(-1, 0); }
    let start: Int = table.offset + Int(offset);
    let low: Int = 0;
    let high: Int = ends.length();

    while (low < high) {
        let mid: Int = low + (high - low) / 2;
        if (ends[mid] < start) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    if (low == ends.length()) { return CoffSpan(-1, 0); }
    return CoffSpan(start, ends[low] - start);
}

func coff_section_name(bytes: Vector(Byte), offset: Int, table: CoffSpan, ends: Vector(Int)) -> CoffSpan {
    if (bytes[offset] != Byte(47)) { return coff_short_name(bytes, offset); }

    let value: UInt32 = 0U;
    let i: Int = 1;
    while (i < 8 && bytes[offset + i] != Byte(0)) {
        let digit: UInt32 = UInt32(bytes[offset + i]);
        if (digit < 48U || digit > 57U || value > (4294967295U - (digit - 48U)) / 10U) {
            return CoffSpan(-1, 0);
        }
        value = value * 10U + digit - 48U;
        i++;
    }
    if (i == 1) { return CoffSpan(-1, 0); }
    return coff_long_name(value, table, ends);
}

func coff_name_matches(object: CoffObject, name: CoffSpan, text: String) -> Bool {
// keep object names as bytes, decoding them as text would lose non-UTF-8 names
    if (name.size != text.length() || !coff_range(object.bytes.length(), Long(name.offset), Long(name.size), 1)) {
        return false;
    }
    let i: Int = 0;
    while (i < name.size) {
        if (object.bytes[name.offset + i] != text[i]) { return false; }
        i++;
    }
    return true;
}

func coff_reloc_width(kind: UInt32) -> Int {
    if (kind == 0U) { return 0; }
    if (kind == 1U) { return 8; }
    if (kind >= 2U && kind <= 9U) { return 4; }
    if (kind == 10U) { return 2; }
    if (kind == 11U || kind == 13U) { return 4; }
    if (kind == 12U) { return 1; }
    return -1;
}

func read_coff(bytes: Vector(Byte)) -> CoffResult {
// validate file spans before decoding, partial objects never escape on failure
    let size: Int = bytes.length();
    if (size >= 8 && coff_u32(bytes, 0) == 0x72613C21U && coff_u32(bytes, 4) == 0x0A3E6863U) {
        return coff_unsupported(0, "Expected a COFF object, found an archive");
    }
    if (size < 20) { return coff_invalid(0, "Truncated COFF header"); }
    if (coff_u16(bytes, 0) == 23117U) { return coff_unsupported(0, "Expected a COFF object, found a PE image"); }
    if (coff_u16(bytes, 0) == 0U && coff_u16(bytes, 2) == 65535U) {
        return coff_unsupported(0, "Expected an ordinary COFF object, found an import or bigobj header");
    }
    if (coff_u16(bytes, 0) != 34404U) { return coff_unsupported(0, "Expected an AMD64 COFF object"); }
    if (coff_u16(bytes, 16) != 0U || (coff_u16(bytes, 18) & 2U) != 0U) {
        return coff_unsupported(16, "COFF images and optional headers are not supported");
    }

    let section_count: Int = Int(coff_u16(bytes, 2));
    if (section_count > 32767) { return coff_unsupported(2, "COFF section count requires bigobj"); }
    if (!coff_range(size, 20L, Long(section_count), 40)) {
        return coff_invalid(2, "Truncated COFF section table");
    }
    let header_end: Int = 20 + section_count * 40;
    let symbol_offset: Long = Long(coff_u32(bytes, 8));
    let symbol_count: Long = Long(coff_u32(bytes, 12));
    let strings: CoffSpan = CoffSpan();
    let ends: Vector(Int) = [];

    if (symbol_offset == 0L) {
        if (symbol_count != 0L) { return coff_invalid(8, "Missing COFF symbol table"); }
    } else {
        if (symbol_offset < Long(header_end) || !coff_range(size, symbol_offset, symbol_count, 18)) {
            return coff_invalid(8, "Invalid COFF symbol table range");
        }
        let start: Int = Int(symbol_offset + symbol_count * 18L);
        if (!coff_range(size, Long(start), 1L, 4)) {
            return coff_invalid(start, "Missing COFF string table length");
        }
        let length: Long = Long(coff_u32(bytes, start));
        if (length < 4L || !coff_range(size, Long(start), length, 1)) {
            return coff_invalid(start, "Invalid COFF string table range");
        }
        strings = CoffSpan(start, Int(length));
        let i: Int = start + 4;
        while (i < start + Int(length)) {
            if (bytes[i] == Byte(0)) { ends.append(i); }
            i++;
        }
    }

    let object: CoffObject = CoffObject(bytes=bytes, timestamp=coff_u32(bytes, 4), flags=coff_u16(bytes, 18));
    let index: Int = 0;
    while (Long(index) < symbol_count) {
        // raw COFF indices include auxiliary entries, these never name a symbol.
        object.symbol_map.append(-1);
        index++;
    }

    index = 0;
    while (Long(index) < symbol_count) {
        let entry: Int = Int(symbol_offset) + index * 18;
        let aux_count: Int = Int(bytes[entry + 17]);
        if (Long(aux_count) >= symbol_count - Long(index)) {
            return coff_invalid(entry + 17, "Truncated COFF auxiliary symbols");
        }
        let name: CoffSpan = coff_short_name(bytes, entry);
        if (coff_u32(bytes, entry) == 0U) { name = coff_long_name(coff_u32(bytes, entry + 4), strings, ends); }
        if (name.offset < 0) { return coff_invalid(entry, "Invalid COFF symbol name"); }

        let section: Int = Int(coff_u16(bytes, entry + 12));
        if (section >= 32768) { section -= 65536; }
        if (section < -2 || section > section_count) {
            return coff_invalid(entry + 12, "Invalid COFF symbol section");
        }

        object.symbol_map[index] = object.symbols.length();
        object.symbols.append(CoffSymbol(name=name, value=coff_u32(bytes, entry + 8), section=section, type=coff_u16(bytes, entry + 14), storage=bytes[entry + 16], table_index=index, aux=CoffSpan(entry + 18, aux_count * 18)));
        index += aux_count + 1;
    }

    // TagIndex uses the original table, an auxiliary entry cannot be a fallback.
    index = 0;
    while (index < object.symbols.length()) {
        let symbol = object.symbols[index];
        if (symbol.storage == Byte(105)) {
            if (symbol.section != 0 || symbol.value != 0U || symbol.aux.size != 18) {
                return coff_invalid(symbol.aux.offset, "Invalid COFF weak external record");
            }
            let tag = Long(coff_u32(bytes, symbol.aux.offset));
            if (tag >= Long(object.symbol_map.length()) || object.symbol_map[Int(tag)] < 0) {
                return coff_invalid(symbol.aux.offset, "Weak external fallback does not name a primary symbol");
            }
            let target = object.symbol_map[Int(tag)];
            if (object.symbols[target].storage != Byte(2) && object.symbols[target].storage != Byte(105)) {
                return coff_invalid(symbol.aux.offset, "Weak external fallback must be external");
            }
            let search = coff_u32(bytes, symbol.aux.offset + 4);
            if (search != 1U && search != 3U) {
                return coff_unsupported(symbol.aux.offset + 4, "Unsupported COFF weak external search mode");
            }
            symbol.weak_target = target;
            symbol.weak_search = search;
            object.symbols[index] = symbol;
        }
        index++;
    }

    index = 0;
    while (index < section_count) {
        let header: Int = 20 + index * 40;
        if (bytes[header] == Byte(47) && bytes[header + 1] == Byte(47)) {
            return coff_unsupported(header, "Base64 COFF section names are not supported yet");
        }
        let name: CoffSpan = coff_section_name(bytes, header, strings, ends);
        if (name.offset < 0) { return coff_invalid(header, "Invalid COFF section name"); }
        let flags: UInt32 = coff_u32(bytes, header + 36);
        let align_code: Int = Int((flags >> 20U) & 15U);
        if (align_code == 15) { return coff_invalid(header + 36, "Invalid COFF section alignment"); }
        let alignment: Int = 0;
        if (align_code > 0) { alignment = 1 << (align_code - 1); }

        let raw_size: UInt32 = coff_u32(bytes, header + 16);
        let raw_offset: Long = Long(coff_u32(bytes, header + 20));
        let data: CoffSpan = CoffSpan();
        if (raw_offset != 0L && raw_size != 0U) {
            if (raw_offset < Long(header_end) || !coff_range(size, raw_offset, Long(raw_size), 1)) {
                return coff_invalid(header + 20, "Invalid COFF section data range");
            }
            data = CoffSpan(Int(raw_offset), Int(raw_size));
        } else if (raw_size != 0U && (flags & 128U) == 0U) {
            return coff_invalid(header + 20, "Missing initialized COFF section data");
        }

        let line_offset: Long = Long(coff_u32(bytes, header + 28));
        let line_count: Long = Long(coff_u16(bytes, header + 34));
        let lines: CoffSpan = CoffSpan();
        if (line_count != 0L) {
            if (line_offset < Long(header_end) || !coff_range(size, line_offset, line_count, 6)) {
                return coff_invalid(header + 28, "Invalid COFF line number table range");
            }
            lines = CoffSpan(Int(line_offset), Int(line_count * 6L));
        }

        let reloc_offset: Long = Long(coff_u32(bytes, header + 24));
        let reloc_count: Long = Long(coff_u16(bytes, header + 32));
        let overflow: Bool = (flags & 16777216U) != 0U;
        if overflow {
            if (reloc_count != 65535L || reloc_offset < Long(header_end) || !coff_range(size, reloc_offset, 1L, 10)) {
                return coff_invalid(header + 24, "Invalid COFF relocation overflow record");
            }
            reloc_count = Long(coff_u32(bytes, Int(reloc_offset)));
            if (reloc_count <= 65535L || coff_u32(bytes, Int(reloc_offset) + 4) != 0U || coff_u16(bytes, Int(reloc_offset) + 8) != 0U) {
                return coff_invalid(Int(reloc_offset), "Invalid COFF relocation overflow count");
            }
        }
        if (reloc_count != 0L && (reloc_offset < Long(header_end) || !coff_range(size, reloc_offset, reloc_count, 10))) {
            return coff_invalid(header + 24, "Invalid COFF relocation table range");
        }

        let relocs: Vector(CoffReloc) = [];
        let i: Int = 0;
        // the overflow record includes itself in the count, skip only that record.
        if overflow { i = 1; }
        while (Long(i) < reloc_count) {
            let entry: Int = Int(reloc_offset) + i * 10;
            let kind: UInt32 = coff_u16(bytes, entry + 8);
            let width: Int = coff_reloc_width(kind);
            if (width < 0) { return coff_unsupported(entry + 8, "Unsupported AMD64 COFF relocation"); }
            // ABSOLUTE is padding, its other fields have no relocation meaning.
            if (width != 0) {
                let target: Long = Long(coff_u32(bytes, entry + 4));
                if (target >= symbol_count || object.symbol_map[Int(target)] < 0) {
                    return coff_invalid(entry + 4, "COFF relocation does not name a primary symbol");
                }
                let address: UInt32 = coff_u32(bytes, entry);
                let base: UInt32 = coff_u32(bytes, header + 12);
                if (address < base || Long(address - base) + Long(width) > Long(raw_size)) {
                    return coff_invalid(entry, "COFF relocation extends beyond its section");
                }
                relocs.append(CoffReloc(address - base, object.symbol_map[Int(target)], kind));
            }
            i++;
        }

        object.sections.append(CoffSection(name=name, size=raw_size, address=coff_u32(bytes, header + 12), data=data, flags=flags, alignment=alignment, relocs=relocs, lines=lines));
        index++;
    }

    return CoffResult(object=object);
}
