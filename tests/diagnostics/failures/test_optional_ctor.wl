// Test: OPTIONAL_CTOR_TYPE
// File: tests/diagnostics/failures/test_optional_ctor.wl
// Focus: Explicit constructor arguments cannot be replaced by the Optional's expected type.
// Expected Error: "TypeError: Type mismatch. Expected (Null | Box(Int)), got Box(String)."

struct Box<T>(value: T)

func main() -> Int {
    let value: Optional(Box(Int)) = Box<String>("text");
    return 0;
}
