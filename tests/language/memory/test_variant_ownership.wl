// Test: VARIANT_AND_FALLIBLE_OWNERSHIP
// File: tests/language/memory/test_variant_ownership.wl
// Focus: Variant payloads, Dict slot cleanup, and fallible reference transfer.
import "dict"
import Error from "errors"


let DROPPED: Int = 0;

interface Valued {
    func get_value() -> Int;
}

class Probe with Valued {
    let value: Int = 0;

    init(value: Int) -> Void {
        self.value = value;
    }

    func get_value() -> Int {
        return self.value;
    }

    deinit() -> Void {
        DROPPED += 1;
    }
}

func make_probe(value: Int, fail: Bool) -> Probe? {
    if fail {
        throw Error.InvalidArgument;
    }
    return Probe(value);
}

func forward_probe(value: Int) -> Probe? {
    let probe: Probe = make_probe(value, false)?;
    return probe;
}

func exercise_fallible() -> Bool {
    let probe: Probe = forward_probe(7)?;
    catch(err) {
        return false;
    }
    return probe.value == 7;
}

func exercise_dict() -> Bool {
    let values: Dict = Dict(1);
    let i: Int = 0;
    while (i < 40) {
        values.put("key-" + i, Probe(i));
        i += 1;
    }

    values.put("key-1", Probe(101));
    values.remove("key-2");

    i = 0;
    while (i < 40) {
        if (i != 2) {
            let probe: Probe = values["key-" + i];
            let expected: Int = i;
            if (i == 1) { expected = 101; }
            if (probe.value != expected) { return false; }
        }
        i += 1;
    }
    return !values.contains_key("key-2");
}

func exercise_interface_variant() -> Bool {
    let values: Dict = Dict(1);
    let probe: Probe = Probe(88);
    let valued: Valued = probe;
    values.put("interface", valued);

    let loaded: Valued = values["interface"];
    return loaded.get_value() == 88;
}

func main() -> Int {
    if (!exercise_fallible() || DROPPED != 1) {
        print("FAIL: Fallible reference ownership was not transferred");
        return 1;
    }

    if (!exercise_dict() || DROPPED != 42) {
        print("FAIL: Dict or Variant ownership was not released");
        return 1;
    }

    if (!exercise_interface_variant() || DROPPED != 43) {
        print("FAIL: Interface Variant payload was corrupted");
        return 1;
    }

    print("PASS: Variant and fallible ownership");
    return 0;
}
