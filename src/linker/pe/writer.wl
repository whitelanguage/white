// src/linker/pe/writer.wl
// PE32+ field offsets: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
import * from "model.wl"
import * from "layout.wl"
import * from "reloc.wl"
import * from "imports.wl"
import * from "../coff/model.wl"
import * from "../coff/link_model.wl"
import coff_name_matches from "../coff/reader.wl"
import coff_resolve_symbols from "../coff/symbols.wl"
import coff_apply_section, coff_put_word from "../coff/reloc.wl"


func pe_image_error(status: CoffLinkStatus, object: Int, section: Int, message: String) -> PeImageResult {
    return PeImageResult(errors=[CoffLinkError(status=status, object=object, section=section, message=message)]);
}

func pe_zeros(ref bytes: Vector(Byte), size: Int) -> Void {
    while (bytes.length() < size) { bytes.append(Byte(0)); }
}

func pe_entry(objects: Vector(CoffObject), name: String) -> CoffSymbolRef {
// only external definitions name a public entry, local symbols can share the spelling
    let i = 0;
    while (i < objects.length()) {
        let object = objects[i];
        let j = 0;
        while (j < object.symbols.length()) {
            let symbol = object.symbols[j];
            if (symbol.storage == Byte(2) && symbol.section > 0 && coff_name_matches(object, symbol.name, name)) {
                return CoffSymbolRef(i, j);
            }
            j++;
        }
        i++;
    }
    return CoffSymbolRef();
}

func pe_headers(layout: PeLayout, options: PeOptions, entry: UInt32, reloc_rva: UInt32, reloc_size: UInt32, fixed: Bool, import_rva: UInt32 = 0U, import_size: UInt32 = 0U, iat_rva: UInt32 = 0U, iat_size: UInt32 = 0U) -> Vector(Byte) {
// leave timestamp, checksums and reserved fields zero so repeated links reproduce the file
    let bytes: Vector(Byte) = [];
    pe_zeros(ref bytes, Int(layout.headers_size));
    coff_put_word(bytes, 0, 2, 23117UL);
    coff_put_word(bytes, 2, 2, 64UL);
    coff_put_word(bytes, 8, 2, 4UL);
    coff_put_word(bytes, 24, 2, 64UL);
    coff_put_word(bytes, 60, 4, 64UL);
    coff_put_word(bytes, 64, 4, 17744UL);
    coff_put_word(bytes, 68, 2, 34404UL);
    coff_put_word(bytes, 70, 2, UInt64(layout.sections.length()));
    coff_put_word(bytes, 84, 2, 240UL);
    let flags = 34UL; // executable and large-address aware
    if fixed { flags |= 1UL; }
    coff_put_word(bytes, 86, 2, flags);

    let code = 0UL;
    let initialized = 0UL;
    let uninitialized = 0UL;
    let first_code = 0U;
    let i = 0;
    while (i < layout.sections.length()) {
        let section = layout.sections[i];
        if ((section.flags & 32U) != 0U) {
            code += UInt64(section.raw_size);
            if (first_code == 0U) { first_code = section.rva; }
        } else if (section.raw_size != 0U) { initialized += UInt64(section.raw_size); }
        else { uninitialized += UInt64(section.size); }
        i++;
    }
    let header = 88;
    coff_put_word(bytes, header, 2, 523UL);
    coff_put_word(bytes, header + 4, 4, code);
    coff_put_word(bytes, header + 8, 4, initialized);
    coff_put_word(bytes, header + 12, 4, uninitialized);
    coff_put_word(bytes, header + 16, 4, UInt64(entry));
    coff_put_word(bytes, header + 20, 4, UInt64(first_code));
    coff_put_word(bytes, header + 24, 8, options.image_base);
    coff_put_word(bytes, header + 32, 4, 4096UL);
    coff_put_word(bytes, header + 36, 4, 512UL);
    coff_put_word(bytes, header + 40, 2, 6UL);
    coff_put_word(bytes, header + 48, 2, 6UL);
    coff_put_word(bytes, header + 56, 4, UInt64(layout.image_size));
    coff_put_word(bytes, header + 60, 4, UInt64(layout.headers_size));
    coff_put_word(bytes, header + 68, 2, 3UL); // console subsystem
    let dll_flags = 33024UL; // NX and terminal-server aware
    if (!fixed) { dll_flags |= 96UL; } // ASLR and high-entropy VA, only DIR64 fields reach this case
    coff_put_word(bytes, header + 70, 2, dll_flags);
    coff_put_word(bytes, header + 72, 8, options.stack_reserve);
    coff_put_word(bytes, header + 80, 8, options.stack_commit);
    coff_put_word(bytes, header + 88, 8, options.heap_reserve);
    coff_put_word(bytes, header + 96, 8, options.heap_commit);
    coff_put_word(bytes, header + 108, 4, 16UL);
    coff_put_word(bytes, header + 112 + 8, 4, UInt64(import_rva));
    coff_put_word(bytes, header + 116 + 8, 4, UInt64(import_size));
    coff_put_word(bytes, header + 112 + 5 * 8, 4, UInt64(reloc_rva));
    coff_put_word(bytes, header + 116 + 5 * 8, 4, UInt64(reloc_size));
    coff_put_word(bytes, header + 112 + 12 * 8, 4, UInt64(iat_rva));
    coff_put_word(bytes, header + 116 + 12 * 8, 4, UInt64(iat_size));

    i = 0;
    while (i < layout.sections.length()) {
        let section = layout.sections[i];
        let offset = 328 + i * 40;
        let j = 0;
        while (j < section.name.length()) {
            bytes[offset + j] = section.name[j];
            j++;
        }

        coff_put_word(bytes, offset + 8, 4, UInt64(section.size));
        coff_put_word(bytes, offset + 12, 4, UInt64(section.rva));
        coff_put_word(bytes, offset + 16, 4, UInt64(section.raw_size));
        coff_put_word(bytes, offset + 20, 4, UInt64(section.raw_offset));
        coff_put_word(bytes, offset + 36, 4, UInt64(section.flags));
        i++;
    }
    return bytes;
}

func write_pe(objects: Vector(CoffObject), options: PeOptions) -> PeImageResult {
// the driver remains separate, this stage has no filesystem or toolchain dependencies
    if (options.entry.length() == 0 || (options.image_base & 65535UL) != 0UL || options.stack_commit == 0UL ||
        options.stack_reserve < options.stack_commit || options.heap_commit == 0UL || options.heap_reserve < options.heap_commit) {
        return pe_image_error(CoffLinkStatus.InvalidLayout, -1, -1, "Invalid PE image options");
    }
    let inputs: Vector(CoffObject) = [];
    let n = 0;
    while (n < objects.length()) { inputs.append(objects[n]); n++; }
    let imported = PeImports();
    let import_id = -1;
    if (options.imports.length() != 0) {
        let selected = pe_select_imports(objects, options.imports);
        if (selected.errors.length() != 0) { return PeImageResult(errors=selected.errors); }
        imported = pe_make_imports(selected.entries, selected.direct);
        if (imported.errors.length() != 0) { return PeImageResult(errors=imported.errors); }
        if (imported.object is !null) {
            let generated: CoffObject = imported.object;
            import_id = inputs.length();
            inputs.append(generated);
        }
    }

    let symbols = coff_resolve_symbols(inputs);
    if (symbols.errors.length() != 0) { return PeImageResult(errors=symbols.errors); }
    let planned = plan_pe(inputs, import_id);
    if (planned.layout is null) { return PeImageResult(errors=planned.errors); }
    let layout: PeLayout = planned.layout;
    if (Int128(UInt128(options.image_base)) + Int128(layout.image_size) > Int128(UInt128(18446744073709551615UL))) {
        return pe_image_error(CoffLinkStatus.InvalidLayout, -1, -1, "PE image address range exceeds 64-bit addressing");
    }
    let entry = pe_entry(inputs, options.entry);
    if (entry.object < 0) {
        return pe_image_error(CoffLinkStatus.UndefinedSymbol, -1, -1, "PE entry symbol '" + options.entry + "' is not defined");
    }
    if (entry.object == import_id) {
        return pe_image_error(CoffLinkStatus.InvalidLayout, -1, -1, "PE entry must be defined by an input object, not a DLL import");
    }
    let definition = inputs[entry.object].symbols[entry.symbol];
    let input = inputs[entry.object].sections[definition.section - 1];
    let place = layout.placements[entry.object][definition.section - 1];
    if (place.section == 0 || definition.value >= input.size || (input.flags & 0x20000000U) == 0U || input.data.size == 0) {
        return pe_image_error(CoffLinkStatus.InvalidLayout, entry.object, definition.section - 1, "PE entry must point into initialized executable storage");
    }
    let entry_rva = place.rva + definition.value;

    let data: Vector(Vector(Byte)) = [];
    let fixups: Vector(CoffBaseReloc) = [];
    let fixed = false;
    let i = 0;
    while (i < layout.sections.length()) {
        let section = layout.sections[i];
        let bytes: Vector(Byte) = [];
        pe_zeros(ref bytes, Int(section.initialized_size));
        let j = 0;
        while (j < section.parts.length()) {
            let part = section.parts[j];
            let patched = coff_apply_section(inputs, symbols, layout.placements, options.image_base, part.object, part.section);
            if (patched.patch is null) {
                if (patched.diagnostic is !null) { return PeImageResult(errors=[patched.diagnostic]); }
                return pe_image_error(CoffLinkStatus.InvalidObject, part.object, part.section, "Relocation application produced no section");
            }
            let patch: CoffPatch = patched.patch;
            let offset = Int(layout.placements[part.object][part.section].offset);
            let k = 0;
            while (k < patch.bytes.length()) {
                bytes[offset + k] = patch.bytes[k];
                k++;
            }

            k = 0;
            while (k < patch.base_relocs.length()) {
                let fixup = patch.base_relocs[k];
                // a 32-bit absolute address cannot survive high-address rebasing on AMD64.
                if (fixup.kind == 3U) { fixed = true; }
                fixups.append(fixup);
                k++;
            }
            if (patch.fixed_base) { fixed = true; }
            j++;
        }
        data.append(bytes);
        i++;
    }

    let reloc_rva = 0U;
    let reloc_size = 0U;
    // RIP-relative images need no fixup table, they still allow the loader to choose a base.
    if (!fixed && fixups.length() != 0) {
        let encoded = pe_base_relocs(fixups);
        if (encoded.message.length() != 0) {
            return pe_image_error(CoffLinkStatus.InvalidObject, -1, -1, encoded.message);
        }
        let raw_size = pe_align(Long(encoded.bytes.length()), 512);
        let image_size = pe_align(Long(layout.image_size) + Long(encoded.bytes.length()), 4096);
        if (Long(layout.file_size) + raw_size > 2147483647L || image_size > 2147483647L ||
            Int128(UInt128(options.image_base)) + Int128(image_size) > Int128(UInt128(18446744073709551615UL))) {
            return pe_image_error(CoffLinkStatus.InvalidLayout, -1, -1, "PE relocation section exceeds the image range");
        }
        reloc_rva = layout.image_size;
        reloc_size = UInt32(encoded.bytes.length());
        layout.sections.append(PeSection(name=[Byte(46), Byte(114), Byte(101), Byte(108), Byte(111), Byte(99)], flags=0x42000040U,
            size=reloc_size, initialized_size=reloc_size, rva=reloc_rva, raw_offset=layout.file_size, raw_size=UInt32(raw_size)));
        data.append(encoded.bytes);
        layout.file_size += UInt32(raw_size);
        layout.image_size = UInt32(image_size);
    }

    let import_rva = 0U;
    let iat_rva = 0U;
    if (import_id >= 0) {
        import_rva = layout.placements[import_id][0].rva;
        iat_rva = import_rva + imported.iat_offset;
    }
    let bytes = pe_headers(layout, options, entry_rva, reloc_rva, reloc_size, fixed,
        import_rva, imported.directory_size, iat_rva, imported.iat_size);
    i = 0;
    while (i < layout.sections.length()) {
        let section = layout.sections[i];
        if (section.raw_size != 0U) {
            pe_zeros(ref bytes, Int(section.raw_offset));
            let j = 0;
            while (j < data[i].length()) {
                bytes.append(data[i][j]);
                j++;
            }
            pe_zeros(ref bytes, Int(section.raw_offset + section.raw_size));
        }
        i++;
    }

    return PeImageResult(image=PeImage(bytes, layout, entry_rva, fixed));
}
