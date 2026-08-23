// Test: STRUCT_VALUE_SEMANTICS
// File: tests/language/types/test_struct_values.wl
// Focus: Field-wise copies, ref aliases, generic structs, containers, and nested ARC values.

let DROPPED: Int = 0;

class Probe {
    let value: Int;

    init(value: Int) {
        self.value = value;
    }

    deinit() {
        DROPPED++;
    }
}

struct Record(value: Int, probe: Probe)
struct Box<T>(value: T)
struct Link(ptr next: Link)

func replace(ptr target: Record, probe: Probe) -> Void {
    deref target = Record(30, probe);
}

func change_copy(value: Record) -> Void {
    value.value = 40;
}

func exercise() -> Bool {
    let link: Link = Link(nullptr);
    if (link.next is !nullptr) { return false; }

    let probe: Probe = Probe(7);
    let original: Record = Record(10, probe);
    let copy: Record = original;

    copy.value = 20;
    if (original.value != 10 || copy.value != 20) { return false; }
    if (original.probe is !copy.probe) { return false; }

    replace(ref copy, probe);
    if (copy.value != 30 || original.value != 10) { return false; }

    let ptr alias: Record = ref copy;
    alias.value = 35;
    if (copy.value != 35 || original.value != 10) { return false; }

    change_copy(original);
    if (original.value != 10) { return false; }

    let boxed: Box(Record) = Box(original);
    let boxed_copy: Box(Record) = boxed;
    boxed_copy.value.value = 50;
    if (boxed.value.value != 10 || boxed_copy.value.value != 50) { return false; }

    let records: Vector(Record) = [original];
    let loaded: Record = records[0];
    loaded.value = 60;
    if (records[0].value != 10 || loaded.value != 60) { return false; }

    let values: Dict = Dict(1);
    values.put("record", original);
    let erased: Record = values["record"];
    erased.value = 70;
    return original.value == 10 && erased.value == 70;
}

func main() -> Int {
    if (!exercise() || DROPPED != 1) {
        print("FAIL: Struct value semantics");
        return 1;
    }

    print("PASS: Struct value semantics");
    return 0;
}
