// Test: BYTE_OVERFLOW
// File: tests/language/basics/test_byte_overflow.wl
// Focus: i8 wrap-around behavior and i32 promotion rules.


func main() -> Int {
    let b1: Byte = 250;
    let b2: Byte = 10;
    
    // 8-bit wrap-around: (250 + 10) = 260. 260 % 256 = 4
    let b3: Byte = b1 + b2;
    
    // Int promotion: 250 + 100 = 350
    let i: Int = b1 + 100;

    if (b3 == 4 && i == 350) {
        print("PASS: Byte overflow and promotion");
    } else {
        print("FAIL: Byte semantics error");
    }
    return 0;
}
