// Expected Error: "Cannot import '__native_hidden', symbol not found in module."
import __native_hidden from "../../fixtures/native_private.wl"
func main() -> Int { return 0; }
