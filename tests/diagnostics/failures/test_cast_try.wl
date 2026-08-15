// Test: CAST_TRY
// File: tests/diagnostics/failures/test_cast_try.wl
// Focus: The try operator cannot be applied to an infallible class conversion.
// Expected Error: "InvalidSyntax: Conversion to Int cannot fail; remove '?'"

class Value {
    type Int {
        return 1;
    }
}

func main() -> Int {
    let value: Value = Value();
    let result: Int = Int(value)?;
    catch(err) {
        return 1;
    }
    return result;
}
