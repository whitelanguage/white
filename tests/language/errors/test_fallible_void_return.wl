// Test: FALLIBLE_VOID_IMPLICIT_SUCCESS
// File: tests/language/errors/test_fallible_void_return.wl
// Focus: Falling off the end of Void? functions and methods returns success.


func succeeds() -> Void? {
}

class Worker {
    func succeeds() -> Void? {
    }
}

func main() -> Int {
    succeeds()?;
    catch(err) {
        print("FAIL: Void? function returned an undefined error");
        return 1;
    }

    let worker: Worker = Worker();
    worker.succeeds()?;
    catch(err) {
        print("FAIL: Void? method returned an undefined error");
        return 2;
    }

    print("PASS: Void? implicit success");
    return 0;
}
