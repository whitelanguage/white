// Test: NULL_ERASED_STRING
// File: tests/diagnostics/failures/test_null_erased_text.wl
// Focus: A dynamic dictionary cannot restore its stored null as an ordinary String.
// Expected Error: "RuntimeError: Erased value has the wrong concrete type"

func main() -> Int {
    let values: Dict = {"absent": null};
    let text: String = values.get("absent")?;
    catch(err) { return 1; }
    print(text);
    return 0;
}
