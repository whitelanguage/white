// Test: VECTOR_DYNAMIC_ARRAY
// File: tests/language/types/test_vector_ops.wl
// Focus: Vector heap growth (append), element removal (drop), and length tracking.


func main() -> Int {
    let v: Vector(Int) = [10, 20];
    v.append(30);
    
    let original_len: Int = v.length(); // 3
    let popped_val: Int = v.drop();    // 30
    let final_len: Int = v.length();    // 2

    if (original_len == 3 && popped_val == 30 && final_len == 2) {
        print("PASS: Vector dynamic mutation");
    } else {
        print("FAIL: Vector mutation result");
        return 1;
    }
    return 0;
}
