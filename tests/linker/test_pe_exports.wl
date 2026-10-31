// Test: PE_EXPORTS
// File: tests/linker/test_pe_exports.wl
// Focus: sorted names, explicit and automatic ordinals, DLL flags and data exports.
import "file"
import * from "../../src/linker/pe/model.wl"
import write_pe from "../../src/linker/pe/writer.wl"
import pe_export_before from "../../src/linker/pe/exports.wl"
import coff_u16, coff_u32 from "../../src/linker/coff/reader.wl"
import pe_export_object from "../fixtures/linker/pe_export_objects.wl"
import pe_pointer_object, pe_bss_object from "../fixtures/linker/pe_objects.wl"


func main(argc: Int, ptr argv: String) -> Int {
    let object = pe_export_object()?;
    catch(err) { return 1; }
    let requests = [PeExport(name="Zen", symbol="Answer"), PeExport(symbol="Answer", ordinal=7U),
        PeExport(name="Constant", ordinal=8U), PeExport(name="Alpha", symbol="Answer"), PeExport(name="Alias", symbol="Answer", ordinal=9U)];
    let options = PeOptions(entry="", is_dll=true, image_name="white-import-fixture.dll", exports=requests);
    let result = write_pe([object], options);
    if (result.image is null) {
        let i = 0;
        while (i < result.errors.length()) { print(result.errors[i].message); i++; }
        print("FAIL: export image");
        return 1;
    }
    let image: PeImage = result.image;
    if (image.layout.sections.length() != 3) { print("FAIL: export section count"); return 1; }
    let section = image.layout.sections[2];
    let raw = Int(section.raw_offset);
    let optional = 88;
    if (image.layout.sections.length() != 3 || section.flags != 0x40000040U || image.entry_rva != 0U ||
        coff_u16(image.bytes, 86) != 8226U || coff_u32(image.bytes, optional + 16) != 0U ||
        coff_u32(image.bytes, optional + 112) != section.rva || coff_u32(image.bytes, optional + 116) != section.size ||
        coff_u32(image.bytes, raw + 16) != 1U || coff_u32(image.bytes, raw + 20) != 9U || coff_u32(image.bytes, raw + 24) != 4U) {
        print("FAIL: DLL headers or export directory");
        return 1;
    }
    let eat = raw + 40;
    let names = raw + 40 + 9 * 4;
    let ordinals = names + 4 * 4;
    let code = image.layout.sections[0].rva;
    let data = image.layout.sections[1].rva;
    if (coff_u32(image.bytes, eat) != code || coff_u32(image.bytes, eat + 4) != code ||
        coff_u32(image.bytes, eat + 24) != code || coff_u32(image.bytes, eat + 28) != data || coff_u32(image.bytes, eat + 32) != code ||
        coff_u32(image.bytes, raw + 28) != section.rva + 40U || coff_u32(image.bytes, raw + 32) != section.rva + 76U ||
        coff_u32(image.bytes, raw + 36) != section.rva + 92U) {
        print("FAIL: address table or exported data RVA");
        return 1;
    }
    let i = 2;
    while (i < 6) {
        if (coff_u32(image.bytes, eat + i * 4) != 0U) { print("FAIL: ordinal hole"); return 1; }
        i++;
    }
    let expected_names = ["Alias", "Alpha", "Constant", "Zen"];
    let expected_ordinals = [8, 0, 7, 1];
    i = 0;
    while (i < 4) {
        let offset = Int(coff_u32(image.bytes, names + i * 4) - section.rva) + raw;
        let text = expected_names[i];
        let j = 0;
        while (j < text.length()) {
            if (image.bytes[offset + j] != text[j]) { print("FAIL: export name order"); return 1; }
            j++;
        }
        if (image.bytes[offset + text.length()] != Byte(0) || coff_u16(image.bytes, ordinals + i * 2) != UInt32(expected_ordinals[i])) {
            print("FAIL: export name terminator or ordinal index");
            return 1;
        }
        i++;
    }
    let reversed: Vector(PeExport) = [];
    i = requests.length();
    while (i > 0) { i--; reversed.append(requests[i]); }
    options.exports = reversed;
    let again = write_pe([object], options);
    if (again.image is null) { return 1; }
    let repeat: PeImage = again.image;
    if (repeat.bytes.length() != image.bytes.length() || requests[0].ordinal is !null) { return 1; }
    i = 0;
    while (i < image.bytes.length()) {
        if (image.bytes[i] != repeat.bytes[i]) { print("FAIL: export reproducibility or automatic ordinal assignment"); return 1; }
        i++;
    }

    options.exports = [PeExport(symbol="Answer", ordinal=65535U)];
    let ordinal_only = write_pe([object], options);
    if (ordinal_only.image is null) { return 1; }
    let only: PeImage = ordinal_only.image;
    let at = Int(only.layout.sections[2].raw_offset);
    if (coff_u32(only.bytes, at + 16) != 65535U || coff_u32(only.bytes, at + 20) != 1U ||
        coff_u32(only.bytes, at + 24) != 0U || coff_u32(only.bytes, at + 32) != 0U || coff_u32(only.bytes, at + 36) != 0U) {
        print("FAIL: ordinal-only directory");
        return 1;
    }
    let pointer = pe_pointer_object()?;
    catch(err) { return 1; }
    let relocated = write_pe([pointer], PeOptions(entry="", is_dll=true, image_name="white-pointer-fixture.dll",
        exports=[PeExport(name="entry"), PeExport(name="pointer")]));
    if (relocated.image is null) { return 1; }
    let with_reloc: PeImage = relocated.image;
    if (with_reloc.layout.sections.length() != 5 || coff_u32(with_reloc.bytes, optional + 112) != with_reloc.layout.sections[3].rva ||
        coff_u32(with_reloc.bytes, optional + 152) != with_reloc.layout.sections[4].rva) { print("FAIL: export and relocation headers"); return 1; }
    let bss = pe_bss_object()?;
    catch(err) { return 1; }
    let bss_export = write_pe([bss], PeOptions(entry="entry", exports=[PeExport(name="zero")]));
    if (bss_export.image is null) { print("FAIL: BSS data export"); return 1; }

    let many: Vector(PeExport) = [];
    i = 1000;
    while (i > 0) { i--; many.append(PeExport(name="item" + String(i), symbol="Answer")); }
    let sorted = write_pe([object], PeOptions(entry="Answer", exports=many));
    if (sorted.image is null) { print("FAIL: large unordered export table"); return 1; }
    let large: PeImage = sorted.image;
    let table = large.layout.sections[2];
    let start = Int(table.raw_offset);
    let pointers = start + 40 + 1000 * 4;
    let indices = pointers + 1000 * 4;
    let previous = "";
    i = 0;
    while (i < 1000) {
        let offset = Int(coff_u32(large.bytes, pointers + i * 4) - table.rva) + start;
        let name = "";
        while (large.bytes[offset] != Byte(0)) { name += String(Char(large.bytes[offset])); offset++; }
        if ((i > 0 && !pe_export_before(previous, name)) || coff_u16(large.bytes, indices + i * 2) != UInt32(i)) {
            print("FAIL: large export ordering or automatic ordinals");
            return 1;
        }
        previous = name;
        i++;
    }

    if (argc == 2 || argc == 3) {
        let output_image = image;
        if (argc == 3 && argv[2] == "pointer") { output_image = with_reloc; }
        let output = file.create(argv[1])?;
        catch(err) { return 1; }
        output.write_bytes(output_image.bytes)?;
        catch(err) { output.close(); return 1; }
        output.close();
    }
    print("PASS: PE exports, sorted names, ordinals, data and DLL headers");
    return 0;
}
