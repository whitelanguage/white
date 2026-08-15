// Test: GENERICS_SYSTEM
// File: tests/language/types/test_generics.wl
// Focus: Generic struct instantiation, type erasure via 'Struct' keyword, and higher-order functions.


struct Dog(name: String)

func bark() -> String {
    return "Woof!";
}

func play_with(pet: Struct, action: Function() -> String) -> String {
    // cast generic Struct back to specific type
    let d: Dog = pet;
    return d.name + " says " + action();
}

func main() -> Int {
    let my_dog: Dog = Dog("Buddy");
    let result: String = play_with(my_dog, bark);

    if (result == "Buddy says Woof!") {
        print("PASS: Generics and functional arguments");
    } else {
        print("FAIL: Generic type resolution error");
    }
    return 0;
}
