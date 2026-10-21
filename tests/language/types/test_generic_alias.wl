// Test: GENERIC_ALIAS
// File: tests/language/types/test_generic_alias.wl
// Focus: Generic aliases preserve type identity, context and container ownership.

type T as Identity<T>;
type Vector(T) as List<T>;
type List(T) as Items<T>;

func identity<T>(value: T) -> Identity(T) {
    return value;
}

func main() -> Int {
    let values: Items(Int) = [10, 20];
    let alias: Vector(Int) = values;
    alias.append(30);

    let text: Identity(String) = identity("same type");
    let number: Identity(Int) = identity(42);
    if (values.length() != 3 || values[2] != 30 || text != "same type" || number != 42) {
        print("FAIL: generic alias changed its target type");
        return 1;
    }

    print("PASS: generic type aliases");
    return 0;
}
