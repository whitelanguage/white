// Test: HASHED_DICTIONARY
// File: tests/language/types/test_hash_dict.wl
// Focus: Typed dictionaries using built-in and user-defined Hash implementations.

import Dict from "dict"
import Hash from "protocol"

class Key with Hash {
    let value: Int;

    init(value: Int) {
        self.value = value;
    }

    func hash() -> Int {
        return self.value;
    }

    func equals(other: Key) -> Bool {
        return self.value == other.value;
    }
}

func main() -> Int {
    let names: Dict(String, Int) = Dict();
    names.put("white", 7);
    let number: Int = names.get("white")?;
    catch(err) {
        print("FAIL: Built-in Hash");
        return 1;
    }

    let values: Dict(Key, String) = Dict();
    values.put(Key(42), "answer");
    let answer: String = values.get(Key(42))?;
    catch(err) {
        print("FAIL: User-defined Hash");
        return 1;
    }

    if (number != 7 || answer != "answer") {
        print("FAIL: Hashed dictionary lookup");
        return 1;
    }
    print("PASS: Hashed dictionary lookup");
    return 0;
}
