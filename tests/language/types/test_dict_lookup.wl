// Test: DICT_LOOKUP
// File: tests/language/types/test_dict_lookup.wl
// Focus: Missing typed entries remain distinct from stored zero and empty values.

struct Entry(value: Int)

class Item {
    let value: Int;
    init(value: Int) { self.value = value; }
}

func main() -> Int {
    let ints: Dict(String, Int) = Dict();
    ints.put("zero", 0);
    let zero = ints.lookup("zero");
    if (zero is null || zero != 0 || ints.lookup("missing") is !null) {
        print("FAIL: integer lookup lost presence");
        return 1;
    }

    let flags: Dict(Int, Bool) = Dict();
    flags.put(1, false);
    let flag = flags.lookup(1);
    if (flag is null || flag || flags.lookup(2) is !null) {
        print("FAIL: false is a stored value");
        return 1;
    }

    let text: Dict(Int, String) = Dict();
    text.put(1, "");
    let empty = text.lookup(1);
    if (empty is null || empty.length() != 0 || text.lookup(2) is !null) {
        print("FAIL: empty String lookup");
        return 1;
    }

    let records: Dict(Int, Entry) = Dict();
    records.put(1, Entry(0));
    let record = records.lookup(1);
    if (record is null || record.value != 0 || records.lookup(2) is !null) {
        print("FAIL: value Struct lookup");
        return 1;
    }

    let objects: Dict(Int, Item) = Dict();
    objects.put(1, Item(42));
    let object = objects.lookup(1);
    if (object is null || object.value != 42 || objects.lookup(2) is !null) {
        print("FAIL: class lookup");
        return 1;
    }
    objects.remove(1);
    if (objects.lookup(1) is !null) {
        print("FAIL: removed entry is still present");
        return 1;
    }

    let nullable: Dict(Int, Optional(String)) = Dict();
    nullable.put(1, null);
    let stored_null = nullable.get(1)?;
    catch(err) { print("FAIL: stored Null reported a missing key"); return 1; }
    if (stored_null is !null || !nullable.contains_key(1) || nullable.contains_key(2)) {
        print("FAIL: nullable entries lost their occupancy state");
        return 1;
    }

    print("PASS: typed dictionary lookup presence");
    return 0;
}
