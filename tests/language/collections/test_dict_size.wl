// Test: DICT_SIZE_VALUES
// File: tests/language/collections/test_dict_size.wl
// Focus: Boxing and restoring pointer-sized integers without same-width casts.

import "dict"


func main() -> Int {
    let values: Dict = Dict(8);
    values.put("signed", IntSize(-7));
    values.put("unsigned", UIntSize(40));

    let signed: IntSize = values.get("signed")?;
    catch(err) { return 1; }
    let unsigned: UIntSize = values.get("unsigned")?;
    catch(err) { return 1; }

    if (signed != IntSize(-7) || unsigned != UIntSize(40)) {
        print("FAIL: pointer-sized dictionary values");
        return 1;
    }

    print("PASS: pointer-sized dictionary values");
    return 0;
}
