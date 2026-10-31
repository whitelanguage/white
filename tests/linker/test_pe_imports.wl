// Test: PE_IMPORTS
// File: tests/linker/test_pe_imports.wl
// Focus: DLL tables, call thunks, live import selection, ordinals and aliases.
import "file"
import * from "../../src/linker/pe/model.wl"
import * from "../../src/linker/pe/imports.wl"
import write_pe from "../../src/linker/pe/writer.wl"
import coff_u16, coff_u32 from "../../src/linker/coff/reader.wl"
import coff_u64 from "../../src/linker/coff/reloc.wl"
import * from "../fixtures/linker/pe_import_objects.wl"
import pe_leaf_object from "../fixtures/linker/pe_objects.wl"


func main(argc: Int, ptr argv: String) -> Int {
    let object = pe_api_object()?;
    catch(err) { return 1; }
    let requests = [PeImport(dll="KERNEL32.dll", name="SetLastError"), PeImport(dll="kernel32.dll", name="GetLastError"),
        PeImport(dll="unused-does-not-exist.dll", name="Unused")];
    let input = [object];
    let result = write_pe(input, PeOptions(entry="entry", imports=requests));
    if (result.image is null) {
        let i = 0;
        while (i < result.errors.length()) { print(result.errors[i].message); i++; }
        print("FAIL: API import image");
        return 1;
    }
    let image: PeImage = result.image;
    if (input.length() != 1 || input[0].sections.length() != 1 || image.layout.sections.length() != 2) {
        print("FAIL: imported objects changed caller input or retained unused DLLs");
        return 1;
    }
    let section = image.layout.sections[1];
    let base = Int(section.raw_offset);
    let optional = Int(coff_u32(image.bytes, 60)) + 24;
    let lookup = Int(coff_u32(image.bytes, base)) - Int(section.rva) + base;
    let iat = Int(coff_u32(image.bytes, base + 16)) - Int(section.rva) + base;
    if (image.fixed_base || section.flags != 0xC0000040U || coff_u32(image.bytes, optional + 120) != section.rva ||
        coff_u32(image.bytes, optional + 124) != 40U || coff_u32(image.bytes, optional + 208) != section.rva + 40U ||
        coff_u32(image.bytes, optional + 212) != 24U || coff_u64(image.bytes, iat) != coff_u64(image.bytes, lookup) ||
        coff_u64(image.bytes, iat + 8) != coff_u64(image.bytes, lookup + 8) || coff_u64(image.bytes, iat + 16) != 0UL ||
        coff_u32(image.bytes, base + 20) != 0U || object.sections[0].relocs.length() != 2) {
        print("FAIL: import descriptor, IAT or lookup table");
        return 1;
    }
    let text = image.layout.sections[0];
    let thunk = Int(text.raw_offset) + 26;
    if (text.size != 32U || image.bytes[thunk] != Byte(255) || image.bytes[thunk + 1] != Byte(37) ||
        coff_u32(image.bytes, Int(text.raw_offset) + 10) != 12U) {
        print("FAIL: import call thunk");
        return 1;
    }
    let again = write_pe(input, PeOptions(entry="entry", imports=requests));
    if (again.image is null) { return 1; }
    let repeat: PeImage = again.image;
    if (image.bytes.length() != repeat.bytes.length()) { return 1; }
    let i = 0;
    while (i < image.bytes.length()) {
        if (image.bytes[i] != repeat.bytes[i]) { print("FAIL: import link reproducibility"); return 1; }
        i++;
    }

    let refs = pe_import_refs(["alias_a", "__imp_alias_b", "by_ordinal", "__imp_data"])?;
    catch(err) { return 1; }
    let aliases = [PeImport(dll="a.dll", name="Exported", symbol="alias_a", hint=8U),
        PeImport(dll="A.DLL", name="Exported", symbol="alias_b"), PeImport(dll="b.dll", symbol="by_ordinal", ordinal=7U),
        PeImport(dll="b.dll", name="Global", symbol="data", is_data=true)];
    let selected = pe_select_imports([refs], aliases);
    if (selected.errors.length() != 0 || selected.entries.length() != 4 || !selected.direct[0] || selected.direct[1] ||
        !selected.direct[2] || selected.direct[3]) { print("FAIL: import alias selection"); return 1; }
    let generated = pe_make_imports(selected.entries, selected.direct);
    if (generated.object is null) { return 1; }
    let imports = generated.object;
    let parsed = imports.sections[0].data;
    if (generated.directory_size != 60U || generated.iat_offset != 64U || generated.iat_size != 40U ||
        coff_u64(imports.bytes, parsed.offset + 80) != 9223372036854775815UL || imports.sections[1].size != 12U) {
        print("FAIL: ordinal, shared alias slot or data import");
        return 1;
    }
    let leaf = pe_leaf_object()?;
    catch(err) { return 1; }
    let two_dlls = write_pe([leaf, refs], PeOptions(entry="entry", imports=aliases));
    if (two_dlls.image is null) { print("FAIL: multi-DLL image"); return 1; }
    let multi: PeImage = two_dlls.image;
    let idata = multi.layout.sections[2];
    let start = Int(idata.raw_offset);
    if (coff_u32(multi.bytes, start + 16) != idata.rva + 64U || coff_u32(multi.bytes, start + 36) != idata.rva + 80U ||
        coff_u64(multi.bytes, start + 80) != 9223372036854775815UL || coff_u64(multi.bytes, start + 72) != 0UL ||
        coff_u64(multi.bytes, start + 96) != 0UL || coff_u32(multi.bytes, start + 40) != 0U) {
        print("FAIL: multi-DLL terminators or ordinal thunk value");
        return 1;
    }

    let local = pe_leaf_object()?;
    catch(err) { return 1; }
    result = write_pe([local], PeOptions(entry="entry", imports=[PeImport(dll="missing.dll", name="entry")]));
    if (result.image is null) { print("FAIL: strong definition shadowed by import"); return 1; }
    let defined: PeImage = result.image;
    if (defined.layout.sections.length() != 1) { print("FAIL: unused DLL activated"); return 1; }

    let ordinal_object = pe_ordinal_object()?;
    catch(err) { print("FAIL: ordinal native fixture"); return 1; }
    let ordinal_result = write_pe([ordinal_object], PeOptions(entry="entry", imports=[
        PeImport(dll="white-import-fixture.dll", symbol="Answer", ordinal=7U),
        PeImport(dll="white-import-fixture.dll", name="Constant", is_data=true)]));
    if (ordinal_result.image is null) { print("FAIL: ordinal/data import image"); return 1; }
    let ordinal_image: PeImage = ordinal_result.image;

    if (argc == 2 || argc == 3) {
        let output_image = image;
        if (argc == 3 && argv[2] == "ordinal") { output_image = ordinal_image; }
        let output = file.create(argv[1])?;
        catch(err) { return 1; }
        output.write_bytes(output_image.bytes)?;
        catch(err) { output.close(); return 1; }
        output.close();
    }
    print("PASS: PE DLL imports, ordinals, aliases and call thunks");
    return 0;
}
