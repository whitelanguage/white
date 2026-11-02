// src/linker/coff/extract.wl
import * from "model.wl"
import * from "archive_model.wl"
import CoffSymbolRef, CoffLinkError, CoffLinkStatus from "link_model.wl"
import CoffNameIndex, coff_name_slot, coff_resolve_symbols from "symbols.wl"
import archive_find from "archive.wl"
import read_coff from "reader.wl"


struct ArchiveSelection(objects: Vector(CoffObject) = [], errors: Vector(CoffLinkError) = [], library: Int = -1)

func archive_add_symbols(objects: Vector(CoffObject), id: Int, ref names: CoffNameIndex, work: Vector(CoffSymbolRef)) -> Void {
// definitions are registered before the work queue advances, cycles do not reload members
    let object = objects[id];
    for (let s = 0; s < object.symbols.length(); s++) {
        let symbol = object.symbols[s];
        if (symbol.storage == Byte(2) && (symbol.section > 0 || symbol.section == -1)) {
            let slot = coff_name_slot(objects, ref names, CoffSymbolRef(id, s));
            if (names.entries[slot].definition.object < 0) { names.entries[slot].definition = CoffSymbolRef(id, s); }
        }
    }
    for (let sec = 0; sec < object.sections.length(); sec++) {
        let relocs = object.sections[sec].relocs;
        for (let r = 0; r < relocs.length(); r++) {
            let s = relocs[r].symbol;
            let symbol = object.symbols[s];
            if (symbol.storage == Byte(2) && symbol.section == 0 && symbol.value == 0U) {
                work.append(CoffSymbolRef(id, s));
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
    let work: Vector(CoffSymbolRef) = [];
    for (let i = 0; i < inputs.length(); i++) { objects.append(inputs[i]); }
    for (let obj = 0; obj < objects.length(); obj++) { archive_add_symbols(objects, obj, ref names, work); }
    let loaded: Vector(Vector(Bool)) = [];
    for (let lib = 0; lib < archives.length(); lib++) {
        let flags: Vector(Bool) = [];
        for (let m = 0; m < archives[lib].members.length(); m++) { flags.append(false); }
        loaded.append(flags);
    }
    let queried: Dict(Int, Bool) = Dict();
    let cursor = 0;
    while (cursor < work.length()) {
        let demand = work[cursor];
        cursor++;
        let slot = coff_name_slot(objects, ref names, demand);
        if (names.entries[slot].definition.object >= 0 || queried.contains_key(slot)) { continue; }
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
            if (names.entries[slot].definition.object < 0) {
                return ArchiveSelection(library=lib, errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=lib,
                    offset=UInt32(archive.members[member_id].header), message="Archive directory names a symbol which its selected member does not define")]);
            }
            break;
        }
    }
    return ArchiveSelection(objects=objects);
}
