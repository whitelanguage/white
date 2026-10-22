// Test: DICT_GET
// File: tests/language/types/test_dict_get.wl
// Focus: Missing keys fail without confusing stored zero, empty or null values, including owned results.

import Dict from "dict"
import Error as DictError from "dict"


let DROPPED: Int = 0;

class Item {
    let value: Int;

    init(value: Int) {
        self.value = value;
    }

    deinit() {
        DROPPED++;
    }
}

func check_owned() -> Int {
    let values: Dict(Int, Item) = Dict();
    let fallback = Item(99);
    values.put(1, Item(7));
    let found: Item = fallback;
    found = values.get(1)?;
    catch(err) { return 1; }
    let missing: Item = fallback;
    missing = values.get(2)?;
    catch(err) {
        if (err != DictError.KeyNotFound) { return 1; }
        missing = fallback;
    }
    values.clear();

    if (found.value != 7 || missing.value != 99 || DROPPED != 0) { return 1; }
    return 0;
}

func main() -> Int {
    let numbers: Dict(Int, Int) = Dict();
    let number: Int = 0;
    number = numbers.get(1)?;
    catch(err) {
        if (err != DictError.KeyNotFound) { return 1; }
        number = 42;
    }
    if (number != 42) { return 1; }
    numbers.put(1, 0);
    number = numbers[1]?;
    catch(err) { return 2; }
    if (number != 0) { return 2; }

    let flags: Dict(Int, Bool) = Dict();
    flags.put(1, false);
    let flag: Bool = flags.get(1)?;
    catch(err) { return 3; }
    let missing_flag: Bool = false;
    missing_flag = flags.get(2)?;
    catch(err) { missing_flag = true; }
    if (flag || !missing_flag) { return 3; }

    let texts: Dict(Int, String) = Dict();
    texts.put(1, "");
    let text: String = texts.get(1)?;
    catch(err) { return 4; }
    let missing_text: String = "";
    missing_text = texts.get(2)?;
    catch(err) { missing_text = "fallback"; }
    if (text != "" || missing_text != "fallback") { return 4; }

    let optional: Dict(Int, Optional(String)) = Dict();
    optional.put(1, null);
    optional.put(2, "");
    let stored: Optional(String) = optional.get(1)?;
    catch(err) { return 5; }
    if (stored is !null) { return 5; }
    let missing: Optional(String) = null;
    missing = optional.get(3)?;
    catch(err) { missing = "fallback"; }
    if (missing is null || missing != "fallback") { return 5; }
    let empty: Optional(String) = optional.get(2)?;
    catch(err) { return 6; }
    if (empty is null || empty != "") { return 6; }

    if (check_owned() != 0 || DROPPED != 2) { return 7; }
    let dynamic: Dict = { "null": null, "zero": 0, "empty": "", "false": false };
    let stored_null: String = dynamic.get("null")?;
    catch(err) { return 8; }
    if (stored_null is !null) { return 8; }
    let zero: Int = dynamic["zero"]?;
    catch(err) { return 9; }
    let blank: String = dynamic["empty"]?;
    catch(err) { return 9; }
    let off: Bool = dynamic["false"]?;
    catch(err) { return 9; }
    if (zero != 0 || blank != "" || off) { return 9; }

    let absent: Bool = false;
    let erased: Variant = null;
    erased = dynamic["missing"]?;
    catch(err) {
        if (err != DictError.KeyNotFound) { return 10; }
        absent = true;
    }
    if (!absent) { return 10; }
    dynamic.remove("zero");
    absent = false;
    erased = dynamic.get("zero")?;
    catch(err) {
        if (err != DictError.KeyNotFound) { return 11; }
        absent = true;
    }
    if (!absent) { return 11; }

    print("PASS: Dict get");
    return 0;
}
