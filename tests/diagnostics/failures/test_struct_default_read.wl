// Test: STRUCT_DEFAULT_READ
// File: tests/diagnostics/failures/test_struct_default_read.wl
// Focus: An initializer body cannot read a field which has not been assigned yet.
// Expected Error: "MissingInitializer: Field 'first' is read before it is initialized."

struct Count(first: Int, second: Int) {
    this.second = this.first;
}

func main() -> Int {
    let count = Count(1, 2);
    return 0;
}
