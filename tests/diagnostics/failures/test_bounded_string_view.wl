// Test: BOUNDED_STRING_VIEW
// File: tests/diagnostics/failures/test_bounded_string_view.wl
// Focus: Bounded zero-copy String views are rejected until their ownership model is implemented.
// Expected Error: "TypeError: String views currently require a full slice expression."

func main() -> Int {
    let value: String = "WhiteLang";
    let invalid: String = ref value[0:5];
    return 0;
}
