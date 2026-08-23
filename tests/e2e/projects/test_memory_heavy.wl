// Test: MEMORY_POINTER_STRESS
// File: tests/e2e/projects/test_memory_heavy.wl
// Focus: Recursive class linking, nested value layouts, and raw pointer memory mutation.


class Node {
    let id: Int;
    let data: Int;
    let next: Node;

    init(id: Int, data: Int, next: Node) {
        self.id = id;
        self.data = data;
        self.next = next;
    }
}
struct Point(x: Int, y: Int)
struct Rect(top_left: Point, width: Int, height: Int)

func build_chain(count: Int) -> Node {
    let head: Node = Node(0, 0, null);
    let curr: Node = head;
    let i: Int = 1;
    while (i < count) {
        curr.next = Node(i, i * 10, null);
        curr = curr.next;
        i++;
    }
    return head;
}

func main() -> Int {
    // linked list stress
    let list: Node = build_chain(10);
    let tail_val: Int = list.next.next.data; // 20

    // nested struct offsets
    let r: Rect = Rect(Point(10, 20), 100, 200);
    let nested_y: Int = r.top_left.y; // 20
    
    // pointer dereference mutation
    let target: Int = 1;
    let ptr p: Int = ref target;
    deref p = 99999;

    if (tail_val == 20 && nested_y == 20 && target == 99999) {
        print("PASS: Memory layout and pointer mutation");
    } else {
        print("FAIL: Memory layout or pointer mutation");
        return 1;
    }
    return 0;
}
