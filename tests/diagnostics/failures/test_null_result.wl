// Test: NULL_RESULT
// File: tests/diagnostics/failures/test_null_result.wl
// Focus: A fallible integer return still requires an integer success value.
// Expected Error: "TypeError: Type Int cannot be null."

func value() -> Int? {
    return null;
}

func main() -> Int {
    let number = value()?;
    catch(err) { return 1; }
    return number;
}
