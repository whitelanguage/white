// Test: OMEGA_E2E
// File: tests/e2e/projects/test_e2e_omega.wl
// Focus: FFI calls, function values, containers, and recursive structures.

import "sys"

extern "system" { func GetCurrentProcessId() -> Int; }
extern "C" { func getpid() -> Int; }

struct Payload(id: Long, tag: String)
class Node {
    let val: Int;
    let data: Payload;
    let next: Node;

    init(val: Int, data: Payload, next: Node) {
        self.val = val;
        self.data = data;
        self.next = next;
    }
}
func compute_sum(a: Int, b: Int) -> Int { return a + b; }

func main() -> Int {
    // native FFI without introducing a Windows CRT dependency
    let process_id: Int = 0;
    if (sys.OS == sys.Os.Windows) { process_id = GetCurrentProcessId(); }
    else { process_id = getpid(); }

    // recursive Vector/Struct mix
    let v_test: Vector(Int) = [100, 200, 300];
    let head: Node = Node(1, Payload(10, "BASE"), null);
    head.next = Node(2, Payload(20, "SUB"), null);

    // higher-order function dispatch
    let fn_ptr: Function(Int, Int) -> Int = compute_sum;
    let calc_res: Int = fn_ptr(50, 50);

    if (process_id > 0 && calc_res == 100 && v_test.length() == 3 && head.next.val == 2) {
        print("PASS: End-to-end language features");
    } else {
        print("FAIL: End-to-end language feature result");
        return 1;
    }
    return 0;
}
