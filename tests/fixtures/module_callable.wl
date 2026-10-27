// tests/fixtures/module_callable.wl
struct Pair(left: Long, right: Long)

func add(left: Int, right: Int) -> Int {
    return left + right;
}

@ExportLib
func reverse(value: Pair) -> Pair {
    return Pair(value.right, value.left);
}
