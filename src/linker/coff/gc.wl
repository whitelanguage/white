// src/linker/coff/gc.wl
import * from "model.wl"
import * from "link_model.wl"
import coff_range, coff_name_matches from "reader.wl"


struct CoffReachable(
    starts: Vector(Int) = [],
    owners: Vector(Int) = [],
    sections: Vector(Int) = [],
    live: Vector(Bool) = [],
    children: Vector(Int) = [],
    next: Vector(Int) = [],
    work: Vector(Int) = []
)

struct CoffCollection(objects: Vector(CoffObject) = [], errors: Vector(CoffLinkError) = [], removed: Int = 0)

func coff_has_gc_sections(objects: Vector(CoffObject)) -> Bool {
// monolithic machine objects cannot benefit from section collection yet
    for (let obj = 0; obj < objects.length(); obj++) {
        for (let sec = 0; sec < objects[obj].sections.length(); sec++) {
            let section = objects[obj].sections[sec];
            if (!section.discarded && (section.flags & 4096U) != 0U) { return true; }
        }
    }
    return false;
}

func coff_gc_metadata(object: CoffObject, section: CoffSection) -> Bool {
    if ((section.flags & 2560U) != 0U) { return true; }
    let name = section.name;
    let size = 0;
    while (size < name.size && object.bytes[name.offset + size] != Byte(36)) { size++; }
    return coff_name_matches(object, CoffSpan(name.offset, size), ".debug");
}

func coff_mark_section(ref state: CoffReachable, index: Int) -> Void {
    if (state.live[index]) { return; }
    state.live[index] = true;
    state.work.append(index);
}

func coff_mark_symbol(objects: Vector(CoffObject), ref state: CoffReachable, target: CoffSymbolRef) -> Void {
    if (target.object < 0) { return; }
    let symbol = objects[target.object].symbols[target.symbol];
    if (symbol.section > 0 && !objects[target.object].sections[symbol.section - 1].discarded) {
        coff_mark_section(ref state, state.starts[target.object] + symbol.section - 1);
    }
}

func coff_collect_sections(objects: Vector(CoffObject), symbols: CoffSymbolResult, roots: Vector(CoffSymbolRef)) -> CoffCollection {
// COFF collection works on COMDAT contributions, ordinary sections remain indivisible roots
    let state = CoffReachable();
    for (let obj = 0; obj < objects.length(); obj++) {
        let object = objects[obj];
        state.starts.append(state.live.length());
        for (let sec = 0; sec < object.sections.length(); sec++) {
            let section = object.sections[sec];
            if (!coff_range(object.bytes.length(), Long(section.name.offset), Long(section.name.size), 1) ||
                !coff_range(object.bytes.length(), Long(section.data.offset), Long(section.data.size), 1)) {
                return CoffCollection(errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=obj,
                    section=sec, message="Invalid section span supplied to collection")]);
            }
            state.owners.append(obj);
            state.sections.append(sec);
            state.live.append(false);
            state.children.append(-1);
            state.next.append(-1);
        }
    }

    for (let owner = 0; owner < objects.length(); owner++) {
        let object = objects[owner];
        for (let sec = 0; sec < object.sections.length(); sec++) {
            let section = object.sections[sec];
            if (section.discarded) { continue; }
            let index = state.starts[owner] + sec;
            if (section.selection == 5U) {
                if (section.parent < 0 || section.parent >= object.sections.length()) {
                    return CoffCollection(errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=owner,
                        section=sec, message="Invalid associative section supplied to collection")]);
                }
                let parent = state.starts[owner] + section.parent;
                state.next[index] = state.children[parent];
                state.children[parent] = index;
            }
            // debug and directive records do not keep code alive through their relocations.
            if ((section.flags & 4096U) == 0U && !coff_gc_metadata(object, section)) {
                coff_mark_section(ref state, index);
            }
        }
    }
    for (let root = 0; root < roots.length(); root++) {
        let ref_id = roots[root];
        coff_mark_symbol(objects, ref state, symbols.targets[ref_id.object][ref_id.symbol]);
    }

    // mark on enqueue, cycles and repeated relocation edges never add a second visit.
    let cursor = 0;
    while (cursor < state.work.length()) {
        let index = state.work[cursor];
        let obj = state.owners[index];
        let section = objects[obj].sections[state.sections[index]];
        if (coff_gc_metadata(objects[obj], section)) { cursor++; continue; }
        for (let rel = 0; rel < section.relocs.length(); rel++) {
            let reloc = section.relocs[rel];
            if (reloc.kind != 0U) {
                coff_mark_symbol(objects, ref state, symbols.targets[obj][reloc.symbol]);
            }
        }
        let child = state.children[index];
        while (child >= 0) {
            coff_mark_section(ref state, child);
            child = state.next[child];
        }
        cursor++;
    }

    let result = CoffCollection();
    for (let out = 0; out < objects.length(); out++) {
        let object = objects[out];
        let sections: Vector(CoffSection) = [];
        for (let sec = 0; sec < object.sections.length(); sec++) {
            let section = object.sections[sec];
            section.collected = !section.discarded &&
                (!state.live[state.starts[out] + sec] || coff_gc_metadata(object, section));
            if (section.collected && (section.flags & 4096U) != 0U) { result.removed++; }
            sections.append(section);
        }
        // copy just the per-link section state, keep byte buffers and symbol identities intact.
        object.sections = sections;
        result.objects.append(object);
    }
    return result;
}
