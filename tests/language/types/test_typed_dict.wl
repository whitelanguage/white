// Test: TYPED_DICT
// File: tests/language/types/test_typed_dict.wl
// Focus: Monomorphized dictionaries, typed literals, resizing, and ARC cleanup.

import "builtin"
import Dict from "dict"
import Error as DictError from "dict"
import Hash, Eq from "hash"

let DROPPED: Int = 0;

class DictProbe {
    let value: Int;

    init(value: Int) {
        self.value = value;
    }

    deinit() {
        DROPPED++;
    }
}

class DictKey with Hash, Eq(DictKey) {
    let value: Int;

    init(value: Int) {
        self.value = value;
    }

    func hash() -> Int {
        return self.value;
    }

    func equals(other: DictKey) -> Bool {
        return self.value == other.value;
    }
}

func main() -> Int {
    let words: Dict(Int, String) = Dict();
    let i: Int = 0;
    while (i < 200) { words.put(i, "value-" + i); i++; }

    let selected: String = words.get(117)?;
    catch(err) { print("FAIL: Typed Dict lookup"); return 1; }
    if (selected != "value-117" || !words.remove(117) || words.contains_key(117)) { print("FAIL: Typed Dict resize or remove"); return 1; }

    let literal: Dict(String, Int) = { "one": 1, "two": 2, "three": 3 };
    let two: Auto = literal["two"]?;
    catch(err) { print("FAIL: Typed Dict literal"); return 1; }
    if (two != 2 || literal.length() != 3) { print("FAIL: Typed Dict literal"); return 1; }
    let missing: Int = literal["missing"]?;
    catch(err) {
        if (err != DictError.KeyNotFound) { print("FAIL: Typed Dict error"); return 1; }
    }

    let first_key: DictKey = DictKey(1);
    let other_key: DictKey = DictKey(1);
    let identities: Dict(DictKey, String) = Dict();
    identities.put(first_key, "first");
    let identity: String = identities.get(other_key)?;
    catch(err) { print("FAIL: Typed Dict class key"); return 1; }
    if (identity != "first" || !identities.contains_key(other_key)) { print("FAIL: Typed Dict class key"); return 1; }

    let probes: Dict(String, DictProbe) = Dict();
    probes.put("value", DictProbe(1));
    probes.put("value", DictProbe(2));
    if (DROPPED != 1 || !probes.remove("value") || DROPPED != 2) { print("FAIL: Typed Dict ownership"); return 1; }
    probes.put("value", DictProbe(3));
    let loaded: DictProbe = probes.get("value")?;
    catch(err) { print("FAIL: Typed Dict class value"); return 1; }
    probes.clear();
    if (DROPPED != 2 || loaded.value != 3) { print("FAIL: Typed Dict class value"); return 1; }
    loaded = null;
    if (DROPPED != 3) { print("FAIL: Typed Dict cleanup"); return 1; }

    print("PASS: Typed Dict");
    return 0;
}
