// Test: NULL_RETURNS
// File: tests/language/memory/test_null_returns.wl
// Focus: Optional success values and explicit nullptr returns remain distinct from errors.

class Box {}

func object() -> Optional(Box) { return null; }
func vector() -> Optional(Vector(Int)) { return null; }
func pointer() -> ptr Int { return nullptr; }

func object_result() -> Optional(Box)? {
    return null;
}

func pointer_result() -> ptr Int? {
    return nullptr;
}

func main() -> Int {
    let box: Optional(Box) = object();
    let values: Optional(Vector(Int)) = vector();
    let ptr ptr_value: Int = pointer();
    if (box is !null || values is !null || ptr_value is !nullptr) {
        print("FAIL: nullable reference returns");
        return 1;
    }

    let result: Optional(Box) = object_result()?;
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
