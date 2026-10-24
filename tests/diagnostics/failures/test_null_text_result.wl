// Test: NULL_STRING_RESULT
// File: tests/diagnostics/failures/test_null_text_result.wl
// Focus: A fallible String result cannot use null as its success value.
// Expected Error: "TypeError: Type String cannot be null."

func text() -> String? {
    return null;
}

func main() -> Int {
    text()?;
    catch(err) { return 1; }
    return 0;
}
