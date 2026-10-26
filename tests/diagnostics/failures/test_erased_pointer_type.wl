// Test: ERASED_POINTER_TYPE
// File: tests/diagnostics/failures/test_erased_pointer_type.wl
// Focus: A non-null pointer must retain its exact pointee type.
// Expected Error: "RuntimeError: Erased value has the wrong concrete type"

func main() -> Int {
    let number = 42;
    let ptr original: Int = ref number;
    let values: Dict = {"value": original};
    let ptr value: Byte = values.get("value")?;
    catch(err) { return 1; }
    return 0;
}
