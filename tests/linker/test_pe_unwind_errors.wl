// Test: PE_UNWIND_ERRORS
// File: tests/linker/test_pe_unwind_errors.wl
// Focus: truncated slots, invalid code ranges, unsupported handlers and table padding.
import * from "../../src/linker/pe/model.wl"
import * from "../../src/linker/pe/unwind.wl"
import write_pe from "../../src/linker/pe/writer.wl"
import coff_put_word from "../../src/linker/coff/reloc.wl"
import pe_unwind_object, pe_unwind_name from "../fixtures/linker/pe_unwind_objects.wl"


func main() -> Int {
    let valid = [Byte(1), Byte(8), Byte(3), Byte(5), Byte(8), Byte(50), Byte(4), Byte(3), Byte(1), Byte(80), Byte(0), Byte(0)];
    let i = 0;
    while (i < valid.length()) {
        let checked = pe_check_unwind(valid, 0, i);
        if (checked.message.length() == 0) { print("FAIL: truncated unwind record ", i); return 1; }
        i++;
    }
    let invalid = [
        [Byte(2), Byte(0), Byte(0), Byte(0)], [Byte(9), Byte(0), Byte(0), Byte(0)],
        [Byte(1), Byte(1), Byte(1), Byte(0), Byte(2), Byte(2), Byte(0), Byte(0)],
        [Byte(1), Byte(1), Byte(1), Byte(0), Byte(0), Byte(2), Byte(0), Byte(0)],
        [Byte(1), Byte(1), Byte(1), Byte(0), Byte(1), Byte(0), Byte(0), Byte(0)],
        [Byte(1), Byte(1), Byte(1), Byte(0), Byte(1), Byte(0x21), Byte(0), Byte(0)],
        [Byte(1), Byte(1), Byte(1), Byte(0), Byte(1), Byte(1), Byte(0), Byte(0)],
        [Byte(1), Byte(1), Byte(2), Byte(0), Byte(1), Byte(1), Byte(0), Byte(0)],
        [Byte(1), Byte(1), Byte(3), Byte(0), Byte(1), Byte(0x11), Byte(9), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0)],
        [Byte(1), Byte(1), Byte(1), Byte(0), Byte(1), Byte(3), Byte(0), Byte(0)],
        [Byte(1), Byte(0), Byte(0), Byte(16)], [Byte(1), Byte(0), Byte(0), Byte(1)],
        [Byte(1), Byte(1), Byte(1), Byte(5), Byte(1), Byte(2), Byte(0), Byte(0)],
        [Byte(1), Byte(1), Byte(2), Byte(0), Byte(1), Byte(0x58), Byte(0), Byte(0)],
        [Byte(1), Byte(1), Byte(3), Byte(0), Byte(1), Byte(0x69), Byte(8), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0)],
        [Byte(1), Byte(1), Byte(3), Byte(0), Byte(1), Byte(0x35), Byte(3), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0)],
        [Byte(1), Byte(1), Byte(1), Byte(0), Byte(1), Byte(6), Byte(0), Byte(0)]];
    i = 0;
    while (i < invalid.length()) {
        let checked = pe_check_unwind(invalid[i], 0, invalid[i].length());
        if (checked.message.length() == 0) { print("FAIL: invalid unwind opcode ", i); return 1; }
        i++;
    }
    if (pe_check_unwind(valid, -1, 4).message.length() == 0 || pe_check_unwind(valid, 0, 13).message.length() == 0) { return 1; }

    i = 0;
    while (i < 11) {
        let object = pe_unwind_object();
        let table = object.sections[1].data.offset;
        let info = object.sections[2].data.offset;
        if (i == 0) { coff_put_word(object.bytes, table + 4, 4, 32UL); }
        if (i == 1) { coff_put_word(object.bytes, table + 4, 4, 1000UL); }
        if (i == 2) { coff_put_word(object.bytes, table + 8, 4, 13UL); }
        if (i == 3) { coff_put_word(object.bytes, table + 8, 4, 100000UL); }
        if (i == 4) { coff_put_word(object.bytes, table, 4, 10UL); coff_put_word(object.bytes, table + 4, 4, 40UL); }
        if (i == 5) { object.bytes[info + 1] = Byte(64); }
        if (i == 6) { object.bytes[info + 2] = Byte(255); }
        if (i == 7) { object.bytes[info] = Byte(9); }
        if (i == 8) { object.sections[1].flags |= 0x80000000U; }
        if (i == 9) { object.sections[2].flags |= 0x80000000U; }
        if (i == 10) {
            object.sections[1].relocs = [];
            object.sections[1].size = 23U;
            object.sections[1].data.size = 23;
        }
        let result = write_pe([object], PeOptions(entry="", is_dll=true));
        if (result.image is !null || result.errors.length() != 1) { print("FAIL: malformed exception image ", i); return 1; }
        i++;
    }
    let left = pe_unwind_object();
    let right = pe_unwind_object();
    right.symbols[0].name = pe_unwind_name(ref right, "Small2");
    right.symbols[1].name = pe_unwind_name(ref right, "Large2");
    right.sections[1].alignment = 16;
    let padded = write_pe([left, right], PeOptions(entry="", is_dll=true));
    if (padded.image is !null) { print("FAIL: padded runtime table"); return 1; }
    let many: Vector(PeRuntimeFunction) = [];
    i = 2048;
    while (i > 0) { i--; many.append(PeRuntimeFunction(UInt32(i * 4), UInt32(i * 4 + 1), 100U)); }
    let sorted = pe_sort_runtime(many);
    i = 0;
    while (i < sorted.length()) {
        if (sorted[i].begin != UInt32(i * 4)) { print("FAIL: large runtime table sort"); return 1; }
        i++;
    }
    print("PASS: malformed unwind records and runtime-function ranges");
    return 0;
}
