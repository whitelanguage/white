// Test: PE_LAYOUT
// File: tests/linker/test_pe_layout.wl
// Focus: Contribution ordering, alignment, virtual storage and rejected metadata.
import * from "../../src/linker/coff/model.wl"
import * from "../../src/linker/coff/link_model.wl"
import * from "../../src/linker/pe/model.wl"
import * from "../../src/linker/pe/layout.wl"


func add_section(ref object: CoffObject, name: String, size: UInt32, alignment: Int, initialized: Bool) -> Void {
    let start = object.bytes.length();
    let i = 0;
    while (i < name.length()) { object.bytes.append(name[i]); i++; }
    let data = CoffSpan(object.bytes.length(), 0);
    let flags = 0xC0000080U;
    if initialized {
        data.size = Int(size);
        flags = 0xC0000040U;
        i = 0;
        while (i < data.size) { object.bytes.append(Byte(7)); i++; }
    }
    object.sections.append(CoffSection(name=CoffSpan(start, name.length()), size=size, address=0U, data=data,
        flags=flags, alignment=alignment, relocs=[], lines=CoffSpan()));
}

func main() -> Int {
    let object = CoffObject();
    add_section(ref object, ".data$Z", 9U, 16, false);
    add_section(ref object, ".data$A", 3U, 1, true);
    add_section(ref object, ".data$M", 4U, 8, true);
    add_section(ref object, ".debug$S", 3U, 1, true);
    let result = plan_pe([object]);
    if (result.layout is null) { print("FAIL: PE layout fixture"); return 1; }
    let layout: PeLayout = result.layout;
    let group = layout.sections[0];
    if (layout.sections.length() != 1 || group.parts[0].section != 1 || group.parts[1].section != 2 || group.parts[2].section != 0 ||
        layout.placements[0][1].offset != 0U || layout.placements[0][2].offset != 8U || layout.placements[0][0].offset != 16U ||
        group.size != 25U || group.initialized_size != 12U || group.raw_size != 512U || layout.placements[0][3].section != 0 ||
        object.sections[0].size != 9U || object.sections[0].data.size != 0 || (group.flags & 128U) != 0U) {
        print("FAIL: suffix order, contribution padding or implicit zero tail");
        return 1;
    }

    // equal suffixes preserve object order, sorting must not reorder the input vector.
    let other = CoffObject();
    add_section(ref other, ".data$A", 2U, 1, true);
    result = plan_pe([object, other]);
    if (result.layout is null) { return 1; }
    layout = result.layout;
    if (layout.sections[0].parts[0].object != 0 || layout.sections[0].parts[1].object != 1 || layout.placements[1][0].offset != 3U) {
        print("FAIL: equal-suffix stability");
        return 1;
    }

    let many = CoffObject();
    let i = 512;
    while (i > 0) { add_section(ref many, ".text$" + String(i), 1U, 16, true); i--; }
    result = plan_pe([many]);
    if (result.layout is null) { return 1; }
    layout = result.layout;
    let parts = layout.sections[0].parts;
    i = 1;
    while (i < parts.length()) {
        if (pe_part_before([many], parts[i], parts[i - 1]) || layout.placements[0][parts[i].section].offset != UInt32(i * 16)) {
            print("FAIL: unordered contribution sort");
            return 1;
        }
        i++;
    }

    let invalid = CoffObject();
    add_section(ref invalid, ".data", 1U, 3, true);
    result = plan_pe([invalid]);
    if (result.layout is !null || result.errors[0].status != CoffLinkStatus.InvalidObject) { return 1; }
    invalid.sections[0].alignment = 1;
    invalid.sections[0].data.offset = invalid.bytes.length();
    result = plan_pe([invalid]);
    if (result.layout is !null || result.errors[0].status != CoffLinkStatus.InvalidObject) { return 1; }

    let huge = CoffObject();
    add_section(ref huge, ".bss", 2147483647U, 1, false);
    result = plan_pe([huge]);
    if (result.layout is !null || result.errors[0].status != CoffLinkStatus.InvalidLayout) {
        print("FAIL: oversized BSS image accepted");
        return 1;
    }
    let reserved: Vector(String) = [".drectve", ".idata$2", ".edata", ".pdata", ".tls$A", ".rsrc", ".reloc", ".CRT$XCU", ".gfids$y"];
    i = 0;
    while (i < reserved.length()) {
        let input = CoffObject();
        add_section(ref input, reserved[i], 1U, 1, true);
        result = plan_pe([input]);
        if (result.layout is !null || result.errors[0].status != CoffLinkStatus.Unsupported) {
            print("FAIL: unsupported loader section ", reserved[i]);
            return 1;
        }
        i++;
    }
    let conflict = CoffObject();
    add_section(ref conflict, ".data$A", 1U, 1, true);
    add_section(ref conflict, ".data$B", 1U, 1, true);
    conflict.sections[1].flags = 0x40000040U;
    result = plan_pe([conflict]);
    if (result.layout is !null || result.errors[0].status != CoffLinkStatus.Unsupported) { return 1; }

    let excess = CoffObject();
    i = 0;
    while (i < 96) { add_section(ref excess, ".s" + String(i), 1U, 1, true); i++; }
    result = plan_pe([excess]);
    if (result.layout is !null || result.errors[0].status != CoffLinkStatus.Unsupported) { return 1; }
    result = plan_pe([]);
    if (result.layout is !null || result.errors[0].status != CoffLinkStatus.InvalidLayout) { return 1; }

    print("PASS: PE contribution layout and rejected input");
    return 0;
}
