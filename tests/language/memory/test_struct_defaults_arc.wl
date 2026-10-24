// Test: STRUCT_DEFAULTS_ARC
// File: tests/language/memory/test_struct_defaults_arc.wl
// Focus: Factory defaults own their results and struct copies retain managed fields.

let CREATED: Int = 0;
let DROPPED: Int = 0;

class Probe {
    init() { CREATED++; }
    deinit() { DROPPED++; }
}

func make_probe() -> Probe {
    return Probe();
}

struct Holder(probe: Probe = make_probe(), text: String = "hello" + " world")
struct Nested(holder: Holder = Holder())
struct Interrupted(value: Int, probe: Probe = make_probe())
struct InterruptedBody(value: Int, probe: Probe = make_probe()) {
    this.value = 0;
}

func fail() -> Int? {
    throw Error.InvalidArgument;
}

struct FailingDefaults(probe: Probe = make_probe(), value: Int = fail()?)

func check_default_failure() -> Bool {
    let outer = Probe();
    let value = FailingDefaults();
    catch(err) {
        return CREATED == DROPPED + 1;
    }
    return false;
}

func check_body_failure() -> Bool {
    let value = InterruptedBody(fail()?);
    catch(err) {
        return CREATED == DROPPED;
    }
    return false;
}

func check_failure() -> Bool {
    let value = Interrupted(fail()?);
    catch(err) {
        return CREATED == DROPPED;
    }
    return false;
}

func check_scope() -> Bool {
    let first = Holder();
    let second = first;
    let explicit = Holder(probe=Probe());
    let nested = Nested();
    return CREATED == 3 && DROPPED == 0 && second.text == "hello world" && nested.holder.text == "hello world";
}

func main() -> Int {
    if (!check_scope() || CREATED != 3 || DROPPED != 3) {
        print("FAIL: struct default ownership", CREATED, DROPPED);
        return 1;
    }
    if (!check_failure() || CREATED != 4 || DROPPED != 4) {
        print("FAIL: interrupted struct construction", CREATED, DROPPED);
        return 1;
    }
    if (!check_default_failure() || CREATED != 6 || DROPPED != 6) {
        print("FAIL: interrupted field default", CREATED, DROPPED);
        return 1;
    }
    if (!check_body_failure() || CREATED != 7 || DROPPED != 7) {
        print("FAIL: interrupted initializer body", CREATED, DROPPED);
        return 1;
    }
    print("PASS: struct default ownership");
    return 0;
}
