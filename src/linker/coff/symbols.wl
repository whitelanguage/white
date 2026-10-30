// src/linker/coff/symbols.wl
import * from "model.wl"
import * from "link_model.wl"
import coff_range from "reader.wl"


struct CoffNameEntry(name: CoffSymbolRef, definition: CoffSymbolRef = CoffSymbolRef(), next: Int = -1)
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
                result.errors.append(CoffLinkError(status=CoffLinkStatus.Unsupported, object=object_id, section=section_id, message="COMDAT selection is not implemented yet"));
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
                result.errors.append(CoffLinkError(status=CoffLinkStatus.Unsupported, object=object_id, symbol=symbol_id, message="Weak external symbols are not implemented yet"));
            }
            if (symbol.storage == Byte(2) && symbol.section == 0 && symbol.value != 0U) {
                result.errors.append(CoffLinkError(status=CoffLinkStatus.Unsupported, object=object_id, symbol=symbol_id, message="Common symbol allocation is not implemented yet"));
            }
            if (coff_address_symbol(symbol) && symbol.section > 0 && symbol.value > object.sections[symbol.section - 1].size) {
                result.errors.append(CoffLinkError(status=CoffLinkStatus.InvalidObject, object=object_id, symbol=symbol_id, message="Defined symbol extends beyond its section"));
            }

            if (coff_address_symbol(symbol) && (symbol.section > 0 || symbol.section == -1)) {
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

    object_id = 0;
    while (object_id < objects.length()) {
        let object: CoffObject = objects[object_id];
        let symbol_id: Int = 0;
        while (symbol_id < object.symbols.length()) {
            let symbol: CoffSymbol = object.symbols[symbol_id];
            if (symbol.storage == Byte(2) && symbol.section == 0) {
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
            let i: Int = 0;
            while (i < section.relocs.length()) {
                let reloc: CoffReloc = section.relocs[i];
                if (reloc.symbol < 0 || reloc.symbol >= object.symbols.length()) {
                    result.errors.append(CoffLinkError(status=CoffLinkStatus.InvalidObject, object=object_id, section=section_id, offset=reloc.offset, message="Invalid relocation symbol index"));
                } else if (result.targets[object_id][reloc.symbol].object < 0 && !reported[reloc.symbol]) {
                    result.errors.append(CoffLinkError(status=CoffLinkStatus.UndefinedSymbol, object=object_id, section=section_id, symbol=reloc.symbol, offset=reloc.offset, message="Relocation references an undefined or non-address symbol"));
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
