// Test: STD_LIBRARY_IMPORT
// File: tests/language/modules/test_std_import.wl
// Focus: Resolving built-in standard library paths and namespace availability.
import "builtin/print"
import "builtin/print" as console


func main() -> Int {
    console.print("module", "alias", sep="-", end="\n");
    print.print("\nPASS: Standard library module resolution");
    
    return 0;
}
