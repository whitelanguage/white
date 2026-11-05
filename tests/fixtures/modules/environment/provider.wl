// tests/fixtures/modules/environment/provider.wl
import "dependency.wl" as dependency
import Box as ForeignBox from "dependency.wl"


struct Item(value: Int)
const OFFSET: Int = 23;

struct Box<T>(value: T, marker: Int = dependency.OFFSET)

func wrap<T>(value: T) -> Box(T) {
    return Box(value);
}

func read<T>(value: Box(T)) -> Int {
    let item = dependency.Item(value.marker);
    return item.value + OFFSET;
}

func read_foreign<T>(value: ForeignBox(T)) -> T {
    return value.value;
}
