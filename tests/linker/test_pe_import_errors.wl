// Test: PE_IMPORT_ERRORS
// File: tests/linker/test_pe_import_errors.wl
// Focus: Invalid metadata, unresolved references and conflicting import bindings.
import * from "../../src/linker/pe/model.wl"
import * from "../../src/linker/pe/imports.wl"
import write_pe from "../../src/linker/pe/writer.wl"
import * from "../../src/linker/coff/link_model.wl"
import * from "../fixtures/linker/pe_import_objects.wl"
import * from "../fixtures/linker/pe_objects.wl"


func main() -> Int {
    let refs = pe_import_refs(["foo"])?;
    catch(err) { print("FAIL: import reference fixture"); return 1; }
    let invalid = [PeImport(dll="", name="foo"), PeImport(dll="../a.dll", name="foo"), PeImport(dll="C:\\a.dll", name="foo"),
        PeImport(dll="a.dll", symbol="foo"), PeImport(dll="a.dll", name="foo", hint=65536U),
        PeImport(dll="a.dll", symbol="foo", ordinal=65536U), PeImport(dll="a.dll", name="foo", ordinal=1U),
        PeImport(dll="a.dll", symbol="foo", ordinal=1U, hint=1U), PeImport(dll="a.dll", name="foo", symbol="__imp_foo"),
        PeImport(dll="a.dll", name="你好", symbol="foo"), PeImport(dll="a" + String('\0') + ".dll", name="foo")];
    let i = 0;
    while (i < invalid.length()) {
        let result = pe_select_imports([refs], [invalid[i]]);
        if (result.errors.length() != 1 || result.errors[0].status != CoffLinkStatus.InvalidLayout) {
            print("FAIL: invalid import metadata ", i);
            return 1;
        }
        i++;
    }
    let selected = pe_select_imports([refs], [PeImport(dll="a.dll", name="foo"), PeImport(dll="b.dll", name="foo")]);
    if (selected.errors.length() != 1 || selected.errors[0].status != CoffLinkStatus.InvalidLayout) { return 1; }
    selected = pe_select_imports([refs], [PeImport(dll="a.dll", name="foo"), PeImport(dll="A.DLL", name="foo", hint=2U)]);
    if (selected.errors.length() != 0 || selected.entries.length() != 1 || !selected.direct[0]) {
        print("FAIL: compatible duplicate import declarations");
        return 1;
    }
    selected = pe_select_imports([refs], [PeImport(dll="a.dll", name="foo", is_data=true)]);
    if (selected.errors.length() != 1 || selected.errors[0].status != CoffLinkStatus.UndefinedSymbol) {
        print("FAIL: data import incorrectly bound a direct symbol");
        return 1;
    }
    selected = pe_select_imports([refs], [PeImport(dll="a.dll", name="Foo")]);
    if (selected.errors.length() != 1 || selected.errors[0].status != CoffLinkStatus.UndefinedSymbol) {
        print("FAIL: export names treated as case-insensitive");
        return 1;
    }
    let image = write_pe([refs], PeOptions(entry="foo", imports=[PeImport(dll="a.dll", name="foo")]));
    if (image.image is !null || image.errors.length() != 1 || image.errors[0].status != CoffLinkStatus.InvalidLayout) {
        print("FAIL: process entry was imported from a DLL");
        return 1;
    }
    let local = pe_leaf_object()?;
    catch(err) { return 1; }
    let alias_refs = pe_import_refs(["__imp_entry"])?;
    catch(err) { return 1; }
    image = write_pe([local, alias_refs], PeOptions(entry="entry", imports=[PeImport(dll="a.dll", name="Exported", symbol="entry")]));
    if (image.image is null) {
        print("FAIL: IAT import collided with an existing direct definition");
        return 1;
    }
    let complete: PeImage = image.image;
    if (complete.layout.sections[0].size != 6U) { print("FAIL: unnecessary call thunk emitted"); return 1; }
    let missing = pe_make_imports([PeImport(dll="a.dll", name="foo")], []);
    if (missing.object is !null || missing.errors.length() != 1) { return 1; }

    // all references reuse the same export slot, the query path must scale with references.
    let names: Vector(String) = [];
    i = 0;
    while (i < 256) { names.append("__imp_foo"); i++; }
    let many = pe_import_refs(names)?;
    catch(err) { print("FAIL: repeated import reference fixture"); return 1; }
    selected = pe_select_imports([many], [PeImport(dll="a.dll", name="foo")]);
    if (selected.errors.length() != 0 || selected.entries.length() != 1 || selected.direct[0]) {
        print("FAIL: repeated import references");
        return 1;
    }
    print("PASS: invalid PE imports and symbol binding boundaries");
    return 0;
}
