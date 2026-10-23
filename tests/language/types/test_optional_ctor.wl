// Test: OPTIONAL_CTOR
// File: tests/language/types/test_optional_ctor.wl
// Focus: Union context and explicit type arguments select the same concrete generic constructor.

struct Box<T>(value: T)

class Cell<T> {
    let value: T;
    init(value: T) { self.value = value; }
}

func make() -> Optional(Dict(String, Int)) {
    return Dict();
}

func read_box(value: Optional(Box(Int))) -> Int {
    if (value is null) { return 0; }
    return value.value;
}

func main() -> Int {
    let box: Optional(Box(Int)) = Box(7);
    if (box is null || box.value != 7) { return 1; }
    let cell: Optional(Cell(String)) = Cell("white");
    if (cell is null || cell.value != "white") { return 2; }
    let table: Optional(Dict(String, Int)) = Dict();
    if (table is null) { return 3; }
    table.put("one", 1);
    let one = table.get("one")?;
    catch(err) { return 3; }
    if (one != 1) { return 3; }
    let explicit: Optional(Dict(String, Int)) = Dict<String, Int>();
    if (explicit is null || explicit.length() != 0) { return 4; }
    let inferred = Box(9);
    let named = Box<String>("nine");
    if (inferred.value != 9 || named.value != "nine" || read_box(Box(11)) != 11) { return 5; }
    let returned = make();
    if (returned is null || returned.length() != 0) { return 6; }
    let dynamic: Dict = Dict(8);
    dynamic.put("answer", 42);
    let answer: Int = dynamic.get("answer")?;
    catch(err) { return 7; }
    if (answer != 42) { return 7; }
    print("PASS: optional generic constructors");
    return 0;
}
