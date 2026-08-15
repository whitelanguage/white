// Test: MODULE_SYMBOL_ISOLATION
// File: tests/language/modules/test_module_isolation.wl
// Focus: Ensuring symbols with the same name in different files do not collide.
import "../../fixtures/pkgs/iso_provider_a.wl" as modA
import "../../fixtures/pkgs/iso_provider_b.wl" as modB


func main() -> Int {
    let str1: String = modA.str("A");
    let str2: String = modB.str("B");

    if (str1 == "A" && str2 == "B") {
        print("PASS: Module symbol isolation");
    } else {
        print("FAIL: Namespace collision detected");
    }
    return 0;
}
