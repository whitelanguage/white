// Expected Error: "Compiler intrinsic 'print' cannot be used as a function value."
// File: tests/diagnostics/failures/test_module_intrinsic_value.wl
import "builtin/print"


func main() -> Int {
    let output = print.print;
    return 0;
}
