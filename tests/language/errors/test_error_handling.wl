// Test: ERROR_HANDLING_PROPAGATION_AND_CONTROL
// File: tests/language/errors/test_error_handling.wl
// Focus: Fallible function propagation (?), catch blocks with control flow, and complex type support.

import Error from "errors"

func may_fail(x: Int) -> Int? {
    if (x < 0) { throw Error.InvalidArgument; }
    if (x == 0) { throw Error.DivisionByZero; }
    return x * 2;
}

func deep_fail(x: Int) -> Int? {
    let res: Int = may_fail(x)?;
    return res + 1;
}

func test_loop() -> Int {
    let sum: Int = 0;
    let i: Int = -2;
    // expected behavior: i=-2,-1,0 fail, loop continues. i=1,2 succeed.
    while (i <= 2) {
        let val: Int = deep_fail(i)?;
        catch(err) {
            i += 1;
            continue; 
        }
        sum += val;
        i += 1;
    }
    return sum; // 1 -> 3, 2 -> 5. sum = 8.
}

func test_complex_type() -> Vector(Int)? {
    let v: Vector(Int) = [];
    v.append(100);
    // simulate error forcing
    throw Error.OutOfMemory; 
}

func main() -> Int {
    // validate loop control flow + error propagation
    let sum: Int = test_loop();
    let loop_ok: Bool = (sum == 8);

    // validate complex type error unwinding
    let vec_catch_hit: Bool = false;
    let my_vec: Vector(Int) = [];
    
    // attempt to handle complex return
    my_vec = test_complex_type()?;
    catch(err2) {
        vec_catch_hit = true;
    }

    let complex_ok: Bool = vec_catch_hit;
    if (loop_ok && complex_ok) {
        print("PASS: Error propagation, loop control, and complex type unwinding");
        return 0;
    } else {
        print("FAIL: Error handling logic mismatch");
        return 1;
    }
}
