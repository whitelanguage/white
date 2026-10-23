// Test: REF_UNION
// File: tests/language/memory/test_ref_union.wl
// Focus: Plain union cleanup does not invalidate an unrelated element reference.

struct Text(value: String)

class Cell {
    let value: Int;
    init(value: Int) { self.value = value; }
    func read(increment: Int = 0) -> Int { return self.value + increment; }
}

struct Holder(cell: Optional(Cell))

func reset(ref cell: Optional(Cell)) -> Int {
    cell = null;
    return 1;
}

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let cell: Optional(Cell) = Cell(10);
    let holder = Holder(cell);
    let first = ref values[0];
    let text: Optional(String) = "one";
    let record: Optional(Text) = Text("two");
    if (text is !null && text.length() != 3) { return 1; }
    if (cell is null) { return 1; }
    first = cell.read();
    if (holder.cell is null) { return 1; }
    first = holder.cell.read(Int(0));
    if (holder.cell is null) { return 1; }
    first = holder.cell.read(reset(ref holder.cell));
    if (first != 11 || holder.cell is !null) { return 1; }
    first = 10;
    text = null;
    record = null;
    let mixed: String | Int | Null = "three";
    mixed = 4;
    mixed = null;
    if (values[0] != 10 || text is !null || record is !null || mixed is !null) { return 1; }
    print("PASS: union cleanup with element references");
    return 0;
}
