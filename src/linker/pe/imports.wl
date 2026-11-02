// src/linker/pe/imports.wl
// import descriptors and 64-bit thunk fields follow the PE32+ loader format
import PeImport from "model.wl"
import * from "../coff/model.wl"
import * from "../coff/link_model.wl"
import * from "../coff/symbols.wl"
import coff_name_matches from "../coff/reader.wl"
import coff_put_word from "../coff/reloc.wl"
import pe_emit_word from "reloc.wl"


struct PeImportSelection(entries: Vector(PeImport) = [], direct: Vector(Bool) = [], errors: Vector(CoffLinkError) = [])
struct PeImports(object: Optional(CoffObject) = null, directory_size: UInt32 = 0U, iat_offset: UInt32 = 0U, iat_size: UInt32 = 0U, errors: Vector(CoffLinkError) = [])
struct PeImportDll(name: String, members: Vector(Int) = [])
struct PeImportSlot(source: PeImport, iat: Int = 0, thunk: Int = -1)

func pe_import_error(message: String) -> CoffLinkError {
    return CoffLinkError(status=CoffLinkStatus.InvalidLayout, object=-1, message=message);
}

func pe_import_span(ref object: CoffObject, text: String) -> CoffSpan {
    let offset = object.bytes.length();
    let i = 0;
    while (i < text.length()) {
        object.bytes.append(text[i]);
        i++;
    }
    return CoffSpan(offset, text.length());
}

func pe_import_symbol(ref object: CoffObject, name: String, section: Int, value: UInt32, external: Bool) -> Int {
    let id = object.symbols.length();
    let span = pe_import_span(ref object, name);
    let storage = Byte(3);
    if external { storage = Byte(2); }
    object.symbols.append(CoffSymbol(name=span, value=value, section=section, type=0U, storage=storage, table_index=id, aux=CoffSpan()));
    object.symbol_map.append(id);
    return id;
}

func pe_import_dll(name: String) -> String {
// PE names are ASCII, fold only the DLL spelling, export names remain case-sensitive
    if (name.length() > 255) { return ""; }
    let result = "";
    let i = 0;
    while (i < name.length()) {
        let byte = Int(name[i]);
        if (byte < 32 || byte > 126 || byte == 47 || byte == 92 || byte == 58) { return ""; }
        if (byte >= 65 && byte <= 90) { byte += 32; }
        result += String(Char(byte));
        i++;
    }
    if (result == "." || result == "..") { return ""; }
    return result;
}

func pe_import_name(name: String, ascii: Bool) -> Bool {
    let i = 0;
    while (i < name.length()) {
        let byte = Int(name[i]);
        if (byte == 0 || (ascii && (byte < 32 || byte > 126))) { return false; }
        i++;
    }
    return name.length() != 0;
}

func pe_same_import(left: PeImport, right: PeImport) -> Bool {
    if (left.dll != right.dll || left.name != right.name || left.is_data != right.is_data || left.is_const != right.is_const) { return false; }
    if (left.ordinal is null) { return right.ordinal is null; }
    if (right.ordinal is null) { return false; }
    let a: UInt32 = left.ordinal;
    let b: UInt32 = right.ordinal;
    return a == b;
}

func pe_select_imports(objects: Vector(CoffObject), requests: Vector(PeImport)) -> PeImportSelection {
// collect unresolved references first, strong object definitions take precedence over import metadata
    let unresolved = coff_resolve_symbols(objects);
    let i = 0;
    while (i < unresolved.errors.length()) {
        if (unresolved.errors[i].status != CoffLinkStatus.UndefinedSymbol) {
            return PeImportSelection(errors=unresolved.errors);
        }
        i++;
    }

    let normalized: Vector(PeImport) = [];
    let query = CoffObject();
    let normalized_ids: Vector(Int) = [];
    i = 0;
    while (i < requests.length()) {
        let item = requests[i];
        item.dll = pe_import_dll(item.dll);
        if (item.symbol.length() == 0) { item.symbol = item.name; }
        if (item.dll.length() == 0 || !pe_import_name(item.symbol, false) || item.symbol.starts_with("__imp_") || item.hint > 65535U ||
            (item.is_const && !item.is_data)) {
            return PeImportSelection(errors=[pe_import_error("Invalid DLL import name, symbol or hint")]);
        }
        if (item.ordinal is !null) {
            let ordinal: UInt32 = item.ordinal;
            if (ordinal > 65535U || item.name.length() != 0 || item.hint != 0U) {
                return PeImportSelection(errors=[pe_import_error("Ordinal imports require a 16-bit ordinal and no export name or hint")]);
            }
        } else if (!pe_import_name(item.name, true)) {
            return PeImportSelection(errors=[pe_import_error("Named imports require a nonempty ASCII export name")]);
        }
        normalized.append(item);
        if (!item.is_data || item.is_const) {
            pe_import_symbol(ref query, item.symbol, 0, 0U, true);
            normalized_ids.append(i);
        }
        pe_import_symbol(ref query, "__imp_" + item.symbol, 0, 0U, true);
        normalized_ids.append(i);
        i++;
    }

    // keep source object vectors untouched, symbol names are spans into the extra query buffer.
    let inputs: Vector(CoffObject) = [];
    i = 0;
    while (i < objects.length()) {
        inputs.append(objects[i]);
        i++;
    }
    let query_id = inputs.length();
    inputs.append(query);
    let names = CoffNameIndex();
    let slots: Dict(Int, Int) = Dict();
    i = 0;
    while (i < query.symbols.length()) {
        let slot = coff_name_slot(inputs, ref names, CoffSymbolRef(query_id, i));
        let previous = slots.lookup(slot);
        let id = normalized_ids[i];
        if (previous is !null) {
            let other: Int = previous;
            if (!pe_same_import(normalized[other], normalized[id])) {
                return PeImportSelection(errors=[pe_import_error("Conflicting DLL import definitions for '" + normalized[id].symbol + "'")]);
            }
        } else {
            slots.put(slot, id);
        }
        i++;
    }

    let used: Vector(Bool) = [];
    let direct: Vector(Bool) = [];
    i = 0;
    while (i < normalized.length()) {
        used.append(false);
        direct.append(false);
        i++;
    }
    let missing: Vector(CoffLinkError) = [];
    i = 0;
    while (i < unresolved.errors.length()) {
        let diagnostic = unresolved.errors[i];
        let reference = CoffSymbolRef(diagnostic.object, diagnostic.symbol);
        if (diagnostic.other.object >= 0) { reference = diagnostic.other; }
        let slot = coff_name_slot(inputs, ref names, reference);
        let found = slots.lookup(slot);
        if (found is null) { missing.append(diagnostic); }
        else {
            let id: Int = found;
            used[id] = true;
            let symbol = objects[reference.object].symbols[reference.symbol];
            if (coff_name_matches(objects[reference.object], symbol.name, normalized[id].symbol)) { direct[id] = true; }
        }
        i++;
    }
    if (missing.length() != 0) { return PeImportSelection(errors=missing); }

    let selected: Vector(PeImport) = [];
    let calls: Vector(Bool) = [];
    i = 0;
    while (i < normalized.length()) {
        if (used[i]) {
            selected.append(normalized[i]);
            calls.append(direct[i]);
        }
        i++;
    }
    return PeImportSelection(entries=selected, direct=calls);
}

func pe_import_zeros(ref bytes: Vector(Byte), size: Int) -> Void {
    while (bytes.length() < size) { bytes.append(Byte(0)); }
}

func pe_import_text(ref bytes: Vector(Byte), text: String) -> Int {
    let offset = bytes.length();
    let i = 0;
    while (i < text.length()) { bytes.append(text[i]); i++; }
    bytes.append(Byte(0));
    return offset;
}

func pe_import_rva(ref bytes: Vector(Byte), ref relocs: Vector(CoffReloc), field: Int, target: Int) -> Void {
// the low word carries an RVA addend, upper words of PE32+ name thunks remain zero
    coff_put_word(bytes, field, 4, UInt64(target));
    relocs.append(CoffReloc(UInt32(field), 0, 3U));
}

func pe_make_imports(entries: Vector(PeImport), direct: Vector(Bool)) -> PeImports {
// generated contributions use ordinary COFF relocations, the existing applicator fixes their RVAs
    if (direct.length() != entries.length()) { return PeImports(errors=[pe_import_error("Missing DLL import call selection")]); }
    if (entries.length() == 0) { return PeImports(); }
    let dlls: Vector(PeImportDll) = [];
    let dll_ids: Dict(String, Int) = Dict();
    let exports: Dict(String, Int) = Dict();
    let slots: Vector(PeImportSlot) = [];
    let bindings: Vector(Int) = [];
    let name_bytes = 0L;
    let i = 0;
    while (i < entries.length()) {
        let item = entries[i];
        let dll_id = dll_ids.lookup(item.dll);
        let group = dlls.length();
        if (dll_id is !null) { group = dll_id; }
        else {
            dlls.append(PeImportDll(item.dll));
            dll_ids.put(item.dll, group);
            name_bytes += Long(item.dll.length()) + 2L;
        }
        let key = String(group) + ":n:" + item.name;
        if (item.ordinal is !null) {
            let ordinal: UInt32 = item.ordinal;
            key = String(group) + ":o:" + String(ordinal);
        }
        let previous = exports.lookup(key);
        let slot = slots.length();
        if (previous is !null) { slot = previous; }
        else {
            slots.append(PeImportSlot(item));
            dlls[group].members.append(slot);
            exports.put(key, slot);
            if (item.ordinal is null) { name_bytes += Long(item.name.length()) + 4L; }
        }
        bindings.append(slot);
        name_bytes += Long(item.symbol.length()) * 2L + 6L;
        i++;
    }

    let directory_size = (Long(dlls.length()) + 1L) * 20L;
    let iat_start = ((directory_size + 7L) / 8L) * 8L;
    let table_size = (Long(slots.length()) + Long(dlls.length())) * 8L;
    let lookup_start = iat_start + table_size;
    let payload_start = lookup_start + table_size;
    if (payload_start + name_bytes + Long(entries.length()) * 6L + 32L > 2147483647L) {
        return PeImports(errors=[pe_import_error("DLL import storage exceeds the supported size")]);
    }

    let bytes: Vector(Byte) = [];
    pe_import_zeros(ref bytes, Int(payload_start));
    let relocs: Vector(CoffReloc) = [];
    let iat = Int(iat_start);
    let lookup = Int(lookup_start);
    i = 0;
    while (i < dlls.length()) {
        let dll = dlls[i];
        let descriptor = i * 20;
        let name = pe_import_text(ref bytes, dll.name);
        if ((bytes.length() & 1) != 0) { bytes.append(Byte(0)); }
        pe_import_rva(ref bytes, ref relocs, descriptor, lookup);
        pe_import_rva(ref bytes, ref relocs, descriptor + 12, name);
        pe_import_rva(ref bytes, ref relocs, descriptor + 16, iat);
        let j = 0;
        while (j < dll.members.length()) {
            let slot_id = dll.members[j];
            let slot = slots[slot_id];
            slot.iat = iat;
            if (slot.source.ordinal is !null) {
                let ordinal: UInt32 = slot.source.ordinal;
                let value = 9223372036854775808UL | UInt64(ordinal);
                coff_put_word(bytes, iat, 8, value);
                coff_put_word(bytes, lookup, 8, value);
            } else {
                name = bytes.length();
                pe_emit_word(ref bytes, UInt64(slot.source.hint), 2);
                pe_import_text(ref bytes, slot.source.name);
                if ((bytes.length() & 1) != 0) { bytes.append(Byte(0)); }
                pe_import_rva(ref bytes, ref relocs, iat, name);
                pe_import_rva(ref bytes, ref relocs, lookup, name);
            }
            slots[slot_id] = slot;
            iat += 8;
            lookup += 8;
            j++;
        }
        // each DLL has its own null terminator in both contiguous tables.
        iat += 8;
        lookup += 8;
        i++;
    }

    let object = CoffObject();
    pe_import_symbol(ref object, "", 1, 0U, false); // section-relative anchor for every RVA field
    let code: Vector(Byte) = [];
    let calls: Vector(CoffReloc) = [];
    i = 0;
    while (i < entries.length()) {
        let item = entries[i];
        let slot_id = bindings[i];
        let slot = slots[slot_id];
        let address = pe_import_symbol(ref object, "__imp_" + item.symbol, 1, UInt32(slot.iat), true);
        // IMPORT_CONST's public symbol also names the slot, callers load through it twice.
        if (item.is_const && direct[i]) { pe_import_symbol(ref object, item.symbol, 1, UInt32(slot.iat), true); }
        if (direct[i] && !item.is_data) {
            if (slot.thunk < 0) {
                slot.thunk = code.length();
                code.append(Byte(255));
                code.append(Byte(37));
                pe_emit_word(ref code, 0UL, 4);
                calls.append(CoffReloc(UInt32(slot.thunk + 2), address, 4U));
                slots[slot_id] = slot;
            }
            pe_import_symbol(ref object, item.symbol, 2, UInt32(slot.thunk), true);
        }
        i++;
    }

    let data_name = pe_import_span(ref object, ".idata");
    let text_name = pe_import_span(ref object, ".text$imports");
    let data_start = object.bytes.length();
    i = 0;
    while (i < bytes.length()) {
        object.bytes.append(bytes[i]);
        i++;
    }
    let code_start = object.bytes.length();
    i = 0;
    while (i < code.length()) {
        object.bytes.append(code[i]);
        i++;
    }
    object.sections.append(CoffSection(name=data_name, size=UInt32(bytes.length()), address=0U, data=CoffSpan(data_start, bytes.length()),
        flags=0xC0000040U, alignment=8, relocs=relocs, lines=CoffSpan()));
    object.sections.append(CoffSection(name=text_name, size=UInt32(code.length()), address=0U, data=CoffSpan(code_start, code.length()),
        flags=0x60000020U, alignment=2, relocs=calls, lines=CoffSpan()));

    return PeImports(object=object, directory_size=UInt32(directory_size), iat_offset=UInt32(iat_start), iat_size=UInt32(table_size));
}
