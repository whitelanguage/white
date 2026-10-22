// Test: DICT_GET_UNHANDLED
// File: tests/diagnostics/failures/test_dict_get.wl
// Focus: Dynamic Dict reads require explicit error handling, like typed Dict reads.
// Expected Error: "TypeError: call to fallible function 'get' requires '?'"

func main() -> Int {
    let values: Dict = { "one": 1 };
    let value: Int = values["one"];
    return value;
}
