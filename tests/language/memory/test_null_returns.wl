// Test: NULL_RETURNS
// File: tests/language/memory/test_null_returns.wl
// Focus: Preserve nullable reference returns and explicit nullptr returns.

class Box {}

func object() -> Box { return null; }
func vector() -> Vector(Int) { return null; }
func pointer() -> ptr Int { return nullptr; }

func object_result() -> Box? {
    return null;
}

func pointer_result() -> ptr Int? {
    return nullptr;
}

func main() -> Int {
    let box: Box = object();
    let values: Vector(Int) = vector();
    let ptr ptr_value: Int = pointer();
    if (box is !null || values is !null || ptr_value is !nullptr) {
        print("FAIL: nullable reference returns");
        return 1;
    }

    let result: Box = object_result()?;
    catch(err) { return 1; }
    let ptr result_ptr: Int = pointer_result()?;
    catch(err) { return 1; }
    if (result is !null || result_ptr is !nullptr) {
        print("FAIL: fallible null success values");
        return 1;
    }

    print("PASS: null and nullptr returns");
    return 0;
}
