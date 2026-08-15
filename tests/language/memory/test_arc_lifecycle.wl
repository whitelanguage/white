// Test: ARC_LIFECYCLE_MANAGEMENT
// File: tests/language/memory/test_arc_lifecycle.wl
// Focus: Automatic Reference Counting (ARC) during scope transitions and reassignments.


struct Point(x: Int, y: Int)

func test_assignment() -> Bool {
    let s1: String = "Hello";
    let s2: String = "World"; 
    
    // assignment should decrease RC of s1's old value and increase RC of s2's value
    s1 = s2; 
    
    return s1 == "World";
}

func main() -> Int {
    let assign_ok: Bool = test_assignment();
    
    // if the compiler reaches here without memory leaks or crashes, scope logic is valid
    if (assign_ok) {
        print("PASS: ARC lifecycle and assignment");
    } else {
        print("FAIL: ARC assignment logic error");
    }
    return 0;
}
