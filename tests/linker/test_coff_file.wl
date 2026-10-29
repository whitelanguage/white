// Test: COFF_FILE_READER
// File: tests/linker/test_coff_file.wl
// Focus: Read an emitted object file, optionally check a supplied compiler or Clang object.

import "file"
import * from "../../src/linker/coff/model.wl"
import read_coff from "../../src/linker/coff/reader.wl"
import coff_object_for_text from "../../src/compiler/machine/x86_64/coff.wl"


func main(argc: Int, ptr argv: String) -> Int {
    let path: String = "test_coff_reader.tmp";
    let temporary: Bool = argc == 1;
    if temporary {
        let bytes = coff_object_for_text("main", [Byte(184), Byte(42), Byte(0), Byte(0), Byte(0), Byte(195)])?;
        catch(err) { print("FAIL: object fixture"); return 1; }
        let output = file.create(path)?;
        catch(err) { print("FAIL: create object fixture"); return 1; }
        output.write_bytes(bytes)?;
        catch(err) { output.close(); print("FAIL: write object fixture"); return 1; }
        output.close();
    } else {
        path = argv[1];
    }

    let input = file.open(path)?;
    catch(err) { print("FAIL: open object", path); return 1; }
    let raw: String = input.read_all()?;
    catch(err) { input.close(); print("FAIL: read object", path); return 1; }
    input.close();
    if temporary {
        file.remove(path)?;
        catch(err) { print("FAIL: remove object fixture"); return 1; }
    }
    let bytes: Vector(Byte) = [];
    let i: Int = 0;
    while (i < raw.length()) {
        bytes.append(raw[i]);
        i++;
    }
    let repeats: Int = 1;
    if (argc > 2 && argv[2] == "repeat") { repeats = 20; }
    i = 0;
    while (i < repeats) {
        let result = read_coff(bytes);
        if (result.object is null) {
            print("FAIL: COFF byte", result.offset, result.message);
            return 1;
        }
        let object: CoffObject = result.object;
        let reloc_count: Int = 0;
        let j: Int = 0;
        while (j < object.sections.length()) {
            reloc_count += object.sections[j].relocs.length();
            j++;
        }
        if (i == 0) { print("COFF:", object.sections.length(), "sections,", object.symbols.length(), "symbols,", reloc_count, "relocations"); }
        i++;
    }

    print("PASS: COFF file reader");
    return 0;
}
