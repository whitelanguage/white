// Test: UNION_CONSTANTS
// File: tests/language/types/test_union_constants.wl
// Focus: Constant references remap union tags and preserve inline data and relocations.

import "../../fixtures/union_constants/source.wl" as constants


struct Pair(left: String, right: String)
struct Record(count: Optional(Int), text: Optional(String))
type Label = String;

const TEXT: String = "hello";
const INTEGER: Int = 42;
const LONG: Long = INTEGER;
const FLOAT: Optional(Float) = Float(INTEGER);
const SMALL: Optional(String) = TEXT;
const COPY: Optional(String) = SMALL;
const WIDE: Int128 | Int | String | Null = COPY;
const NONE: Optional(String) = null;
const WIDE_NONE: Int128 | String | Null = NONE;
const NUMBER: Optional(Int) = 42;
const WIDE_NUMBER: Int128 | Int | String | Null = NUMBER;
const BIG: Optional(Int128) = 123456789012345678901234567890LL;
const WIDE_BIG: Int128 | String | Null = BIG;
const PAIR: Optional(Pair) = Pair(TEXT, "right");
const WIDE_PAIR: Int128 | Pair | Null = PAIR;
const RECORD: Optional(Record) = Record(NUMBER, SMALL);
const WIDE_RECORD: Int128 | Record | Null = RECORD;
const NAMED: Optional(Label) = Label("label");
const WIDE_NAMED: Int128 | Label | Null = NAMED;
const IMPORTED: Int128 | String | Null = constants.VALUE;
let writable: Int128 | Int | String | Null = NUMBER;

func main() -> Int {
    if (!is_type(WIDE, String)) { return 1; }
    if (WIDE != "hello") { return 2; }
    if (WIDE_NONE is !null) { return 3; }
    if (!is_type(WIDE_NUMBER, Int)) { return 4; }
    if (WIDE_NUMBER != 42) { return 5; }
    if (!is_type(WIDE_PAIR, Pair)) { return 6; }
    if (WIDE_PAIR.left != "hello" || WIDE_PAIR.right != "right") { return 7; }
    if (!is_type(WIDE_RECORD, Record)) { return 8; }
    let record = WIDE_RECORD;
    if (record.count is null || record.count != 42) { return 9; }
    if (record.text is null || record.text != "hello") { return 10; }
    if (!is_type(WIDE_NAMED, Label)) { return 11; }
    if (String(WIDE_NAMED) != "label") { return 12; }
    if (!is_type(IMPORTED, String)) { return 13; }
    if (IMPORTED != "imported") { return 13; }
    writable = "changed";
    if (!is_type(writable, String)) { return 14; }
    if (writable != "changed" || NUMBER is null || NUMBER != 42) { return 15; }
    if (!is_type(WIDE_BIG, Int128)) { return 16; }
    if (WIDE_BIG != 123456789012345678901234567890LL) { return 17; }
    if (LONG != 42L || FLOAT is null || FLOAT != 42.0) { return 18; }
    print("PASS: union constants");
    return 0;
}
