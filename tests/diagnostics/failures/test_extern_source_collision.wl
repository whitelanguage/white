// Expected Error: "Function 'duplicate' is already defined."
extern "C" { func duplicate(value: Int) -> Int; }
func duplicate(value: Int) -> Int { return value; }
func main() -> Int { return 0; }
