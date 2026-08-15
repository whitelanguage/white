// Test: ARRAY_CORE_OPERATIONS
// File: tests/language/types/test_array_basic.wl
// Focus: Fixed-size array layout, multi-dimensional indexing, and ARC lifecycle in stack-allocated sequences.


struct Point (
    x: Int,
    y: Int
)

func main() -> Int {
    let nums: Int[5] = [10, 20, 30, 40, 50];
    print("Array nums:", nums); 
    
    nums[2] = 999;
    let index_ok: Bool = (nums[2] == 999);
    print("After mutation:", nums);

    let matrix: Int[2][3] = [[1, 2, 3], [4, 5, 6]];
    let m_val: Int = matrix[1][1]; // expected: 5
    print("Matrix row 1:", matrix[1]);
    print("Element [1][1]:", m_val);

    let points: Point[2] = [Point(x=1, y=2), Point(x=10, y=20)];
    points[0].x = 88;
    let struct_ok: Bool = (points[0].x == 88);
    print("Modified points:", points);

    let words: String[3] = ["Hello", "White", "Language"];
    words[1] = "Power";
    let arc_ok: Bool = (words[1] == "Power");
    print("ARC words:", words);

    let a: Int = 100;
    let b: Int = 200;
    let ptrs: ptr Int[2] = [ref a, ref b];
    let deref_ok: Bool = (deref ptrs[0] == 100);
    print("Deref check:", deref ptrs[0]);

    if (index_ok && m_val == 5 && struct_ok && arc_ok && deref_ok) {
        print("PASS: Fixed-size arrays");
    } else {
        print("FAIL: Fixed-size array result");
        return 1;
    }

    return 0;
}
