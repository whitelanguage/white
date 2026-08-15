// Test: RC_CONTROL_FLOW_JUMPS
// File: tests/language/memory/test_rc_control_flow.wl
// Focus: Reference counting consistency during non-local jumps (break, continue, return).


func fail_func() -> Int? {
    throw Error.InvalidArgument;
}

func test_loop_break() -> Void {
    let i: Int = 0;
    while (i < 5) {
        // temp_str should be released on every iteration
        let temp_str: String = "Loop " + i; 
        if (i == 2) {
            break; // should release temp_str and exit
        }
        i += 1;
    }
}

func test_loop_continue() -> Void {
    let i: Int = 0;
    while (i < 5) {
        let temp_str: String = "Loop " + i;
        i += 1;
        if (i == 2) {
            continue; // should release temp_str and jump to loop start
        }
    }
}

func test_local_throw() -> Void {
    // fail_func returns Error, trigger propagation catch
    let val: Int = fail_func()?;
    catch(err) {
        let temp_str: String = "Inside Try";
        return; // should release temp_str and exit function
    }
}

func main() -> Int {
    // running these functions validates that the stack unwinding 
    // and RC decrement logic are triggered correctly at jump sites.
    test_loop_break();
    test_loop_continue();
    test_local_throw();
    
    // if the program reaches here without a segmentation fault 
    // (caused by double-free) or memory exhaustion (caused by leak), PASS.
    print("PASS: RC control flow jumps compiled and ran successfully.");
    return 0;
}
