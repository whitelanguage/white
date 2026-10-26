// Test: ERASED_POINTER_STRING
// File: tests/diagnostics/failures/test_erased_pointer_text.wl
// Focus: Stored nullptr cannot initialize a String.
// Expected Error: "RuntimeError: Erased value has the wrong concrete type"

func main() -> Int {
    let values: Dict = {"value": nullptr};
    let value: String = values.get("value")?;
    catch(err) { return 1; }
    return 0;
}
