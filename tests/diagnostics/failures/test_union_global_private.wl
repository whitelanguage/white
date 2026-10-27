// Test: UNION_GLOBAL_PRIVATE
// File: tests/diagnostics/failures/test_union_global_private.wl
// Focus: Constant folding keeps module-private globals out of imported namespaces.
// Expected Error: "NameError: Undefined module variable 'source.__SECRET'."

import "../../fixtures/union_constants/source.wl" as source


const copy: Optional(String) = source.__SECRET;

func main() -> Int {
    return 0;
}
