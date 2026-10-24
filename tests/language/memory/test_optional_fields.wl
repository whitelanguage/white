// Test: OPTIONAL_FIELD_OWNERSHIP
// File: tests/language/memory/test_optional_fields.wl
// Focus: Narrowed receivers release temporary references while copied fields remain alive.

let DROPPED: Int = 0;

class Record {
    let number: Int = 42;
    let text: String = "record";
    let values: Vector(Int) = [1, 2];

    deinit() { DROPPED++; }
}

func main() -> Int {
    let record: Optional(Record) = Record();
    if (record is null) { return 1; }

    let number = record.number;
    let text = record.text;
    let values = record.values;
    record = null;

    if (DROPPED != 1 || number != 42 || text != "record" || values[1] != 2) {
        print("FAIL: Optional field ownership", DROPPED);
        return 1;
    }

    print("PASS: Optional field ownership");
    return 0;
}
