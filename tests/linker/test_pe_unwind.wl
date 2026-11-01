// Test: PE_UNWIND
// File: tests/linker/test_pe_unwind.wl
// Focus: runtime-function sorting, RVA relocation, v1 unwind slots and DLL metadata.
import "file"
import * from "../../src/linker/pe/model.wl"
import * from "../../src/linker/pe/unwind.wl"
import write_pe from "../../src/linker/pe/writer.wl"
import coff_u32 from "../../src/linker/coff/reader.wl"
import pe_unwind_object from "../fixtures/linker/pe_unwind_objects.wl"


func main(argc: Int, ptr argv: String) -> Int {
    let object = pe_unwind_object();
    let options = PeOptions(entry="", is_dll=true, image_name="white-unwind-fixture.dll", exports=[PeExport(name="Small"), PeExport(name="Large")]);
    let result = write_pe([object], options);
    if (result.image is null) {
        let i = 0;
        while (i < result.errors.length()) { print(result.errors[i].message); i++; }
        return 1;
    }
    let image: PeImage = result.image;
    let table = image.layout.sections[1];
    let raw = Int(table.raw_offset);
    let code = image.layout.sections[0].rva;
    let info = image.layout.sections[2].rva;
    if (coff_u32(image.bytes, 224) != table.rva || coff_u32(image.bytes, 228) != 24U ||
        coff_u32(image.bytes, raw) != code || coff_u32(image.bytes, raw + 4) != code + 19U ||
        coff_u32(image.bytes, raw + 8) != info || coff_u32(image.bytes, raw + 12) != code + 32U ||
        coff_u32(image.bytes, raw + 16) != code + 57U || coff_u32(image.bytes, raw + 20) != info + 12U ||
        coff_u32(object.bytes, object.sections[1].data.offset) != 32U) {
        print("FAIL: runtime table sorting, exception directory or source immutability");
        return 1;
    }
    let records = [
        [Byte(1), Byte(4), Byte(1), Byte(0), Byte(4), Byte(0x30), Byte(0), Byte(0)],
        [Byte(1), Byte(7), Byte(3), Byte(0), Byte(7), Byte(0x11), Byte(0), Byte(0), Byte(8), Byte(0), Byte(0), Byte(0)],
        [Byte(1), Byte(5), Byte(2), Byte(0), Byte(5), Byte(0x34), Byte(8), Byte(0)],
        [Byte(1), Byte(5), Byte(3), Byte(0), Byte(5), Byte(0x35), Byte(64), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0)],
        [Byte(1), Byte(5), Byte(2), Byte(0), Byte(5), Byte(0x68), Byte(2), Byte(0)],
        [Byte(1), Byte(5), Byte(3), Byte(0), Byte(5), Byte(0x69), Byte(32), Byte(0), Byte(0), Byte(0), Byte(0), Byte(0)],
        [Byte(1), Byte(0), Byte(0), Byte(0)]];
    let i = 0;
    while (i < records.length()) {
        let checked = pe_check_unwind(records[i], 0, records[i].length());
        if (checked.message.length() != 0) { print("FAIL: supported unwind operation ", i, checked.message); return 1; }
        i++;
    }
    let shared = [PeRuntimeFunction(8U, 12U, 100U), PeRuntimeFunction(1U, 2U, 100U), PeRuntimeFunction(4U, 5U, 100U)];
    let sorted = pe_sort_runtime(shared);
    if (sorted[0].begin != 1U || sorted[1].begin != 4U || sorted[2].begin != 8U || shared[0].begin != 8U) {
        print("FAIL: runtime table sort"); return 1;
    }
    if (argc == 2) {
        let output = file.create(argv[1])?;
        catch(err) { return 1; }
        output.write_bytes(image.bytes)?;
        catch(err) { output.close(); return 1; }
        output.close();
    }
    print("PASS: PE exception directory and checked unwind records");
    return 0;
}
