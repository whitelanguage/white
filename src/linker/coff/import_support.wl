// src/linker/coff/import_support.wl
// support members follow the standard COFF import library layout
import CoffReloc from "model.wl"
import CoffLibraryPart from "library_model.wl"
import library_word, library_text from "library_write.wl"


struct ImportSupportSection(name: String, bytes: Vector(Byte), flags: UInt32, relocs: Vector(CoffReloc) = [])
struct ImportSupportSymbol(name: String, section: Int, storage: Byte)

func import_zeroes(count: Int) -> Vector(Byte) {
    let bytes: Vector(Byte) = [];
    for (let i = 0; i < count; i++) { bytes.append(Byte(0)); }
    return bytes;
}

func import_support_object(sections: Vector(ImportSupportSection), symbols: Vector(ImportSupportSymbol)) -> Vector(Byte) {
// these three fixed-shape objects need no auxiliary records, section-class symbols join the import tables
    let symbol_offset = 20 + sections.length() * 40;
    for (let s = 0; s < sections.length(); s++) { symbol_offset += sections[s].bytes.length() + sections[s].relocs.length() * 10; }
    let bytes: Vector(Byte) = [];
    library_word(ref bytes, 0x8664U, 2);
    library_word(ref bytes, UInt32(sections.length()), 2);
    library_word(ref bytes, 0U, 4);
    library_word(ref bytes, UInt32(symbol_offset), 4);
    library_word(ref bytes, UInt32(symbols.length()), 4);
    library_word(ref bytes, 0U, 4);

    let cursor = 20 + sections.length() * 40;
    for (let sec = 0; sec < sections.length(); sec++) {
        let section = sections[sec];
        library_text(ref bytes, section.name, false);
        library_word(ref bytes, 0U, 4);
        library_word(ref bytes, 0U, 4);
        library_word(ref bytes, UInt32(section.bytes.length()), 4);
        library_word(ref bytes, UInt32(cursor), 4);
        let reloc_offset = 0;
        if (section.relocs.length() != 0) { reloc_offset = cursor + section.bytes.length(); }
        library_word(ref bytes, UInt32(reloc_offset), 4);
        library_word(ref bytes, 0U, 4);
        library_word(ref bytes, UInt32(section.relocs.length()), 2);
        library_word(ref bytes, 0U, 2);
        library_word(ref bytes, section.flags, 4);
        cursor += section.bytes.length() + section.relocs.length() * 10;
    }
    for (let data = 0; data < sections.length(); data++) {
        let section = sections[data];
        for (let b = 0; b < section.bytes.length(); b++) { bytes.append(section.bytes[b]); }
        for (let r = 0; r < section.relocs.length(); r++) {
            let reloc = section.relocs[r];
            library_word(ref bytes, reloc.offset, 4);
            library_word(ref bytes, UInt32(reloc.symbol), 4);
            library_word(ref bytes, reloc.kind, 2);
        }
    }

    let strings: Vector(Byte) = [];
    for (let sym = 0; sym < symbols.length(); sym++) {
        let symbol = symbols[sym];
        if (symbol.name.length() <= 8) {
            library_text(ref bytes, symbol.name, false);
            for (let pad = symbol.name.length(); pad < 8; pad++) { bytes.append(Byte(0)); }
        } else {
            library_word(ref bytes, 0U, 4);
            library_word(ref bytes, UInt32(strings.length() + 4), 4);
            library_text(ref strings, symbol.name);
        }
        library_word(ref bytes, 0U, 4);
        library_word(ref bytes, UInt32(symbol.section), 2);
        library_word(ref bytes, 0U, 2);
        bytes.append(symbol.storage);
        bytes.append(Byte(0));
    }
    library_word(ref bytes, UInt32(strings.length() + 4), 4);
    for (let str = 0; str < strings.length(); str++) { bytes.append(strings[str]); }
    return bytes;
}

func import_support_members(dll: String) -> Vector(CoffLibraryPart) {
// MS linkers pull these by their reserved symbols, short imports supply the per-export thunks
    let stem = dll;
    for (let dot = dll.length() - 1; dot > 0; dot--) {
        if (dll[dot] == '.') { stem = dll.slice(0, dot); break; }
    }
    let descriptor = "__IMPORT_DESCRIPTOR_" + stem;
    let null_descriptor = "__NULL_IMPORT_DESCRIPTOR";
    let null_thunk = String(Char(127)) + stem + "_NULL_THUNK_DATA";
    let dll_name: Vector(Byte) = [];
    library_text(ref dll_name, dll);
    let descriptor_sections = [ImportSupportSection(".idata$2", import_zeroes(20), 0xC0300040U,
        [CoffReloc(12U, 2, 3U), CoffReloc(0U, 3, 3U), CoffReloc(16U, 4, 3U)]),
        ImportSupportSection(".idata$6", dll_name, 0xC0200040U)];
    let descriptor_symbols = [ImportSupportSymbol(descriptor, 1, Byte(2)),
        ImportSupportSymbol(".idata$2", 1, Byte(104)), ImportSupportSymbol(".idata$6", 2, Byte(3)),
        ImportSupportSymbol(".idata$4", 0, Byte(104)), ImportSupportSymbol(".idata$5", 0, Byte(104)),
        ImportSupportSymbol(null_descriptor, 0, Byte(2)), ImportSupportSymbol(null_thunk, 0, Byte(2))];
    let parts = [CoffLibraryPart(import_support_object(descriptor_sections, descriptor_symbols), [descriptor])];
    parts.append(CoffLibraryPart(import_support_object([ImportSupportSection(".idata$3", import_zeroes(20), 0xC0300040U)],
        [ImportSupportSymbol(null_descriptor, 1, Byte(2))]), [null_descriptor]));
    parts.append(CoffLibraryPart(import_support_object([ImportSupportSection(".idata$5", import_zeroes(8), 0xC0400040U),
        ImportSupportSection(".idata$4", import_zeroes(8), 0xC0400040U)],
        [ImportSupportSymbol(null_thunk, 1, Byte(2))]), [null_thunk]));
    return parts;
}
