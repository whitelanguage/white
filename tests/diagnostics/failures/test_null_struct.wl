// Test: NULL_STRUCT_RETURN
// File: tests/diagnostics/failures/test_null_struct.wl
// Focus: Inline struct returns cannot use a null success value.
// Expected Error: "TypeError: Type Point cannot be null."

struct Point(x: Int)

func value() -> Point {
    return null;
}

func main() -> Int {
    let point: Point = value();
    return point.x;
}
