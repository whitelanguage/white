// src/linker/coff/symbols.wl
import * from "model.wl"
import * from "link_model.wl"
import coff_range from "reader.wl"


struct CoffNameEntry(name: CoffSymbolRef, definition: CoffSymbolRef = CoffSymbolRef(), next: Int = -1, fallback: CoffSymbolRef = CoffSymbolRef())
struct CoffNameIndex(buckets: Dict(UInt64, Int) = Dict(), entries: Vector(CoffNameEntry) = [])

func coff_address_symbol(symbol: CoffSymbol) -> Bool {
    return symbol.storage == Byte(2) || symbol.storage == Byte(3) || symbol.storage == Byte(6) || symbol.storage == Byte(104);
}

func coff_name_hash(bytes: Vector(Byte), name: CoffSpan) -> UInt64 {
// FNV-1a selects a bucket, full byte comparison still decides symbol identity
    let hash: UInt64 = 14695981039346656037UL;
    let i: Int = 0;
    while (i < name.size) {
        hash = (hash ^ UInt64(bytes[name.offset + i])) * 1099511628211UL;
        i++;
    }
    return hash;
}

func coff_same_name(objects: Vector(CoffObject), left: CoffSymbolRef, right: CoffSymbolRef) -> Bool {
    let a: CoffSpan = objects[left.object].symbols[left.symbol].name;
    let b: CoffSpan = objects[right.object].symbols[right.symbol].name;
    if (a.size != b.size) { return false; }

    let i: Int = 0;
    while (i < a.size) {
        if (objects[left.object].bytes[a.offset + i] != objects[right.object].bytes[b.offset + i]) { return false; }
        i++;
    }
    return true;
}

func coff_name_slot(objects: Vector(CoffObject), ref index: CoffNameIndex, name: CoffSymbolRef) -> Int {
// names remain in their object buffers, only integer indices enter the hash table
    let hash: UInt64 = coff_name_hash(objects[name.object].bytes, objects[name.object].symbols[name.symbol].name);
    let head: Int = -1;
    let found: Optional(Int) = index.buckets.lookup(hash);
    if (found is !null) { head = found; }
    let current: Int = head;
    while (current >= 0) {
        let entry: CoffNameEntry = index.entries[current];
        if (coff_same_name(objects, entry.name, name)) { return current; }
        current = entry.next;
    }

    let slot: Int = index.entries.length();
    index.entries.append(CoffNameEntry(name=name, next=head));
    index.buckets.put(hash, slot);
    return slot;
}

func coff_register_object_aliases(objects: Vector(CoffObject), id: Int, ref names: CoffNameIndex) -> Vector(CoffLinkError) {
// register after strong definitions, a real definition does not need its weak fallback
    let errors: Vector(CoffLinkError) = [];
    let object = objects[id];
    for (let s = 0; s < object.symbols.length(); s++) {
        let symbol = object.symbols[s];
        if (symbol.storage != Byte(2) && symbol.storage != Byte(105)) { continue; }
        let discarded = symbol.section > 0 && object.sections[symbol.section - 1].discarded;
        if (symbol.section != 0 && !discarded) { continue; }
        let slot = coff_name_slot(objects, ref names, CoffSymbolRef(id, s));
        if (symbol.storage != Byte(105)) { continue; }
        let target = CoffSymbolRef(id, symbol.weak_target);
        coff_name_slot(objects, ref names, target);
        if (names.entries[slot].definition.object >= 0) { continue; }
        let previous = names.entries[slot].fallback;
        if (previous.object >= 0 && !coff_same_name(objects, previous, target)) {
            errors.append(CoffLinkError(status=CoffLinkStatus.DuplicateSymbol, object=id, symbol=s, other=previous,
                message="Conflicting weak external fallbacks"));
        } else {
            names.entries[slot].fallback = target;
        }
    }
    return errors;
}

func coff_register_aliases(objects: Vector(CoffObject), ref names: CoffNameIndex) -> Vector(CoffLinkError) {
    let errors: Vector(CoffLinkError) = [];
    for (let obj = 0; obj < objects.length(); obj++) {
        let added = coff_register_object_aliases(objects, obj, ref names);
        for (let e = 0; e < added.length(); e++) { errors.append(added[e]); }
    }
    return errors;
}

func coff_bind_aliases(objects: Vector(CoffObject), ref names: CoffNameIndex) -> CoffSymbolResult {
// walk each alias edge once, compress completed chains and never recurse on object input
    let has_alias = false;
    for (let name = 0; name < names.entries.length(); name++) {
        if (names.entries[name].fallback.object >= 0) { has_alias = true; break; }
    }
    if (!has_alias) { return CoffSymbolResult(); }

    let next: Vector(Int) = [];
    let state: Vector(Byte) = [];
    for (let slot = 0; slot < names.entries.length(); slot++) {
        let fallback = names.entries[slot].fallback;
        let edge = -1;
        if (fallback.object >= 0) { edge = coff_name_slot(objects, ref names, fallback); }
        next.append(edge);
        state.append(Byte(0));
    }

    for (let start = 0; start < next.length(); start++) {
        if (state[start] == Byte(2)) { continue; }
        if (names.entries[start].definition.object >= 0) { state[start] = Byte(2); continue; }
        let path: Vector(Int) = [];
        let current = start;
        let definition = CoffSymbolRef();
        let missing = CoffSymbolRef();
        while true {
            let entry = names.entries[current];
            if (state[current] == Byte(2)) {
                definition = entry.definition;
                missing = entry.fallback;
                break;
            }
            if (state[current] == Byte(1)) {
                return CoffSymbolResult(errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject,
                    object=entry.name.object, symbol=entry.name.symbol, message="Weak external alias cycle")]);
            }
            state[current] = Byte(1);
            path.append(current);
            if (entry.definition.object >= 0) {
                definition = entry.definition;
                break;
            }
            if (next[current] < 0) {
                missing = entry.name;
                break;
            }
            current = next[current];
        }
        for (let p = 0; p < path.length(); p++) {
            let slot = path[p];
            names.entries[slot].definition = definition;
            names.entries[slot].fallback = missing;
            state[slot] = Byte(2);
        }
    }
    return CoffSymbolResult();
}

func coff_resolve_symbols(objects: Vector(CoffObject)) -> CoffSymbolResult {
// build definitions before binding references, input order cannot hide a definition
    let result: CoffSymbolResult = CoffSymbolResult();
    let names: CoffNameIndex = CoffNameIndex();
    let object_id: Int = 0;
    while (object_id < objects.length()) {
        let object: CoffObject = objects[object_id];
        let row: Vector(CoffSymbolRef) = [];
        let section_id: Int = 0;
        while (section_id < object.sections.length()) {
            if ((object.sections[section_id].flags & 4096U) != 0U) {
                if (!object.sections[section_id].selected) {
                    result.errors.append(CoffLinkError(status=CoffLinkStatus.Unsupported, object=object_id, section=section_id, message="COMDAT sections require selection before symbol resolution"));
                }
            }
            section_id++;
        }

        let symbol_id: Int = 0;
        while (symbol_id < object.symbols.length()) {
            let symbol: CoffSymbol = object.symbols[symbol_id];
            let target: CoffSymbolRef = CoffSymbolRef(object_id, symbol_id);
            row.append(CoffSymbolRef());
            if (!coff_range(object.bytes.length(), Long(symbol.name.offset), Long(symbol.name.size), 1) || symbol.section < -2 || symbol.section > object.sections.length()) {
                result.errors.append(CoffLinkError(status=CoffLinkStatus.InvalidObject, object=object_id, symbol=symbol_id, message="Invalid symbol record supplied to resolver"));
                symbol_id++;
                continue;
            }
            if (symbol.storage == Byte(105)) {
                if (symbol.section != 0 || symbol.value != 0U || symbol.aux.size != 18 ||
                    !coff_range(object.bytes.length(), Long(symbol.aux.offset), 18L, 1) ||
                    symbol.weak_target < 0 || symbol.weak_target >= object.symbols.length()) {
                    result.errors.append(CoffLinkError(status=CoffLinkStatus.InvalidObject, object=object_id, symbol=symbol_id, message="Invalid COFF weak external record"));
                } else if (symbol.weak_search != 1U && symbol.weak_search != 3U) {
                    result.errors.append(CoffLinkError(status=CoffLinkStatus.Unsupported, object=object_id, symbol=symbol_id, message="Unsupported COFF weak external search mode"));
                } else if (object.symbols[symbol.weak_target].storage != Byte(2) && object.symbols[symbol.weak_target].storage != Byte(105)) {
                    result.errors.append(CoffLinkError(status=CoffLinkStatus.InvalidObject, object=object_id, symbol=symbol_id, message="Weak external fallback must be external"));
                }
            }
            if (symbol.storage == Byte(2) && symbol.section == 0 && symbol.value != 0U) {
                result.errors.append(CoffLinkError(status=CoffLinkStatus.Unsupported, object=object_id, symbol=symbol_id, message="Common symbol allocation is not implemented yet"));
            }
            if (coff_address_symbol(symbol) && symbol.section > 0 && symbol.value > object.sections[symbol.section - 1].size) {
                result.errors.append(CoffLinkError(status=CoffLinkStatus.InvalidObject, object=object_id, symbol=symbol_id, message="Defined symbol extends beyond its section"));
            }

            let discarded = symbol.section > 0 && object.sections[symbol.section - 1].discarded;
            if (coff_address_symbol(symbol) && !discarded && (symbol.section > 0 || symbol.section == -1)) {
                row[symbol_id] = target;
                if (symbol.storage == Byte(2)) {
                    let slot: Int = coff_name_slot(objects, ref names, target);
                    let entry: CoffNameEntry = names.entries[slot];
                    if (entry.definition.object >= 0) {
                        result.errors.append(CoffLinkError(status=CoffLinkStatus.DuplicateSymbol, object=object_id, symbol=symbol_id, other=entry.definition, message="Duplicate external symbol definition"));
                    } else {
                        entry.definition = target;
                        names.entries[slot] = entry;
                    }
                }
            }
            symbol_id++;
        }
        result.targets.append(row);
        object_id++;
    }
    if (result.errors.length() > 0) { return result; }

    let aliases = coff_register_aliases(objects, ref names);
    if (aliases.length() != 0) { return CoffSymbolResult(errors=aliases); }
    let bound = coff_bind_aliases(objects, ref names);
    if (bound.errors.length() != 0) { return bound; }

    object_id = 0;
    while (object_id < objects.length()) {
        let object: CoffObject = objects[object_id];
        let symbol_id: Int = 0;
        while (symbol_id < object.symbols.length()) {
            let symbol: CoffSymbol = object.symbols[symbol_id];
            let discarded = symbol.section > 0 && object.sections[symbol.section - 1].discarded;
            if ((symbol.storage == Byte(2) || symbol.storage == Byte(105)) && (symbol.section == 0 || discarded)) {
                let slot: Int = coff_name_slot(objects, ref names, CoffSymbolRef(object_id, symbol_id));
                result.targets[object_id][symbol_id] = names.entries[slot].definition;
            }
            symbol_id++;
        }

        // unused undefined declarations are harmless, report each referenced one once.
        let reported: Vector(Bool) = [];
        symbol_id = 0;
        while (symbol_id < object.symbols.length()) { reported.append(false); symbol_id++; }
        let section_id: Int = 0;
        while (section_id < object.sections.length()) {
            let section: CoffSection = object.sections[section_id];
            if (section.discarded) { section_id++; continue; }
            let i: Int = 0;
            while (i < section.relocs.length()) {
                let reloc: CoffReloc = section.relocs[i];
                if (reloc.symbol < 0 || reloc.symbol >= object.symbols.length()) {
                    result.errors.append(CoffLinkError(status=CoffLinkStatus.InvalidObject, object=object_id, section=section_id, offset=reloc.offset, message="Invalid relocation symbol index"));
                } else if (result.targets[object_id][reloc.symbol].object < 0 && !reported[reloc.symbol]) {
                    let missing = CoffSymbolRef();
                    let reference = object.symbols[reloc.symbol];
                    if (reference.storage == Byte(2) || reference.storage == Byte(105)) {
                        let slot = coff_name_slot(objects, ref names, CoffSymbolRef(object_id, reloc.symbol));
                        missing = names.entries[slot].fallback;
                    }
                    let message = "Relocation references an undefined or non-address symbol";
                    if (reference.section > 0 && object.sections[reference.section - 1].discarded && reference.storage != Byte(2)) {
                        message = "Relocation references a discarded local COMDAT symbol";
                    }
                    result.errors.append(CoffLinkError(status=CoffLinkStatus.UndefinedSymbol, object=object_id, section=section_id, symbol=reloc.symbol, offset=reloc.offset, other=missing, message=message));
                    reported[reloc.symbol] = true;
                }
                i++;
            }
            section_id++;
        }
        object_id++;
    }
    return result;
}
