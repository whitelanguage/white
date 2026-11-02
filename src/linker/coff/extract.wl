// src/linker/coff/extract.wl
import * from "model.wl"
import * from "archive_model.wl"
import CoffSymbolRef, CoffLinkError, CoffLinkStatus from "link_model.wl"
import CoffNameIndex, coff_name_slot, coff_resolve_symbols, coff_register_aliases, coff_register_object_aliases from "symbols.wl"
import archive_find from "archive.wl"
import read_coff from "reader.wl"
import coff_is_import, read_coff_import from "import_object.wl"
import PeImport from "../pe/model.wl"
import pe_import_symbol from "../pe/imports.wl"


struct ArchiveSelection(objects: Vector(CoffObject) = [], imports: Vector(PeImport) = [], errors: Vector(CoffLinkError) = [], library: Int = -1)
struct ArchiveDemand(symbol: CoffSymbolRef, required: Bool = true)

func archive_add_symbols(objects: Vector(CoffObject), id: Int, ref names: CoffNameIndex, work: Vector(ArchiveDemand)) -> Void {
// definitions are registered before the work queue advances, cycles do not reload members
    let object = objects[id];
    for (let s = 0; s < object.symbols.length(); s++) {
        let symbol = object.symbols[s];
        if (symbol.storage == Byte(2) && (symbol.section > 0 || symbol.section == -1)) {
            let slot = coff_name_slot(objects, ref names, CoffSymbolRef(id, s));
            if (names.entries[slot].definition.object < 0) { names.entries[slot].definition = CoffSymbolRef(id, s); }
        }
        if (symbol.storage == Byte(105)) {
            // a newly loaded alias can satisfy an earlier demand which found no archive member.
            work.append(ArchiveDemand(CoffSymbolRef(id, s), false));
        }
    }
    for (let sec = 0; sec < object.sections.length(); sec++) {
        let relocs = object.sections[sec].relocs;
        for (let r = 0; r < relocs.length(); r++) {
            let s = relocs[r].symbol;
            let symbol = object.symbols[s];
            if ((symbol.storage == Byte(2) || symbol.storage == Byte(105)) && symbol.section == 0 && symbol.value == 0U) {
                work.append(ArchiveDemand(CoffSymbolRef(id, s)));
            }
        }
    }
}

func extract_archives(inputs: Vector(CoffObject), archives: Vector(CoffArchive)) -> ArchiveSelection {
// a dependency queue avoids rerunning whole-object symbol resolution after each extraction
    if (archives.length() == 0) { return ArchiveSelection(objects=inputs); }
    let checked = coff_resolve_symbols(inputs);
    for (let e = 0; e < checked.errors.length(); e++) {
        if (checked.errors[e].status != CoffLinkStatus.UndefinedSymbol) { return ArchiveSelection(errors=checked.errors); }
    }
    let objects: Vector(CoffObject) = [];
    let names = CoffNameIndex();
    let work: Vector(ArchiveDemand) = [];
    for (let i = 0; i < inputs.length(); i++) { objects.append(inputs[i]); }
    for (let obj = 0; obj < objects.length(); obj++) { archive_add_symbols(objects, obj, ref names, work); }
    let aliases = coff_register_aliases(objects, ref names);
    if (aliases.length() != 0) { return ArchiveSelection(errors=aliases); }
    // this name-only object lives in the extraction index, it must never reach relocation or PE layout.
    let import_names = CoffObject();
    let import_id = objects.length();
    objects.append(import_names);
    let imports: Vector(PeImport) = [];
    let loaded: Vector(Vector(Bool)) = [];
    for (let lib = 0; lib < archives.length(); lib++) {
        let flags: Vector(Bool) = [];
        for (let m = 0; m < archives[lib].members.length(); m++) { flags.append(false); }
        loaded.append(flags);
    }
    let queried: Dict(Int, Bool) = Dict();
    let demanded: Dict(Int, Bool) = Dict();
    let followed: Dict(Int, Bool) = Dict();
    let cursor = 0;
    while (cursor < work.length()) {
        let request = work[cursor];
        let demand = request.symbol;
        cursor++;
        let slot = coff_name_slot(objects, ref names, demand);
        if (!request.required && !demanded.contains_key(slot)) { continue; }
        demanded.put(slot, true);
        if (names.entries[slot].definition.object >= 0) { continue; }
        let fallback = names.entries[slot].fallback;
        if (fallback.object >= 0) {
            // NOLIBRARY and ALIAS do not pull a same-named provider from a library.
            if (!followed.contains_key(slot)) {
                followed.put(slot, true);
                work.append(ArchiveDemand(fallback));
            }
            continue;
        }
        if (queried.contains_key(slot)) { continue; }
        queried.put(slot, true);

        for (let lib = 0; lib < archives.length(); lib++) {
            let archive = archives[lib];
            let member_id = archive_find(archive, objects[demand.object], objects[demand.object].symbols[demand.symbol].name);
            if (member_id < 0) { continue; }
            if (loaded[lib][member_id]) {
                return ArchiveSelection(library=lib, errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=lib,
                    message="Archive directory names a symbol which its selected member does not define")]);
            }
            loaded[lib][member_id] = true;
            let span = archive.members[member_id].data;
            let bytes: Vector(Byte) = [];
            for (let b = 0; b < span.size; b++) { bytes.append(archive.bytes[span.offset + b]); }
            if (coff_is_import(bytes)) {
                let decoded_import = read_coff_import(bytes);
                if (decoded_import.entry is null) {
                    let status = CoffLinkStatus.InvalidObject;
                    if (decoded_import.status == CoffError.UnsupportedObject) { status = CoffLinkStatus.Unsupported; }
                    return ArchiveSelection(library=lib, errors=[CoffLinkError(status=status, object=lib,
                        offset=UInt32(span.offset + decoded_import.offset), message="Selected archive member: " + decoded_import.message)]);
                }
                let entry: PeImport = decoded_import.entry;
                let first = import_names.symbols.length();
                if (!entry.is_data || entry.is_const) { pe_import_symbol(ref import_names, entry.symbol, -1, 0U, true); }
                pe_import_symbol(ref import_names, "__imp_" + entry.symbol, -1, 0U, true);
                objects[import_id] = import_names;
                for (let imp = first; imp < import_names.symbols.length(); imp++) {
                    let import_slot = coff_name_slot(objects, ref names, CoffSymbolRef(import_id, imp));
                    if (names.entries[import_slot].definition.object < 0) {
                        names.entries[import_slot].definition = CoffSymbolRef(import_id, imp);
                    }
                }
                imports.append(entry);
            } else {
                let decoded = read_coff(bytes);
                if (decoded.object is null) {
                    let status = CoffLinkStatus.InvalidObject;
                    if (decoded.status == CoffError.UnsupportedObject) { status = CoffLinkStatus.Unsupported; }
                    return ArchiveSelection(library=lib, errors=[CoffLinkError(status=status, object=lib,
                        offset=UInt32(span.offset + decoded.offset), message="Selected archive member: " + decoded.message)]);
                }
                let member: CoffObject = decoded.object;
                let id = objects.length();
                objects.append(member);
                archive_add_symbols(objects, id, ref names, work);
                let added_aliases = coff_register_object_aliases(objects, id, ref names);
                if (added_aliases.length() != 0) { return ArchiveSelection(library=lib, errors=added_aliases); }
            }
            if (names.entries[slot].definition.object < 0 && names.entries[slot].fallback.object < 0) {
                return ArchiveSelection(library=lib, errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=lib,
                    offset=UInt32(archive.members[member_id].header), message="Archive directory names a symbol which its selected member does not define")]);
            }
            break;
        }
    }
    let selected: Vector(CoffObject) = [];
    for (let selected_id = 0; selected_id < objects.length(); selected_id++) {
        if (selected_id != import_id) { selected.append(objects[selected_id]); }
    }
    return ArchiveSelection(objects=selected, imports=imports);
}
