// Test: ERASED_NULL_POINTER
// File: tests/diagnostics/failures/test_erased_null_pointer.wl
// Focus: Stored Null cannot initialize a raw pointer.
// Expected Error: "RuntimeError: Erased value has the wrong concrete type"

func main() -> Int {
    let values: Dict = {"value": null};
    let ptr value: Int = values.get("value")?;
    catch(err) { return 1; }
    return 0;
}
