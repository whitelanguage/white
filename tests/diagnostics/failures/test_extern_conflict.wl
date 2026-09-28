// Test: EXTERN_DECLARATION_CONFLICT
// File: tests/diagnostics/failures/test_extern_conflict.wl
// Focus: Rejecting incompatible declarations of one native symbol across modules.
// Expected Error: "ExternError: Conflicting extern declaration for symbol 'external_redeclaration_probe'."

import "../../fixtures/ffi/extern_redeclaration.wl"

extern "C" {
    func external_redeclaration_probe(value: Long) -> Int;
}

func main() -> Int {
    return 0;
}
