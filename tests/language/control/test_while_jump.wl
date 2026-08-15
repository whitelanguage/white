// Test: WHILE_LOOP_CONTROL
// File: tests/language/control/test_while_jump.wl
// Focus: While loop execution with 'continue' and 'break' jump instructions.


func main() -> Int {
    let i: Int = 0;
    let sum: Int = 0;

    while (i < 10) {
        i = i + 1;
        
        if (i == 5) { continue; } // skip 5
        if (i > 8) { break; }    // stop after 8 (sum includes 1,2,3,4,6,7,8)
        
        sum = sum + i;
    }

    // 1+2+3+4+6+7+8 = 31
    if (sum == 31) {
        print("PASS: While loop with jump instructions");
    } else {
        print("FAIL: While loop sum mismatch. Got: " + sum);
    }
    return 0;
}
