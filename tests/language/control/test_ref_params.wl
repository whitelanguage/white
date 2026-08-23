// Test: REFERENCE_PARAMETERS
// File: tests/language/control/test_ref_params.wl
// Focus: Explicit reference parameters across functions, methods, interfaces, constructors, closures, and generics.

struct Pair(left: Int, right: Int)

class Cell {
    let value: Int;

    init(value: Int) {
        self.value = value;
    }

    func get() -> Int {
        return self.value;
    }
}

interface PairWriter {
    func write(ref value: Pair) -> Void;
}

class Writer with PairWriter {
    init(ref value: Pair) {
        value.left++;
    }

    func write(ref value: Pair) -> Void {
        value.right++;
    }

    func replace(ref target: Cell, replacement: Cell) -> Void {
        target = replacement;
    }
}

func swap<T>(ref left: T, ref right: T) -> Void {
    let temporary: T = left;
    left = right;
    right = temporary;
}

func increment(ref value: Pair) -> Void {
    value.left++;
}

func one() -> Int {
    return 1;
}

func two() -> Int {
    return 2;
}

func replace_function(ref target: Function() -> Int, replacement: Function() -> Int) -> Void {
    target = replacement;
}

func replace_method(ref target: Method() -> Int, replacement: Method() -> Int) -> Void {
    target = replacement;
}

func replace_interface(ref target: PairWriter, replacement: PairWriter) -> Void {
    target = replacement;
}

func replace_array(ref target: Int[2]) -> Void {
    target[0] = 7;
    target[1] = 8;
}

func main() -> Int {
    let pair: Pair = Pair(1, 2);
    let writer: Writer = Writer(ref pair);
    let interface_writer: PairWriter = writer;
    let function_value: Function(ref Pair) -> Void = increment;
    let method_value: Method(ref Pair) -> Void = writer.write;

    function_value(ref pair);
    method_value(ref pair);
    interface_writer.write(ref pair);

    let first: Int = 10;
    let second: Int = 20;
    swap(ref first, ref second);

    let cell: Cell = Cell(1);
    let replacement: Cell = Cell(9);
    writer.replace(ref cell, replacement);

    let function: Function() -> Int = one;
    replace_function(ref function, two);

    let original_cell: Cell = Cell(3);
    let selected_method: Method() -> Int = original_cell.get;
    let replacement_method: Method() -> Int = replacement.get;
    replace_method(ref selected_method, replacement_method);

    let other_pair: Pair = Pair(0, 0);
    let other_writer: Writer = Writer(ref other_pair);
    let selected_writer: PairWriter = interface_writer;
    replace_interface(ref selected_writer, other_writer);
    selected_writer.write(ref other_pair);

    let first_text: String = "first";
    let second_text: String = "second";
    swap(ref first_text, ref second_text);

    let first_values: Vector(Int) = [1];
    let second_values: Vector(Int) = [2];
    swap(ref first_values, ref second_values);

    let array: Int[2] = [1, 2];
    replace_array(ref array);

    func local(ref value: Pair) -> Void {
        value.left++;
    }
    local(ref pair);

    if (pair.left != 4 || pair.right != 4 || first != 20 || second != 10 || cell.value != 9 ||
        function() != 2 || selected_method() != 9 || other_pair.left != 1 || other_pair.right != 1 ||
        first_text != "second" || second_text != "first" || first_values[0] != 2 || second_values[0] != 1 ||
        array[0] != 7 || array[1] != 8) {
        print("FAIL: Reference parameters");
        return 1;
    }

    print("PASS: Reference parameters");
    return 0;
}
