// src/linker/coff/comdat.wl
import * from "model.wl"
import * from "link_model.wl"
import CoffNameIndex, coff_name_slot from "symbols.wl"
import coff_range from "reader.wl"


struct CoffSelection(objects: Vector(CoffObject) = [], leaders: CoffNameIndex = CoffNameIndex(), errors: Vector(CoffLinkError) = [])

func coff_has_comdat(object: CoffObject) -> Bool {
    for (let i = 0; i < object.sections.length(); i++) {
        if ((object.sections[i].flags & 4096U) != 0U) { return true; }
    }
    return false;
}

func coff_prepare_selection(object: CoffObject) -> CoffObject {
// sections carry per-link state, copying the vector leaves the caller's decoded object reusable
    if (!coff_has_comdat(object)) { return object; }
    let result = object;
    let sections: Vector(CoffSection) = [];
    for (let i = 0; i < object.sections.length(); i++) {
        let section = object.sections[i];
        section.selected = false;
        section.discarded = false;
        sections.append(section);
    }
    result.sections = sections;
    return result;
}

func coff_select_object(objects: Vector(CoffObject), id: Int, ref leaders: CoffNameIndex) -> Vector(CoffLinkError) {
// first-seen selection stays stable when archives append objects, no earlier dependencies are revoked
    let object = objects[id];
    if (!coff_has_comdat(object)) { return []; }
    let state: Vector(Byte) = [];
    for (let sec = 0; sec < object.sections.length(); sec++) {
        let section = object.sections[sec];
        state.append(Byte(0));
        if ((section.flags & 4096U) == 0U) { state[sec] = Byte(2); continue; }
        let mode = section.selection;
        if (mode != 1U && mode != 2U && mode != 3U && mode != 5U) {
            return [CoffLinkError(status=CoffLinkStatus.Unsupported, object=id, section=sec, message="Unsupported COMDAT selection mode")];
        }
        if (mode == 5U) {
            if (section.parent < 0 || section.parent >= object.sections.length() ||
                (object.sections[section.parent].flags & 4096U) == 0U) {
                return [CoffLinkError(status=CoffLinkStatus.InvalidObject, object=id, section=sec, message="Invalid associative COMDAT parent")];
            }
            continue;
        }
        if (section.leader < 0 || section.leader >= object.symbols.length() || object.symbols[section.leader].section != sec + 1) {
            return [CoffLinkError(status=CoffLinkStatus.InvalidObject, object=id, section=sec, message="Invalid COMDAT leader symbol")];
        }
        let leader = object.symbols[section.leader];
        if (!coff_range(object.bytes.length(), Long(leader.name.offset), Long(leader.name.size), 1)) {
            return [CoffLinkError(status=CoffLinkStatus.InvalidObject, object=id, section=sec, message="Invalid COMDAT leader name")];
        }
        if (leader.storage == Byte(2)) {
            let slot = coff_name_slot(objects, ref leaders, CoffSymbolRef(id, section.leader));
            let previous = leaders.entries[slot].definition;
            if (previous.object < 0) {
                leaders.entries[slot].definition = CoffSymbolRef(id, section.leader);
            } else {
                let old_symbol = objects[previous.object].symbols[previous.symbol];
                let old_section = objects[previous.object].sections[old_symbol.section - 1];
                if (mode != old_section.selection || mode == 1U || (mode == 3U && section.size != old_section.size)) {
                    return [CoffLinkError(status=CoffLinkStatus.DuplicateSymbol, object=id, section=sec, symbol=section.leader,
                        other=previous, message="Conflicting COMDAT definitions")];
                }
                section.discarded = true;
            }
        }
        section.selected = true;
        object.sections[sec] = section;
        state[sec] = Byte(2);
    }

    // associative ownership may form a long chain, use states rather than recursive descent.
    for (let start = 0; start < object.sections.length(); start++) {
        if (state[start] == Byte(2)) { continue; }
        let path: Vector(Int) = [];
        let current = start;
        while (state[current] != Byte(2)) {
            if (state[current] == Byte(1)) {
                return [CoffLinkError(status=CoffLinkStatus.InvalidObject, object=id, section=current, message="Associative COMDAT parent cycle")];
            }
            state[current] = Byte(1);
            path.append(current);
            current = object.sections[current].parent;
        }
        let discarded = object.sections[current].discarded;
        for (let p = 0; p < path.length(); p++) {
            let child = path[p];
            object.sections[child].selected = true;
            object.sections[child].discarded = discarded;
            state[child] = Byte(2);
        }
    }
    objects[id] = object;
    return [];
}

func coff_select_objects(inputs: Vector(CoffObject)) -> CoffSelection {
    let result = CoffSelection();
    for (let i = 0; i < inputs.length(); i++) { result.objects.append(coff_prepare_selection(inputs[i])); }
    for (let obj = 0; obj < result.objects.length(); obj++) {
        let errors = coff_select_object(result.objects, obj, ref result.leaders);
        if (errors.length() != 0) { result.errors = errors; return result; }
    }
    return result;
}
