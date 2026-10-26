// Test: POINTER_PRINT
// File: tests/language/types/test_pointer_print.wl
// Focus: Printing pointer fields without confusing their pointee with a value.

struct Pointers(ptr number: Int, ptr text: Byte)

func main() -> Int {
    let number: Int = 42;
    let text: Byte[4] = [Byte(111), Byte(107), Byte(0), Byte(0)];
    let record: Pointers = Pointers(ref number, ref text[0]);
    print(record);
    print(record.number, record.text);
    if (deref record.number != 42) { print("FAIL: pointer field changed"); return 1; }
    print("PASS: pointer fields");
    return 0;
}
