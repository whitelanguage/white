// Expected Error: "Function 'duplicate' is already defined."
func duplicate(value: Int) -> Int { return value; }
extern "C" { func duplicate(value: Int) -> Int; }
func main() -> Int { return 0; }
