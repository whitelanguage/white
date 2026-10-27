// Test: DLL_SYMBOL_EXPORT
// File: tests/integration/ffi/test_lib_export.wl
// Focus: Shared library symbol exporting, recursive stack frame integrity, and float ABI stability.

const DEFAULT_COUNT: Optional(Int) = 42;

@ExportLib
let exported_count: Optional(Int) = DEFAULT_COUNT;

@ExportLib
func read_count() -> Int {
    if (exported_count is null) { return -1; }
    return exported_count;
}

@ExportLib
// basic i32 addition for export validation
func add(a: Int, b: Int) -> Int {
    return a + b;
}

@ExportLib
// recursive factorial: tests internal control flow and stack frame preservation in exported context
func factorial(n: Int) -> Int {
    if (n <= 1) { 
        return 1; 
    }
    return n * factorial(n - 1);
}

@ExportLib
// verify float-point multiplier and IEEE 754 ABI compliance
func multiply_float(a: Float, b: Float) -> Float {
    return a * b;
}
