// Test: CLASS_INHERITANCE_CYCLE
// File: tests/diagnostics/failures/test_class_cycle.wl
// Focus: Rejecting class inheritance cycles before either backend computes object layout.
// Expected Error: "TypeError: Class inheritance cycle involving 'Right'."

class Left(Right) {}
class Right(Left) {}

func main() -> Int {
    return 0;
}
