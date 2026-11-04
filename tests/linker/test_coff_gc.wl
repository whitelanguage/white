// tests/linker/test_coff_gc.wl
import * from "../../src/linker/coff/model.wl"
import * from "../../src/linker/coff/link_model.wl"
import coff_collect_sections from "../../src/linker/coff/gc.wl"
import coff_select_objects from "../../src/linker/coff/comdat.wl"
import coff_resolve_symbols from "../../src/linker/coff/symbols.wl"
import pe_import_span, pe_import_symbol from "../../src/linker/pe/imports.wl"
import PeOptions, PeImage from "../../src/linker/pe/model.wl"
import write_pe from "../../src/linker/pe/writer.wl"


func section(ref object: CoffObject, name: String, comdat: Bool = true, parent: Int = -1) -> Int {
    let span = pe_import_span(ref object, name);
    let offset = object.bytes.length();
    object.bytes.append(Byte(195));
    let flags = 0x60500020U;
    let selection = 0U;
    if comdat { flags |= 4096U; selection = 2U; }
    if (parent >= 0) { selection = 5U; }
    let id = object.sections.length();
    object.sections.append(CoffSection(name=span, size=1U, address=0U, data=CoffSpan(offset, 1),
        flags=flags, alignment=16, relocs=[], lines=CoffSpan(), selection=selection,
        leader=object.symbols.length(), parent=parent));
    pe_import_symbol(ref object, name, id + 1, 0U, true);
    return id;
}

func main() -> Int {
    let object = CoffObject();
    section(ref object, ".text$entry");
    section(ref object, ".text$callee");
    section(ref object, ".text$child", true, 1);
    section(ref object, ".text$grandchild", true, 2);
    section(ref object, ".text$dead");
    section(ref object, ".text$other");
    section(ref object, ".text$ordinary", false);
    section(ref object, ".text$fromordinary");
    section(ref object, ".debug$S", false);
    section(ref object, ".text$debugonly");
    object.sections[0].relocs.append(CoffReloc(0U, 1, 0U));
    object.sections[0].relocs.append(CoffReloc(0U, 1, 4U));
    object.sections[1].relocs.append(CoffReloc(0U, 0, 4U));
    object.sections[4].relocs.append(CoffReloc(0U, 5, 4U));
    object.sections[5].relocs.append(CoffReloc(0U, 4, 4U));
    object.sections[6].relocs.append(CoffReloc(0U, 7, 4U));
    object.sections[8].relocs.append(CoffReloc(0U, 9, 4U));

    let selected = coff_select_objects([object]);
    if (selected.errors.length() != 0) { return 1; }
    let symbols = coff_resolve_symbols(selected.objects);
    if (symbols.errors.length() != 0) { return 1; }
    let roots = [CoffSymbolRef(0, 0)];
    let collected = coff_collect_sections(selected.objects, symbols, roots);
    if (collected.errors.length() != 0 || collected.removed != 3) { return 1; }
    for (let sec = 0; sec < object.sections.length(); sec++) {
        let dead = sec == 4 || sec == 5 || sec == 8 || sec == 9;
        if (collected.objects[0].sections[sec].collected != dead ||
            object.sections[sec].collected || selected.objects[0].sections[sec].collected) {
            print("FAIL: collection roots, cycles or input reuse");
            return 1;
        }
    }
    object.sections[8].flags |= 4096U;
    object.sections[8].selection = 5U;
    object.sections[8].parent = 0;
    selected = coff_select_objects([object]);
    symbols = coff_resolve_symbols(selected.objects);
    collected = coff_collect_sections(selected.objects, symbols, roots);
    if (!collected.objects[0].sections[8].collected || !collected.objects[0].sections[9].collected) {
        print("FAIL: associated debug metadata retained code");
        return 1;
    }
    let entry = PeOptions(entry=".text$entry", gc_sections=true);
    // Use relocation-free bodies for PE layout, the graph above tests reachability only.
    for (let clear = 0; clear < object.sections.length(); clear++) { object.sections[clear].relocs = []; }
    let linked = write_pe([object], entry);
    if (linked.image is null) { print("FAIL: COMDAT entry root"); return 1; }
    let image: PeImage = linked.image;
    if (image.layout.placements[0][0].section == 0 || image.layout.placements[0][1].section != 0) { return 1; }
    let uncollected = write_pe([object], PeOptions(entry=".text$entry"));
    if (uncollected.image is null) { return 1; }
    let all: PeImage = uncollected.image;
    if (all.layout.placements[0][1].section == 0 || object.sections[1].collected) { return 1; }

    let chain = CoffObject();
    for (let node = 0; node < 4096; node++) {
        section(ref chain, ".text$" + node);
        if (node > 0) { chain.sections[node - 1].relocs.append(CoffReloc(0U, node, 4U)); }
    }
    let chosen = coff_select_objects([chain]);
    let resolved = coff_resolve_symbols(chosen.objects);
    let reached = coff_collect_sections(chosen.objects, resolved, roots);
    if (reached.errors.length() != 0 || reached.removed != 0) { print("FAIL: long section graph"); return 1; }
    print("PASS: COFF section roots, cycles, associations and reusable input");
    return 0;
}
