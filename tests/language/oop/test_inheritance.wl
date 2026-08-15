// Test: INHERITANCE_AND_POLYMORPHISM
// File: tests/language/oop/test_inheritance.wl
// Focus: VTable layout for overridden methods, super-constructor chaining, and implicit upcasting.


class Animal {
    let name: String = "Unknown";
    let age: Int = 0;

    init(n: String, a: Int) -> Void {
        self.name = n;
        self.age = a;
    }

    func speak() -> String {
        return "The animal makes a sound.";
    }
}

class Dog(Animal) {
    let breed: String = "Mutt";

    init(n: String, a: Int, b: String) -> Void {
        super.init(n, a); // testing super-call logic
        self.breed = b;
    }

    // Override parent method
    func speak() -> String {
        return self.name + " says: Woof!";
    }
    
    func fetch() -> String {
        return self.name + " is fetching.";
    }
}

class Cat(Animal) {
    init(n: String, a: Int) -> Void {
        self.name = n;
        self.age = a;
    }

    func speak() -> String {
        return self.name + " says: Meow~";
    }
}

func main() -> Int {
    // basic instance verification
    let dog: Dog = Dog("Buddy", 3, "Golden");
    let cat: Cat = Cat("Whiskers", 2);

    // polymorphism (ipcasting) test
    // this verifies VTable offset calculation and implicit pointer casting
    let poly_dog: Animal = dog; 
    let poly_cat: Animal = cat;

    let dog_speaks: String = poly_dog.speak(); // must trigger Dog.speak()
    let cat_speaks: String = poly_cat.speak(); // must trigger Cat.speak()

    let dog_name_ok: Bool = (poly_dog.name == "Buddy"); // accessing parent field via Animal pointer
    let dog_vtable_ok: Bool = (dog_speaks == "Buddy says: Woof!");
    let cat_vtable_ok: Bool = (cat_speaks == "Whiskers says: Meow~");

    if (dog_name_ok && dog_vtable_ok && cat_vtable_ok) {
        print("PASS: OOP inheritance and polymorphic dispatch");
    } else {
        print("FAIL: VTable dispatch or field inheritance mismatch");
        return 1;
    }

    return 0;
}
