// Test: UNION_ARC
// File: tests/language/memory/test_union_arc.wl
// Focus: Copies, returns and container elements clean up only the active member.

let DROPS: Int = 0;

class Probe {
    let id: Int;

    init(id: Int) { self.id = id; }

    deinit() { DROPS++; }
}

struct Record(value: Optional(Probe), label: String)

class Owner {
    let value: Optional(Probe);
    let label: String;

    init() {
        self.value = Probe(5);
        self.label = "owner";
    }
}

func make(id: Int) -> Optional(Probe) {
    return Probe(id);
}

func make_callback() -> Function() -> Bool {
    let value: Optional(Probe) = make(6);
    func alive() -> Bool {
        return value is !null;
    }
    return alive;
}

func checked(ok: Bool) -> Optional(Probe)? {
    if (!ok) { throw Error.InvalidArgument; }
    return Probe(7);
}

func exercise() -> Bool {
    let value: Optional(Probe) = make(1);
    let copy = value;
    value = null;
    if (DROPS != 0) { return false; }

    let wide: Probe | String | Null = copy;
    copy = null;
    if (DROPS != 0 || wide is null) { return false; }
    wide = "ready";
    if (DROPS != 1) { return false; }
    wide = null;

    let record = Record(make(2), "record");
    let other = record;
    record.value = null;
    if (DROPS != 1 || other.value is null) { return false; }
    other.value = null;
    if (DROPS != 2) { return false; }

    {
        let elements: Vector(Optional(Probe)) = [];
        elements.append(Probe(3));
        elements.append(null);
        elements.append(make(4));
        elements[0] = null;
        if (DROPS != 3) { return false; }
    }
    if (DROPS != 4) { return false; }

    {
        let owner = Owner();
    }
    if (DROPS != 5) { return false; }
    {
        let callback = make_callback();
        if (!callback() || DROPS != 5) { return false; }
    }
    if (DROPS != 6) { return false; }

    let result: Optional(Probe) = null;
    result = checked(true)?;
    catch(err) { return false; }
    result = checked(false)?;
    catch(err) {
        if (result is null || DROPS != 6) { return false; }
    }
    result = null;
    if (DROPS != 7) { return false; }

    let text: Optional(String) = "";
    if (text is null) { return false; }
    text = null;
    return text is null;
}

func main() -> Int {
    if (!exercise() || DROPS != 7) {
        print("FAIL: union ARC", DROPS);
        return 1;
    }
    let values: Optional(Vector(Probe)) = [Probe(8)];
    let copy: Optional(Vector(Probe)) = values;
    values = null;
    if (DROPS != 7) { return 1; }
    copy = null;
    if (DROPS != 8) { return 1; }

    print("PASS: union ARC");
    return 0;
}
