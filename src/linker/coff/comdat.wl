// src/linker/coff/comdat.wl
import * from "model.wl"
import * from "link_model.wl"
import CoffNameIndex, coff_name_slot from "symbols.wl"
import coff_range from "reader.wl"


struct CoffSelection(objects: Vector(CoffObject) = [], leaders: CoffNameIndex = CoffNameIndex(), errors: Vector(CoffLinkError) = [])
struct CoffSelectionStep(errors: Vector(CoffLinkError) = [], replaced: Bool = false)

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
        section.root = -1;
        sections.append(section);
    }
    result.sections = sections;
    return result;
}

func coff_equal_contents(left: CoffObject, a: CoffSection, right: CoffObject, b: CoffSection) -> Bool {
// link.exe and LLD compare payloads for EXACT_MATCH, relocation indices are object-local
    if (a.size != b.size || a.data.size != b.data.size) { return false; }
    if (!coff_range(left.bytes.length(), Long(a.data.offset), Long(a.data.size), 1) ||
        !coff_range(right.bytes.length(), Long(b.data.offset), Long(b.data.size), 1)) {
        return false;
    }
    for (let i = 0; i < a.data.size; i++) {
        if (left.bytes[a.data.offset + i] != right.bytes[b.data.offset + i]) { return false; }
    }
    return true;
}

func coff_select_object(objects: Vector(CoffObject), id: Int, ref leaders: CoffNameIndex) -> CoffSelectionStep {
// LARGEST can revoke a prior winner, the archive queue must then forget its dependency index
    let object = objects[id];
    if (!coff_has_comdat(object)) { return CoffSelectionStep(); }
    let result = CoffSelectionStep();
    let state: Vector(Byte) = [];
    for (let sec = 0; sec < object.sections.length(); sec++) {
        let section = object.sections[sec];
        state.append(Byte(0));
        if ((section.flags & 4096U) == 0U) { state[sec] = Byte(2); continue; }
        let mode = section.selection;
        if (mode < 1U || mode > 6U) {
            return CoffSelectionStep(errors=[CoffLinkError(status=CoffLinkStatus.Unsupported, object=id, section=sec, message="Unsupported COMDAT selection mode")]);
        }
        if (mode == 5U) {
            if (section.parent < 0 || section.parent >= object.sections.length() ||
                (object.sections[section.parent].flags & 4096U) == 0U) {
                return CoffSelectionStep(errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=id, section=sec, message="Invalid associative COMDAT parent")]);
            }
            continue;
        }
        if (section.leader < 0 || section.leader >= object.symbols.length() || object.symbols[section.leader].section != sec + 1) {
            return CoffSelectionStep(errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=id, section=sec, message="Invalid COMDAT leader symbol")]);
        }
        let leader = object.symbols[section.leader];
        if (!coff_range(object.bytes.length(), Long(leader.name.offset), Long(leader.name.size), 1)) {
            return CoffSelectionStep(errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=id, section=sec, message="Invalid COMDAT leader name")]);
        }
        if (leader.storage == Byte(2)) {
            let slot = coff_name_slot(objects, ref leaders, CoffSymbolRef(id, section.leader));
            let previous = leaders.entries[slot].definition;
            if (previous.object < 0) {
                leaders.entries[slot].definition = CoffSymbolRef(id, section.leader);
            } else {
                let old_symbol = objects[previous.object].symbols[previous.symbol];
                let old_section = objects[previous.object].sections[old_symbol.section - 1];
                if (mode != old_section.selection || mode == 1U || (mode == 3U && section.size != old_section.size) ||
                    (mode == 4U && !coff_equal_contents(object, section, objects[previous.object], old_section))) {
                    return CoffSelectionStep(errors=[CoffLinkError(status=CoffLinkStatus.DuplicateSymbol, object=id, section=sec, symbol=section.leader,
                        other=previous, message="Conflicting COMDAT definitions")]);
                }
                if (mode == 6U && section.size > old_section.size) {
                    let old_object = objects[previous.object];
                    let old_root = old_symbol.section - 1;
                    // cached roots include transitive .pdata/.xdata children, none may outlive their code.
                    for (let child_id = 0; child_id < old_object.sections.length(); child_id++) {
                        if (child_id == old_root || old_object.sections[child_id].root == old_root) {
                            old_object.sections[child_id].discarded = true;
                        }
                    }
                    objects[previous.object] = old_object;
                    leaders.entries[slot].definition = CoffSymbolRef(id, section.leader);
                    result.replaced = true;
                } else {
                    // equal-sized LARGEST candidates retain input order, just like ANY.
                    section.discarded = true;
                }
            }
        }
        section.selected = true;
        section.root = sec;
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
                return CoffSelectionStep(errors=[CoffLinkError(status=CoffLinkStatus.InvalidObject, object=id, section=current, message="Associative COMDAT parent cycle")]);
            }
            state[current] = Byte(1);
            path.append(current);
            current = object.sections[current].parent;
        }
        let discarded = object.sections[current].discarded;
        let root = object.sections[current].root;
        for (let p = 0; p < path.length(); p++) {
            let child = path[p];
            object.sections[child].selected = true;
            object.sections[child].discarded = discarded;
            object.sections[child].root = root;
            state[child] = Byte(2);
        }
    }
    objects[id] = object;
    return result;
}

func coff_select_objects(inputs: Vector(CoffObject)) -> CoffSelection {
    let result = CoffSelection();
    for (let i = 0; i < inputs.length(); i++) { result.objects.append(coff_prepare_selection(inputs[i])); }
    for (let obj = 0; obj < result.objects.length(); obj++) {
        let step = coff_select_object(result.objects, obj, ref result.leaders);
        if (step.errors.length() != 0) { result.errors = step.errors; return result; }
    }
    return result;
}
