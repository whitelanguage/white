// Test: CLASS_FIELD_INITIALIZATION
// File: tests/language/oop/test_field_init.wl
// Focus: Initializing class fields in constructors and across branches.


class Record {
    let name: String;
    let value: Int;

    init(name: String, value: Int, adjust: Bool) -> Void {
        self.name = name;
        if adjust {
            self.value = value + 1;
        } else {
            self.value = value;
        }
    }

    func valid() -> Bool {
        return self.name == "entry" && self.value == 8;
    }
}

class Base {
    let id: Int;

    init(id: Int) -> Void {
        self.id = id;
    }
}

class Derived(Base) {
    let text: String;

    init(id: Int, text: String) -> Void {
        super.init(id);
        self.text = text;
    }

    func valid() -> Bool {
        return self.id == 4 && self.text == "derived";
    }
}

class DefaultBase {
    let base_value: Int = 3;
}

class DefaultDerived(DefaultBase) {
    let child_value: String = "default";
}

class ConstantBranch {
    let value: Int;

    init() -> Void {
        if true {
            self.value = 9;
        }
    }
}

class OrderedDefaults {
    let first: Int = 4;
    let second: Int = self.first + 1;
}

class VectorField {
    let values: Vector(Int);

    init() -> Void {
        self.values = [0];
    }
}

func main() -> Int {
    let record: Record = Record("entry", 7, true);
    let derived: Derived = Derived(4, "derived");
    let defaults: DefaultDerived = DefaultDerived();
    let constant: ConstantBranch = ConstantBranch();
    let ordered: OrderedDefaults = OrderedDefaults();
    let vector: VectorField = VectorField();
    if (!record.valid() ||
        !derived.valid() ||
        defaults.base_value != 3 ||
        defaults.child_value != "default" ||
        constant.value != 9 ||
        ordered.second != 5 ||
        vector.values[0] != 0) {
        print("FAIL: class field initialization");
        return 1;
    }
    print("PASS: class field initialization");
    return 0;
}
