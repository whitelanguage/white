// Test: ARC_POLYMORPHIC_DEINIT
// File: tests/language/oop/test_deinit.wl
// Focus: VTable-based virtual teardown, ARC-driven heap release, and ABI-safe super-call chaining.


let SUB_DEINIT_TRIGGERED: Bool = false;
let SUPER_DEINIT_TRIGGERED: Bool = false;

class Resource {
    let name: String = "";
    
    init(n: String) -> Void {
        self.name = n;
    }
    
    // virtual destructor hook in parent
    deinit() -> Void {
        SUPER_DEINIT_TRIGGERED = true;
    }
}

class NetworkConnection(Resource) {
    let ip: String = "";
    
    init(n: String, ip: String) -> Void {
        super.init(n); // testing constructor chaining
        self.ip = ip;
    }
    
    // override deinit
    deinit() -> Void {
        SUB_DEINIT_TRIGGERED = true;
        super.deinit(); 
    }
}

func run_scope_test() -> Void {
    // assigning subclass to parent reference to test VTable routing
    let conn: Resource = NetworkConnection("MainServer", "192.168.1.1");
    
    // function exit will trigger ARC decrement.
}

func main() -> Int {
    run_scope_test();

    // verify if the ARC-driven teardown reached both levels of the hierarchy
    let chain_intact: Bool = SUB_DEINIT_TRIGGERED && SUPER_DEINIT_TRIGGERED;

    if chain_intact {
        print("PASS: Polymorphic deinit chain and ARC scope-bound cleanup");
    } else {
        // if one is false, either the VTable is busted or ARC missed the scope exit hook
        print("FAIL: Destructor chain broken. Sub:" + SUB_DEINIT_TRIGGERED + " Super:" + SUPER_DEINIT_TRIGGERED);
        return 1;
    }

    return 0;
}
