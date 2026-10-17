// Test: RECORD_ALIGNMENT
// File: tests/language/memory/test_record_alignment.wl
// Focus: Odd-sized records retain their target alignment when copied out of a Vector.

struct Row(op: UInt32, kind: UInt32, name: String)

func fingerprint(row: Row) -> UInt64 {
    return (UInt64(row.op) << 9) ^ (UInt64(row.kind) << 17);
}

func main() -> Int {
    let rows: Vector(Row) = [];
    let i: Int = 0;
    while (i < 65) {
        rows.append(Row(UInt32(i), UInt32(i + 3), "row"));
        i++;
    }

    i = 0;
    while (i < rows.length()) {
        let expected: UInt64 = (UInt64(i) << 9) ^ (UInt64(i + 3) << 17);
        if (fingerprint(rows[i]) != expected || rows[i].name != "row") {
            print("FAIL: record copy changed field values");
            return 1;
        }
        i++;
    }
    print("PASS: contiguous record alignment");
    return 0;
}
