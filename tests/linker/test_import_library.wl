// Test: COFF_IMPORT_LIBRARY
// File: tests/linker/test_import_library.wl
// Focus: Deterministic directories, support records, resolved aliases, ordinals and data classification.
import "file"
import PeOptions, PeExport, PeImage from "../../src/linker/pe/model.wl"
import write_pe from "../../src/linker/pe/writer.wl"
import write_import_library from "../../src/linker/pe/library.wl"
import read_archive from "../../src/linker/coff/archive.wl"
import CoffArchive from "../../src/linker/coff/archive_model.wl"
import CoffLibraryPart from "../../src/linker/coff/library_model.wl"
import write_coff_library from "../../src/linker/coff/library_write.wl"
import read_coff, coff_u16, coff_u32 from "../../src/linker/coff/reader.wl"
import read_coff_import from "../../src/linker/coff/import_object.wl"
import pe_export_object from "../fixtures/linker/pe_export_objects.wl"


func save_library_fixture(path: String, bytes: Vector(Byte)) -> Void? {
    let output = file.create(path)?;
    output.write_bytes(bytes)?;
    output.close_checked()?;
    return;
}

func main(argc: Int, ptr argv: String) -> Int {
    let object = pe_export_object()?;
    catch(err) { return 1; }
    let requests = [PeExport(name="Zen", symbol="Answer"), PeExport(name="Alias", symbol="Answer", ordinal=7U),
        PeExport(name="Constant", ordinal=8U), PeExport(symbol="Answer", ordinal=65535U)];
    let linked = write_pe([object], PeOptions(entry="", image_name="fixture.dll", is_dll=true, exports=requests));
    if (linked.image is null) { print("FAIL: export fixture"); return 1; }
    let image: PeImage = linked.image;
    if (image.exports.length() != 4 || image.exports[0].ordinal != 65535U || image.exports[1].name != "Alias" ||
        image.exports[2].name != "Constant" || !image.exports[2].is_data || image.exports[3].ordinal != 1U) {
        print("FAIL: resolved bindings");
        return 1;
    }
    let library = write_import_library("fixture.dll", image.exports);
    if (library.message.length() != 0) { print("FAIL: library fixture ", library.message); return 1; }
    let decoded = read_archive(library.bytes);
    if (decoded.archive is null) { print("FAIL: written archive ", decoded.message); return 1; }
    let archive: CoffArchive = decoded.archive;
    if (archive.members.length() != 7 || archive.symbols.length() != 10) { print("FAIL: member or symbol count"); return 1; }
    for (let member = 0; member < archive.members.length(); member++) {
        let span = archive.members[member].data;
        let bytes: Vector(Byte) = [];
        for (let b = 0; b < span.size; b++) { bytes.append(archive.bytes[span.offset + b]); }
        if (member < 3) {
            let support = read_coff(bytes);
            if (support.object is null || coff_u32(bytes, 4) != 0U) { print("FAIL: support COFF record"); return 1; }
            let expected_sections = 2;
            let expected_symbols = 1;
            if (member == 0) { expected_symbols = 7; }
            if (member == 1) { expected_sections = 1; }
            if (coff_u16(bytes, 2) != UInt32(expected_sections) || coff_u32(bytes, 12) != UInt32(expected_symbols)) { return 1; }
        } else {
            let imported = read_coff_import(bytes);
            if (imported.entry is null) { print("FAIL: written short import ", imported.message); return 1; }
            let entry = imported.entry;
            let binding = image.exports[member - 3];
            if (entry.dll != "fixture.dll" || entry.is_data != binding.is_data || entry.is_const) { return 1; }
            if (binding.name.length() == 0) {
                let supplied = entry.ordinal;
                if (supplied is null) { return 1; }
                let ordinal: UInt32 = supplied;
                if (entry.symbol != binding.symbol || ordinal != binding.ordinal || entry.name != "") { return 1; }
            } else if (entry.symbol != binding.name || entry.name != binding.name || entry.hint != binding.hint || entry.ordinal is !null) {
                print("FAIL: public alias uses the private object symbol");
                return 1;
            }
        }
    }
    let again = write_import_library("fixture.dll", image.exports);
    if (again.bytes.length() != library.bytes.length()) { return 1; }
    for (let i = 0; i < library.bytes.length(); i++) {
        if (again.bytes[i] != library.bytes[i]) { print("FAIL: library reproducibility"); return 1; }
    }
    if (write_import_library("../fixture.dll", image.exports).message.length() == 0) { return 1; }
    let duplicate = [image.exports[1], image.exports[1]];
    if (write_import_library("fixture.dll", duplicate).message.length() == 0) { return 1; }
    if (write_coff_library([CoffLibraryPart([], ["a"]), CoffLibraryPart([], ["a"])]).message.length() == 0) { return 1; }
    if (write_coff_library([CoffLibraryPart([], [""])]).message.length() == 0) { return 1; }
    let empty = write_import_library("empty.dll", []);
    if (empty.message.length() != 0 || read_archive(empty.bytes).archive is null) { return 1; }

    // the host suite consumes these with an independent linker, no fixture files are emitted in normal runs.
    if (argc == 3) {
        save_library_fixture(argv[1], image.bytes)?;
        catch(err) { return 1; }
        save_library_fixture(argv[2], library.bytes)?;
        catch(err) { return 1; }
    }
    print("PASS: COFF import library writer");
    return 0;
}
