// tests/linker/test_coff_common.wl
import * from "../../src/linker/coff/model.wl"
import * from "../../src/linker/coff/link_model.wl"
import coff_resolve_symbols from "../../src/linker/coff/symbols.wl"
import coff_allocate_common, coff_common_align from "../../src/linker/coff/common.wl"
import * from "../../src/linker/pe/model.wl"
import write_pe from "../../src/linker/pe/writer.wl"


func common(size: UInt32) -> CoffObject {
    return CoffObject(bytes=[Byte(115), Byte(116), Byte(97), Byte(116), Byte(101)],
        symbols=[CoffSymbol(name=CoffSpan(0, 5), value=size, section=0, type=0U, storage=Byte(2), table_index=0, aux=CoffSpan())],
        symbol_map=[0]);
}

func main() -> Int {
    let first = common(3U);
    let second = common(17U);
    let symbols = coff_resolve_symbols([first, second]);
    if (symbols.errors.length() != 0 || symbols.targets[0][0].object != 1 || symbols.targets[1][0].object != 1) {
        print("FAIL: common size merge");
        return 1;
    }
    let allocated = coff_allocate_common([first, second]);
    if (allocated.errors.length() != 0 || allocated.objects.length() != 3) { return 1; }
    let generated = allocated.objects[2];
    if (generated.sections.length() != 1 || generated.sections[0].size != 17U || generated.sections[0].alignment != 32 ||
        generated.sections[0].data.size != 0 || generated.symbols[0].value != 0U || first.symbols[0].section != 0 ||
        first.symbols[0].value != 3U || second.sections.length() != 0) {
        print("FAIL: common BSS allocation changed the input or emitted raw data");
        return 1;
    }
    symbols = coff_resolve_symbols(allocated.objects);
    if (symbols.errors.length() != 0 || symbols.targets[0][0].object != 2 || symbols.targets[1][0].object != 2) { return 1; }
    let repeated = coff_allocate_common(allocated.objects);
    if (repeated.errors.length() != 0 || repeated.objects.length() != 3) { return 1; }

    let image = write_pe([first, second], PeOptions(entry="", is_dll=true, exports=[PeExport(name="state")]));
    let ready = image.image;
    if (ready is null) { print("FAIL: common PE export"); return 1; }
    let linked: PeImage = ready;
    if (linked.exports.length() != 1 || !linked.exports[0].is_data || linked.layout.sections[0].initialized_size != 0U ||
        linked.layout.sections[0].size != 17U) {
        print("FAIL: common export lost zero-fill storage");
        return 1;
    }

    let strong = common(7U);
    strong.symbols[0].section = 1;
    strong.symbols[0].value = 0U;
    strong.sections.append(CoffSection(name=CoffSpan(), size=4U, address=0U, data=CoffSpan(0, 4),
        flags=0xC0300040U, alignment=4, relocs=[], lines=CoffSpan()));
    allocated = coff_allocate_common([common(4294967295U), strong]);
    if (allocated.errors.length() != 0 || allocated.objects.length() != 2) { return 1; }
    symbols = coff_resolve_symbols(allocated.objects);
    if (symbols.errors.length() != 0 || symbols.targets[0][0].object != 1) {
        print("FAIL: common overrode an initialized definition");
        return 1;
    }
    allocated = coff_allocate_common([strong, first, second]);
    if (allocated.errors.length() != 0 || allocated.objects.length() != 3) { return 1; }

    let absolute = common(0U);
    absolute.symbols[0].section = -1;
    symbols = coff_resolve_symbols([absolute, first]);
    if (symbols.errors.length() != 0 || symbols.targets[0][0].object != 1) { return 1; }
    allocated = coff_allocate_common([first, absolute]);
    if (allocated.errors.length() != 0 || allocated.objects.length() != 3) { return 1; }
    symbols = coff_resolve_symbols(allocated.objects);
    if (symbols.errors.length() != 0 || symbols.targets[1][0].object != 2) { return 1; }

    allocated = coff_allocate_common([common(4294967295U)]);
    if (allocated.errors.length() != 1 || allocated.errors[0].status != CoffLinkStatus.InvalidLayout) { return 1; }
    let empty = common(4U);
    empty.symbols[0].name.size = 0;
    allocated = coff_allocate_common([empty]);
    if (allocated.errors.length() != 1 || allocated.errors[0].status != CoffLinkStatus.InvalidObject) { return 1; }
    for (let size = 1U; size < 100U; size++) {
        let align = coff_common_align(size);
        if (align < 1 || align > 32 || (align & (align - 1)) != 0 || (size < 32U && UInt32(align) < size)) { return 1; }
    }

    print("PASS: COFF common size, alignment, precedence and exports");
    return 0;
}
