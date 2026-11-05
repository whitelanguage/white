// Test: GENERIC_ENVIRONMENT
// File: tests/language/modules/test_generic_environment.wl
// Focus: Nested imports and instantiation keep the defining module's names.

import "../../fixtures/modules/environment/consumer.wl" as consumer
import "../../fixtures/modules/environment/provider.wl" as provider
import "../../fixtures/modules/environment/dependency.wl" as dependency


const OFFSET: Int = 1000;
struct Item(value: String)

func main() -> Int {
    let first = provider.wrap(5);
    let second = provider.wrap("white");
    let own = Item("caller");
    let imported = provider.Item(3);
    let foreign = dependency.Box(9);
    if (provider.read(first) != 40 || provider.read(second) != 40 ||
        consumer.calculate() != 141 || own.value != "caller" ||
        imported.value != 3 || provider.read_foreign(foreign) != 9 || OFFSET != 1000) {
        return 1;
    }

    print("PASS: generic module environment");
    return 0;
}
