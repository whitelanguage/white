// src/linker/coff/extract.wl
import * from "model.wl"
import * from "archive_model.wl"
import CoffSymbolRef, CoffLinkError, CoffLinkStatus from "link_model.wl"
import CoffNameIndex, coff_name_slot, coff_same_name, coff_resolve_symbols, coff_register_aliases, coff_register_object_aliases, coff_is_common, coff_define_symbol from "symbols.wl"
import archive_find from "archive.wl"
import read_coff from "reader.wl"
import coff_select_objects, coff_select_object, coff_prepare_selection from "comdat.wl"
import CoffDirectives, coff_collect_directives, coff_add_directives from "directives.wl"
import coff_is_import, read_coff_import from "import_object.wl"
import PeImport from "../pe/model.wl"
import pe_import_symbol from "../pe/imports.wl"


struct ArchiveSelection(objects: Vector(CoffObject) = [], imports: Vector(PeImport) = [], errors: Vector(CoffLinkError) = [], library: Int = -1, pending_libraries: Bool = false)
struct ArchiveDemand(symbol: CoffSymbolRef, required: Bool = true)

struct ArchiveWork(
    objects: Vector(CoffObject) = [],
    names: CoffNameIndex = CoffNameIndex(),
    leaders: CoffNameIndex = CoffNameIndex(),
    directives: CoffDirectives = CoffDirectives(),
    work: Vector(ArchiveDemand) = [],
    imports: Vector(PeImport) = [],
    import_names: CoffObject = CoffObject(),
    import_id: Int = -1,
    loaded: Vector(Vector(Int)) = [],
    queried: Dict(Int, Int) = Dict(),
    demanded: Dict(Int, Bool) = Dict(),
    followed: Dict(Int, Bool) = Dict(),
    unresolved: Vector(CoffSymbolRef) = [],
    cursor: Int = 0,
    errors: Vector(CoffLinkError) = []
)

func archive_defines_name(objects: Vector(CoffObject), id: Int, demand: CoffSymbolRef) -> Bool {
// a replaced COMDAT may have defined this name, that is different from a corrupt archive directory
    let object = objects[id];
    for (let s = 0; s < object.symbols.length(); s++) {
        let symbol = object.symbols[s];
        if ((symbol.storage == Byte(2) && (symbol.section > 0 || symbol.section == -1 || coff_is_common(symbol))) ||
            symbol.storage == Byte(105)) {
            if (coff_same_name(objects, CoffSymbolRef(id, s), demand)) { return true; }
        }
    }
    return false;
}

func archive_add_symbols(objects: Vector(CoffObject), id: Int, ref names: CoffNameIndex, work: Vector(ArchiveDemand)) -> Void {
// definitions are registered before the work queue advances, cycles do not reload members
    let object = objects[id];
    for (let s = 0; s < object.symbols.length(); s++) {
        let symbol = object.symbols[s];
        if (symbol.section > 0 && object.sections[symbol.section - 1].discarded) { continue; }
        if (symbol.storage == Byte(2) && (symbol.section > 0 || symbol.section == -1 || coff_is_common(symbol))) {
            coff_define_symbol(objects, ref names, CoffSymbolRef(id, s));
        }
        if (symbol.storage == Byte(105)) {
            // a newly loaded alias can satisfy an earlier demand which found no archive member.
            work.append(ArchiveDemand(CoffSymbolRef(id, s), false));
        }
    }
    for (let sec = 0; sec < object.sections.length(); sec++) {
        if (object.sections[sec].discarded) { continue; }
        let relocs = object.sections[sec].relocs;
        for (let r = 0; r < relocs.length(); r++) {
            let s = relocs[r].symbol;
            let symbol = object.symbols[s];
            let discarded = symbol.section > 0 && object.sections[symbol.section - 1].discarded;
            if ((symbol.storage == Byte(2) || symbol.storage == Byte(105)) &&
                ((symbol.section == 0 && symbol.value == 0U) || discarded)) {
                work.append(ArchiveDemand(CoffSymbolRef(id, s)));
            }
        }
    }
}

func archive_add_roots(object: CoffObject, id: Int, work: Vector(ArchiveDemand)) -> Void {
// the name-only object also holds directive roots, they have no relocation section to walk
    for (let s = 0; s < object.symbols.length(); s++) {
        if (object.symbols[s].section == 0) { work.append(ArchiveDemand(CoffSymbolRef(id, s))); }
    }
}

func begin_archive_work(inputs: Vector(CoffObject)) -> ArchiveWork {
// retain the name index while the driver discovers additional default libraries
    let chosen = coff_select_objects(inputs);
    if (chosen.errors.length() != 0) { return ArchiveWork(errors=chosen.errors); }
    let directives = coff_collect_directives(chosen.objects);
    if (directives.errors.length() != 0) { return ArchiveWork(errors=directives.errors); }
    let checked = coff_resolve_symbols(chosen.objects);
    for (let e = 0; e < checked.errors.length(); e++) {
        if (checked.errors[e].status != CoffLinkStatus.UndefinedSymbol) { return ArchiveWork(errors=checked.errors); }
    }
    let objects: Vector(CoffObject) = [];
    let names = CoffNameIndex();
    let work: Vector(ArchiveDemand) = [];
    for (let i = 0; i < chosen.objects.length(); i++) { objects.append(chosen.objects[i]); }
    for (let obj = 0; obj < objects.length(); obj++) { archive_add_symbols(objects, obj, ref names, work); }
    let aliases = coff_register_aliases(objects, ref names);
    if (aliases.length() != 0) { return ArchiveWork(errors=aliases); }
    // this name-only object lives in the extraction index, it must never reach relocation or PE layout.
    let import_names = CoffObject();
    let import_id = objects.length();
    for (let root = 0; root < directives.roots.length(); root++) {
        pe_import_symbol(ref import_names, directives.roots[root], 0, 0U, true);
    }
    objects.append(import_names);
    archive_add_roots(import_names, import_id, work);
    return ArchiveWork(objects=objects, names=names, leaders=chosen.leaders, directives=directives,
        work=work, import_names=import_names, import_id=import_id);
}

func resume_archive_work(ref state: ArchiveWork, archives: Vector(CoffArchive), enabled: Optional(Vector(Bool)) = null) -> ArchiveSelection {
// only unresolved demands revisit newly added libraries, existing members and definitions stay indexed
    if (state.errors.length() != 0) { return ArchiveSelection(errors=state.errors); }
    if (archives.length() < state.loaded.length()) {
        return ArchiveSelection(errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=-1,
            message="Archive discovery cannot remove previously indexed libraries")]);
    }
    if (enabled is !null) {
        let active: Vector(Bool) = enabled;
        if (active.length() != archives.length()) {
            return ArchiveSelection(errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=-1,
                message="Archive exclusion mask does not match the library list")]);
        }
    }
    let first_library = state.loaded.length();
    for (let lib = first_library; lib < archives.length(); lib++) {
        let flags: Vector(Int) = [];
        for (let m = 0; m < archives[lib].members.length(); m++) { flags.append(-1); }
        state.loaded.append(flags);
    }
    if (first_library < archives.length()) {
        for (let missing = 0; missing < state.unresolved.length(); missing++) {
            state.work.append(ArchiveDemand(state.unresolved[missing]));
        }
        state.unresolved = [];
    }
    let epoch = state.directives.library_epoch;
    while (state.cursor < state.work.length()) {
        let request = state.work[state.cursor];
        let demand = request.symbol;
        state.cursor++;
        let slot = coff_name_slot(state.objects, ref state.names, demand);
        if (!request.required && !state.demanded.contains_key(slot)) { continue; }
        state.demanded.put(slot, true);
        if (state.names.entries[slot].definition.object >= 0) { continue; }
        let fallback = state.names.entries[slot].fallback;
        if (fallback.object >= 0) {
            // NOLIBRARY and ALIAS do not pull a same-named provider from a library.
            if (!state.followed.contains_key(slot)) {
                state.followed.put(slot, true);
                state.work.append(ArchiveDemand(fallback));
            }
            continue;
        }
        let previous = state.queried.lookup(slot);
        let search_from = 0;
        if (previous is !null) {
            if (previous >= archives.length()) { continue; }
            search_from = previous;
        }
        state.queried.put(slot, archives.length());

        for (let lib = search_from; lib < archives.length(); lib++) {
            if (enabled is !null) {
                let active: Vector(Bool) = enabled;
                if (lib >= active.length() || !active[lib]) { continue; }
            }
            let archive = archives[lib];
            let member_id = archive_find(archive, state.objects[demand.object], state.objects[demand.object].symbols[demand.symbol].name);
            if (member_id < 0) { continue; }
            if (state.loaded[lib][member_id] >= 0) {
                if (archive_defines_name(state.objects, state.loaded[lib][member_id], demand)) { continue; }
                return ArchiveSelection(library=lib, errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=lib,
                    message="Archive directory names a symbol which its selected member does not define")]);
            }
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
                state.loaded[lib][member_id] = state.import_id;
                let first = state.import_names.symbols.length();
                if (!entry.is_data || entry.is_const) { pe_import_symbol(ref state.import_names, entry.symbol, -1, 0U, true); }
                pe_import_symbol(ref state.import_names, "__imp_" + entry.symbol, -1, 0U, true);
                state.objects[state.import_id] = state.import_names;
                for (let imp = first; imp < state.import_names.symbols.length(); imp++) {
                    let import_slot = coff_name_slot(state.objects, ref state.names, CoffSymbolRef(state.import_id, imp));
                    if (state.names.entries[import_slot].definition.object < 0) {
                        state.names.entries[import_slot].definition = CoffSymbolRef(state.import_id, imp);
                    }
                }
                state.imports.append(entry);
            } else {
                let decoded = read_coff(bytes);
                if (decoded.object is null) {
                    let status = CoffLinkStatus.InvalidObject;
                    if (decoded.status == CoffError.UnsupportedObject) { status = CoffLinkStatus.Unsupported; }
                    return ArchiveSelection(library=lib, errors=[CoffLinkError(status=status, object=lib,
                        offset=UInt32(span.offset + decoded.offset), message="Selected archive member: " + decoded.message)]);
                }
                let member: CoffObject = decoded.object;
                let id = state.objects.length();
                let first_root = state.directives.roots.length();
                coff_add_directives(ref state.directives, member, id);
                if (state.directives.errors.length() != 0) {
                    for (let error_id = 0; error_id < state.directives.errors.length(); error_id++) {
                        state.directives.errors[error_id].offset += UInt32(span.offset);
                    }
                    return ArchiveSelection(library=lib, errors=state.directives.errors);
                }
                for (let new_root = first_root; new_root < state.directives.roots.length(); new_root++) {
                    let root_symbol = pe_import_symbol(ref state.import_names, state.directives.roots[new_root], 0, 0U, true);
                    state.work.append(ArchiveDemand(CoffSymbolRef(state.import_id, root_symbol)));
                }
                state.objects[state.import_id] = state.import_names;
                state.objects.append(coff_prepare_selection(member));
                state.loaded[lib][member_id] = id;
                let step = coff_select_object(state.objects, id, ref state.leaders);
                if (step.errors.length() != 0) { return ArchiveSelection(library=lib, errors=step.errors); }
                if (step.replaced) {
                    // this slow path runs only when LARGEST changes a winner. Dropped definitions,
                    // alias traversal and relocation demands must all refer to the same selection.
                    // Members already extracted stay loaded, their ordinary sections still count.
                    state.names = CoffNameIndex();
                    state.work = [];
                    for (let rebuild = 0; rebuild < state.objects.length(); rebuild++) {
                        archive_add_symbols(state.objects, rebuild, ref state.names, state.work);
                    }
                    archive_add_roots(state.import_names, state.import_id, state.work);
                    let rebuilt_aliases = coff_register_aliases(state.objects, ref state.names);
                    if (rebuilt_aliases.length() != 0) { return ArchiveSelection(library=lib, errors=rebuilt_aliases); }
                    state.queried = Dict();
                    state.unresolved = [];
                    state.demanded = Dict();
                    state.followed = Dict();
                    state.cursor = 0;
                    slot = coff_name_slot(state.objects, ref state.names, demand);
                } else {
                    archive_add_symbols(state.objects, id, ref state.names, state.work);
                    let added_aliases = coff_register_object_aliases(state.objects, id, ref state.names);
                    if (added_aliases.length() != 0) { return ArchiveSelection(library=lib, errors=added_aliases); }
                }
            }
            if (state.names.entries[slot].definition.object < 0 && state.names.entries[slot].fallback.object < 0 &&
                !archive_defines_name(state.objects, state.loaded[lib][member_id], demand)) {
                return ArchiveSelection(library=lib, errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=lib,
                    offset=UInt32(archive.members[member_id].header), message="Archive directory names a symbol which its selected member does not define")]);
            }
            break;
        }
        if (state.names.entries[slot].definition.object < 0 && state.names.entries[slot].fallback.object < 0) {
            state.unresolved.append(demand);
        }
        if (epoch != state.directives.library_epoch) { return ArchiveSelection(pending_libraries=true); }
    }
    let selected: Vector(CoffObject) = [];
    for (let selected_id = 0; selected_id < state.objects.length(); selected_id++) {
        if (selected_id != state.import_id) { selected.append(state.objects[selected_id]); }
    }
    return ArchiveSelection(objects=selected, imports=state.imports);
}

func extract_archives(inputs: Vector(CoffObject), archives: Vector(CoffArchive)) -> ArchiveSelection {
// filesystem-free callers can resolve supplied archives, default-library discovery belongs to the driver
    if (archives.length() == 0) {
        let chosen = coff_select_objects(inputs);
        return ArchiveSelection(objects=chosen.objects, errors=chosen.errors);
    }
    let state = begin_archive_work(inputs);
    if (state.errors.length() != 0) { return ArchiveSelection(errors=state.errors); }
    if (state.directives.libraries.length() != 0) {
        return ArchiveSelection(errors=[CoffLinkError(status=CoffLinkStatus.Unsupported, object=-1,
            message="COFF default libraries require driver discovery before archive extraction")]);
    }
    let result = resume_archive_work(ref state, archives);
    if (result.pending_libraries) {
        return ArchiveSelection(errors=[CoffLinkError(status=CoffLinkStatus.Unsupported, object=-1,
            message="COFF default libraries require driver discovery before archive extraction")]);
    }
    return result;
}
