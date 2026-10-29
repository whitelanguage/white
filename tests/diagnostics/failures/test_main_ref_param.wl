// Expected Error: "function 'main' must be 'func main() -> Int' or 'func main(argc: Int, ptr argv: String) -> Int'"
// File: tests/diagnostics/failures/test_main_ref_param.wl
func main(ref argc: Int, ptr argv: String) -> Int {
    return argc;
}
