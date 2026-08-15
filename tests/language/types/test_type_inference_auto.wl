// Test: TYPE_INFERENCE_AUTO
// File: tests/language/types/test_type_inference_auto.wl
// Focus: Verify that the `Auto` keyword successfully deduces function and method signatures.


func add_nums(x: Int, y: Int) -> Int {
    return x + y;
}

class Counter {
    let value: Int = 0;
    
    init(init_val: Int) -> Void {
        self.value = init_val;
    }
    
    func increment(amount: Int) -> Int {
        self.value += amount;
        return self.value;
    }
}

func main() -> Int {
    // verify auto inference for global function pointers.
    let add: Auto = add_nums;
    let res1: Int = add(10, 20);

    // verify auto inference for bound class methods.
    let c: Counter = Counter(100);
    let inc: Auto = c.increment;
    let res2: Int = inc(5);
    
    let res: Bool = true;
    if (res1 != 30) {
        res = false;
    }
    if (res2 != 105 || c.value != 105) {
        res = false;
    }

    if res {
        print("PASS: Auto type inference for methods and functions is working");
        return 0;
    } else {
        print("FAIL: Auto type inference deduction mismatch");
        return 1;
    }
}
