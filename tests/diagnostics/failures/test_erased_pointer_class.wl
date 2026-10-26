// Test: ERASED_POINTER_CLASS
// File: tests/diagnostics/failures/test_erased_pointer_class.wl
// Focus: Stored nullptr cannot bypass a class's non-null source type.
// Expected Error: "RuntimeError: Erased value has the wrong concrete type"

class Box { }

func main() -> Int {
    let values: Dict = {"value": nullptr};
    let value: Box = values.get("value")?;
    catch(err) { return 1; }
    return 0;
}
