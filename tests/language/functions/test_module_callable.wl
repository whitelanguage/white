// Test: MODULE_CALLABLE
// File: tests/language/functions/test_module_callable.wl
// Focus: Module function values, shadowing, and exported aggregate ABI adaptation.
import "../../fixtures/module_callable.wl" as library


class Local {
    func add(left: Int, right: Int) -> Int {
        return left - right;
    }
}

func main() -> Int {
    let add = library.add;
    let typed: Function(Int, Int) -> Int = library.add;
    if (add(20, 22) != 42 || typed(2, 3) != 5) { return 1; }

    let reverse = library.reverse;
    let pair = reverse(library.Pair(10L, 20L));
    if (pair.left != 20L || pair.right != 10L) { return 2; }

    {
        let library = Local();
        let bound = library.add;
        if (bound(10, 3) != 7) { return 3; }
    }
    print("PASS: module callable values");
    return 0;
}
