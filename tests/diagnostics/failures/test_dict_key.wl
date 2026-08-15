// Test: DICT_KEY_TYPE
// File: tests/diagnostics/failures/test_dict_key.wl
// Focus: Rejecting mutable containers as dynamic Dict keys.
// Expected Error: "Type Vector(Int) cannot be used as a Dict key"

func main() -> Int {
    let key: Vector(Int) = [1, 2, 3];
    let values: Dict = { key: "value" };
    return 0;
}
