// Test: FIRST_CLASS_METHOD_DISPATCH
// File: tests/language/oop/test_method_value.wl
// Focus: Method-to-closure binding, environment capture (self-pointer), and 'Class' type erasure.


// global flag for side-effect verification in higher-order functions
let CALLBACK_EXECUTED: Bool = false;
let METHOD_OWNER_DROPPED: Int = 0;

class Dog {
    let name: String = "";
    
    init(n: String) -> Void {
        self.name = n;
    }

    func bark() -> String {
        CALLBACK_EXECUTED = true;
        return self.name + " says: Woof!";
    }

    func get_info(age: Int) -> String {
        return self.name + " is " + age;
    }
}

class MethodOwner {
    init() {}

    func read() -> Int {
        return 7;
    }

    deinit() {
        METHOD_OWNER_DROPPED++;
    }
}

class Counter {
    init() {}

    func read() -> Int {
        return 1;
    }
}

class VirtualCounter(Counter) {
    init() {}

    func read() -> Int {
        return 2;
    }
}

// higher-order function accepting a bound method closure
func execute_callback(m: Method() -> String) -> String {
    return m();
}

func exercise_method_owner() -> Bool {
    let owner: MethodOwner = MethodOwner();
    let read: Method() -> Int = owner.read;
    return read() == 7;
}

func exercise_virtual_method() -> Bool {
    let concrete: VirtualCounter = VirtualCounter();
    let base: Counter = concrete;
    let read: Method() -> Int = base.read;
    return read() == 2;
}

func main() -> Int {
    let my_dog: Dog = Dog(n="Buddy");
    let any_class: Class = my_dog; 


    let bark_func: Method() -> String = my_dog.bark;
    let info_func: Method(Int) -> String = my_dog.get_info;


    let bark_res: String = bark_func();
    let info_res: String = info_func(3);


    let callback_res: String = execute_callback(bark_func);
    let owner_ok: Bool = exercise_method_owner() && METHOD_OWNER_DROPPED == 1;
    let virtual_ok: Bool = exercise_virtual_method();


    let upcast_ok: Bool = (any_class is ! null);
    let bark_ok: Bool = (bark_res == "Buddy says: Woof!");
    let info_ok: Bool = (info_res == "Buddy is 3");
    let callback_ok: Bool = (callback_res == "Buddy says: Woof!" && CALLBACK_EXECUTED);

    if (upcast_ok && bark_ok && info_ok && callback_ok && owner_ok && virtual_ok) {
        print("PASS: First-class methods and environment capture");
    } else {
        // if this fails, the closure environment or VTable routing is corrupted
        print("FAIL: Method binding or higher-order dispatch error");
        return 1;
    }

    return 0;
}
