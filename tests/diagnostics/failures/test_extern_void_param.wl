// Test: EXTERN_VOID_PARAM
// File: tests/diagnostics/failures/test_extern_void_param.wl
// Focus: Rejecting Void storage before native signature lowering.
// Expected Error: "TypeError: Extern parameters cannot have type Void."

extern "C" {
    func invalid(value: Void) -> Void;
}

func main() -> Int { return 0; }
