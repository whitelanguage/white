// Test: NAMED_TYPES
// File: tests/language/types/test_named_types.wl
// Focus: Distinct named types, transparent aliases, generic inference, conversions and ownership.

import Dict from "dict"

type UserID = UInt32;
type Label = String;
type String as Text;
type Vector(Int) as IntVector;

const ROOT_ID: UserID = UserID(9U);
let DROPPED: Int = 0;

class Source {
    type UserID { return 40U; }
    type Label { return "named"; }
    type Text { return "source"; }
}

class CheckedSource {
    let valid: Bool;

    init(valid: Bool) { self.valid = valid; }

    type UserID? {
        if (!self.valid) { throw Error.InvalidArgument; }
        return 41U;
    }
}

class Probe {
    let value: Int;

    init(value: Int) { self.value = value; }
    func get() -> Int { return self.value; }
    deinit() { DROPPED += 1; }
}

type Owner = Probe;

func identity<T>(value: T) -> T { return value; }
func consume(value: Owner) -> Int { return value.get(); }

func main() -> Int {
    let id: UserID = UserID(1U);
    let next = id + UserID(1U);
    id += UserID(1U);
    id++;

    let inferred = identity(next);
    let source = Source();
    let converted: UserID = UserID(source);
    let checked: UserID = UserID(CheckedSource(true))?;
    catch(err) { return 1; }
    let named_text: Label = Label(source);
    let text: Text = Text(source);
    let label: Label = Label("white") + Label("lang");
    let values: IntVector = [1, 2, 3];

    let table: Dict(UserID, String) = Dict();
    table.put(UserID(7U), "seven");
    let stored: String = table.get(UserID(7U))?;
    catch(err) { return 1; }

    let dynamic: Dict = Dict(1);
    dynamic.put("id", id);
    let restored: UserID = dynamic["id"];

    {
        let owner = Owner(Probe(12));
        if (consume(owner) != 12) { return 1; }
    }

    if (ROOT_ID != UserID(9U) || id != UserID(3U) || inferred != UserID(2U) ||
        converted != UserID(40U) || checked != UserID(41U) || named_text != Label("named") || text != "source" ||
        label != Label("whitelang") || label.length() != 9 || label[0] != Byte('w') ||
        values[1] != 2 || stored != "seven" || restored != id || DROPPED != 1 ||
        size_of(UserID) != size_of(UInt32) || align_of(Label) != align_of(String)) {
        print("FAIL: Named types");
        return 1;
    }

    print("PASS: Named types");
    return 0;
}
