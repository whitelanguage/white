// Test: GENERIC_TYPES
// File: tests/language/types/test_generic_types.wl
// Focus: Monomorphized structs, nested type inference, recursion, and ARC cleanup.

import "builtin"

let DROPPED -> Int = 0;

class Probe {
    let value -> Int = 0;

    init(value -> Int) {
        self.value = value;
    }

    deinit() {
        DROPPED++;
    }
}

struct Box<T>(value -> T)
struct Pair<T, K>(first -> T, second -> K)

class Cell<T> {
    let value -> T;

    init(value -> T) {
        self.value = value;
    }

    method get() -> T {
        return self.value;
    }
}

func first<T>(values -> Vector(T)) -> T {
    return values[0];
}

func unwrap<T>(box -> Box(T)) -> T {
    return box.value;
}

func factorial<T>(value -> T) -> T {
    if (value <= 1) { return 1; }
    return value * factorial(value - 1);
}

func drop_box() -> Void {
    let box -> Box(Probe) = Box(Probe(8));
}

func main() -> Int {
    let boxes -> Vector(Box(Int)) = [Box(11), Box(19)];
    let value -> Int = unwrap(first(boxes));
    let pair -> Auto = Pair(7, "seven");
    let named_pair -> Auto = Pair(second="right", first=9);
    let explicit -> Auto = Box<String>("white");
    let number_cell -> Auto = Cell(23);
    let text_cell -> Cell(String) = Cell("language");
    drop_box();

    if (value != 11 || pair.first != 7 || pair.second != "seven" || named_pair.first != 9 || named_pair.second != "right" || explicit.value != "white" || number_cell.get() != 23 || text_cell.get() != "language" || factorial<Int>(6) != 720 || DROPPED != 1) {
        print("FAIL: Generic types");
        return 1;
    }
    print("PASS: Generic types");
    return 0;
}
