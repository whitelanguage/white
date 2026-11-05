// Test: GENERIC_ENVIRONMENT_ORDER
// File: tests/language/modules/test_generic_environment_order.wl
// Focus: Reversing import order does not alter generic defaults or bindings.

import "../../fixtures/modules/environment/provider.wl" as provider
import "../../fixtures/modules/environment/consumer.wl" as consumer


const OFFSET: Int = 2000;

func main() -> Int {
    let box = provider.wrap(7);
    if (provider.read(box) != 40 || consumer.calculate() != 141 || OFFSET != 2000) {
        return 1;
    }

    print("PASS: generic module import order");
    return 0;
}
