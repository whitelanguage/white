// Test: DICT_STRESS
// File: tests/language/types/test_dict_stress.wl
// Focus: Dict growth, tombstone reuse, updates, and mixed-key lookup under load.

import "builtin"
import "dict"

func main() -> Int {
    let values: Dict = Dict(2);
    let i: Int = 0;

    while (i < 4096) {
        values.put(i, i);
        i++;
    }

    values.put(1, 999);
    let updated: Int = values[1];
    if (values.length() != 4096 || updated != 999) {
        print("FAIL: Dict update changed the table size");
        return 1;
    }

    i = 0;
    while (i < 4096) {
        if (i % 3 == 0) { values.remove(i); }
        i++;
    }

    i = 4096;
    while (i < 8192) {
        values.put(i, i * 2);
        i++;
    }

    if (values.length() != 6826) {
        print("FAIL: Dict lost entries while growing");
        return 1;
    }

    i = 0;
    while (i < 4096) {
        if (i % 3 == 0) {
            if (values.contains_key(i)) {
                print("FAIL: Dict retained a removed key");
                return 1;
            }
        } else if (!values.contains_key(i)) {
            print("FAIL: Dict lost an existing key");
            return 1;
        }
        i++;
    }

    i = 4096;
    while (i < 8192) {
        let loaded: Int = values[i];
        if (!values.contains_key(i) || loaded != i * 2) {
            print("FAIL: Dict lookup failed after rehash");
            return 1;
        }
        i++;
    }

    print("PASS: Dict stress");
    return 0;
}
