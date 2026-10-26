// Test: ERASED_POINTER_NULL
// File: tests/diagnostics/failures/test_erased_pointer_null.wl
// Focus: Stored nullptr cannot be recovered as Null.
// Expected Error: "RuntimeError: Erased value has the wrong concrete type"

func main() -> Int {
    let values: Dict = {"value": nullptr};
    let value: Null = values.get("value")?;
    catch(err) { return 1; }
    return 0;
}
