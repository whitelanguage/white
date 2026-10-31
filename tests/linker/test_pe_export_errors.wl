// Test: PE_EXPORT_ERRORS
// File: tests/linker/test_pe_export_errors.wl
// Focus: invalid export metadata, missing/local/end symbols and discarded storage.
import * from "../../src/linker/pe/model.wl"
import write_pe from "../../src/linker/pe/writer.wl"
import plan_pe from "../../src/linker/pe/layout.wl"
import * from "../fixtures/linker/pe_objects.wl"
import pe_api_object from "../fixtures/linker/pe_import_objects.wl"


func main() -> Int {
    let object = pe_leaf_object()?;
    catch(err) { return 1; }
    let invalid = [PeExport(), PeExport(symbol="entry"), PeExport(name="entry", ordinal=0U), PeExport(name="entry", ordinal=65536U),
        PeExport(name="你", symbol="entry"), PeExport(name="bad" + String('\0'), symbol="entry"), PeExport(name="valid", symbol=String('\0'))];
    let i = 0;
    while (i < invalid.length()) {
        let result = write_pe([object], PeOptions(entry="entry", exports=[invalid[i]]));
        if (result.image is !null || result.errors.length() != 1) { print("FAIL: invalid export accepted ", i); return 1; }
        i++;
    }
    let requests = [[PeExport(name="entry"), PeExport(name="entry")],
        [PeExport(name="entry", ordinal=7U), PeExport(name="alias", symbol="entry", ordinal=7U)], [PeExport(name="missing")]];
    i = 0;
    while (i < requests.length()) {
        let result = write_pe([object], PeOptions(entry="entry", exports=requests[i]));
        if (result.image is !null || result.errors.length() != 1) { print("FAIL: conflicting or missing export"); return 1; }
        i++;
    }
    let paths = ["", "dir/a.dll", "dir\\a.dll", "a:foo.dll", "a" + String('\0')];
    i = 0;
    while (i < paths.length()) {
        let result = write_pe([object], PeOptions(entry="entry", image_name=paths[i], exports=[PeExport(name="entry")]));
        if (result.image is !null) { print("FAIL: invalid export image name"); return 1; }
        i++;
    }
    let local = object;
    local.symbols[0].storage = Byte(3);
    let result = write_pe([local], PeOptions(entry="", is_dll=true, exports=[PeExport(name="entry")]));
    if (result.image is !null || result.errors.length() != 1) { print("FAIL: local symbol exported"); return 1; }
    // Vector fields share storage, restore it before checking the next independent case.
    local.symbols[0].storage = Byte(2);
    local.symbols[0].value = local.sections[0].size;
    result = write_pe([local], PeOptions(entry="", is_dll=true, exports=[PeExport(name="entry")]));
    if (result.image is !null) { print("FAIL: end-of-section export"); return 1; }
    local.symbols[0].value = 0U;
    local.sections[0].flags |= 2048U;
    result = write_pe([local], PeOptions(entry="", is_dll=true, exports=[PeExport(name="entry")]));
    if (result.image is !null) { print("FAIL: removed export"); return 1; }
    local.sections[0].flags &= ~2048U;

    result = write_pe([object], PeOptions(entry=""));
    if (result.image is !null) { print("FAIL: entryless EXE"); return 1; }
    let api = pe_api_object()?;
    catch(err) { return 1; }
    result = write_pe([api], PeOptions(entry="entry", imports=[PeImport(dll="kernel32.dll", name="SetLastError"),
        PeImport(dll="kernel32.dll", name="GetLastError")], exports=[PeExport(name="SetLastError")]));
    if (result.image is !null) { print("FAIL: imported thunk exported as a local definition"); return 1; }
    let bad_reserve = plan_pe([object], -1, 97);
    if (bad_reserve.layout is !null) { print("FAIL: invalid section reserve"); return 1; }
    print("PASS: invalid PE exports and entry policy");
    return 0;
}
