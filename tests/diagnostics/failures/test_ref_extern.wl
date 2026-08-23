// Test: REFERENCE_EXTERN_PARAMETER
// File: tests/diagnostics/failures/test_ref_extern.wl
// Focus: Keeping safe reference parameters out of native ABI declarations.
// Expected Error: "ExternError: Extern functions cannot use reference parameters; declare a pointer parameter instead."

extern func update(ref value: Int) -> Void from "C";

func main() -> Int {
    return 0;
}
