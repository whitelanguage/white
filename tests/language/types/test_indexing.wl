// Test: INDEXING_ACCESS
// File: tests/language/types/test_indexing.wl
// Focus: Array-style indexing ([]) for Vector read/write and String read-only access.


func main() -> Int {
    // 1. Vector index mutation
    let v: Vector(Int) = [10, 20, 30];
    v[1] = 999;
    
    // 2. String byte access
    let s: String = "ABC";
    let first_byte: Char = s[0];

    if (v[1] == 999 && first_byte == 'A') {
        print("PASS: Vector and String indexing");
    } else {
        print("FAIL: Indexing value mismatch");
    }
    return 0;
}
