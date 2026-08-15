// Test: LOGIC_SCOPE_STRESS
// File: tests/e2e/projects/test_logic_chaos.wl
// Focus: Deeply nested functions, symbol table shadowing, short-circuit complexity, and loop-jump traps.


func math_chaos(a: Float, b: Int) -> Float {
    let result: Float = (a ** 2.0) + (b / 2);
    if (result > 10.0) {
        let result: Int = 100; // shadowing test
        // builtin.print(result); 
    }
    return result + 1.23;
}

func fib(n: Int) -> Int {
    if (n < 2) { return n; }
    return fib(n - 1) + fib(n - 2);
}

func main() -> Int {
    // fibonacci recursion
    let f10: Int = fib(10); // 55

    // scoping and mutation
    let counter: Int = 0;
    counter += 10;
    counter *= 2;
    counter /= (5 - 3); // 10
    let post: Int = counter++; // post = 10, counter = 11

    // deep nesting loops
    let hit_target: Int = 0;
    for (i: Int = 0; i < 5; i++) {
        let j: Int = i;
        while (j > 0) {
            if (j == 2) { hit_target++; j--; continue; }
            if (i == 4) { break; }
            j--;
        }
        if (i == 4) { break; }
    }

    // implicit casts
    let mixed: Float = 10 + 5.5 * (2 ** 3); // 10 + 44.0 = 54.0

    if (f10 == 55 && post == 10 && counter == 11 && mixed == 54.0) {
        print("PASS: Control flow and scope shadowing");
    } else {
        print("FAIL: Control flow or scope result");
        return 1;
    }
    return 0;
}
