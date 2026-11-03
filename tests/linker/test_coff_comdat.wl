// tests/linker/test_coff_comdat.wl
import * from "../../src/linker/coff/model.wl"
import * from "../../src/linker/coff/link_model.wl"
import coff_select_objects from "../../src/linker/coff/comdat.wl"
import coff_resolve_symbols from "../../src/linker/coff/symbols.wl"


func fixture() -> CoffObject {
    let bytes: Vector(Byte) = [Byte(184), Byte(42), Byte(0), Byte(0), Byte(0), Byte(195)];
    let name = bytes.length();
    for (let n = 0; n < 6; n++) { bytes.append("answer"[n]); }
    let local_name = bytes.length();
    for (let l = 0; l < 5; l++) { bytes.append("local"[l]); }

    let root = CoffSection(name=CoffSpan(), size=6U, address=0U, data=CoffSpan(0, 6),
        flags=0x60501020U, alignment=16, relocs=[], lines=CoffSpan(), selection=2U, leader=0);
    let child = CoffSection(name=CoffSpan(), size=0U, address=0U, data=CoffSpan(),
        flags=0x40301040U, alignment=4, relocs=[], lines=CoffSpan(), selection=5U, parent=0);
    let grandchild = child;
    grandchild.parent = 1;
    let leader = CoffSymbol(name=CoffSpan(name, 6), value=0U, section=1, type=32U, storage=Byte(2),
        table_index=0, aux=CoffSpan());
    let local = CoffSymbol(name=CoffSpan(local_name, 5), value=0U, section=1, type=0U, storage=Byte(3),
        table_index=1, aux=CoffSpan());
    return CoffObject(bytes=bytes, sections=[root, child, grandchild], symbols=[leader, local], symbol_map=[0, 1]);
}

func main() -> Int {
    let first = fixture();
    let second = fixture();
    let chosen = coff_select_objects([first, second]);
    if (chosen.errors.length() != 0) { return 1; }
    for (let s = 0; s < 3; s++) {
        if (!chosen.objects[0].sections[s].selected || chosen.objects[0].sections[s].discarded ||
            !chosen.objects[1].sections[s].selected || !chosen.objects[1].sections[s].discarded) {
            print("FAIL: associative COMDAT selection");
            return 1;
        }
        if (first.sections[s].selected || second.sections[s].selected || second.sections[s].discarded) {
            print("FAIL: selection changed the caller's decoded sections");
            return 1;
        }
    }
    let resolved = coff_resolve_symbols(chosen.objects);
    if (resolved.errors.length() != 0 || resolved.targets[1][0].object != 0 || resolved.targets[1][0].symbol != 0 ||
        resolved.targets[1][1].object != -1) {
        print("FAIL: discarded external and local bindings");
        return 1;
    }
    let repeated = coff_select_objects(chosen.objects);
    if (repeated.errors.length() != 0 || !repeated.objects[1].sections[2].discarded) { return 1; }

    // same-named local leaders belong to different objects, neither owns the other.
    first.symbols[0].storage = Byte(3);
    second.symbols[0].storage = Byte(3);
    chosen = coff_select_objects([first, second]);
    if (chosen.errors.length() != 0 || chosen.objects[0].sections[0].discarded || chosen.objects[1].sections[0].discarded) {
        print("FAIL: local COMDAT leaders were merged globally");
        return 1;
    }
    first = fixture();
    second = fixture();
    first.sections[0].selection = 3U;
    second.sections[0].selection = 3U;
    second.sections[0].size = 5U;
    chosen = coff_select_objects([first, second]);
    if (chosen.errors.length() != 1 || chosen.errors[0].status != CoffLinkStatus.DuplicateSymbol) { return 1; }

    first = fixture();
    first.sections[1].parent = 2;
    chosen = coff_select_objects([first]);
    if (chosen.errors.length() != 1 || chosen.errors[0].status != CoffLinkStatus.InvalidObject) { return 1; }

    first = fixture();
    let child = first.sections[1];
    for (let depth = 3; depth < 4096; depth++) {
        child.parent = depth - 1;
        first.sections.append(child);
    }
    chosen = coff_select_objects([first, fixture()]);
    if (chosen.errors.length() != 0 || !chosen.objects[0].sections[4095].selected ||
        chosen.objects[0].sections[4095].discarded || !chosen.objects[1].sections[2].discarded) {
        print("FAIL: deep associative COMDAT ownership");
        return 1;
    }

    print("PASS: COMDAT selection and symbol rebinding");
    return 0;
}
