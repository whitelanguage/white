// Test: INFERRED_MODULE_TYPES
// File: tests/language/modules/test_inferred_types.wl
// Focus: Inferring constructors and enum members through module exports and aliases.
import "../../fixtures/modules/inference.wl" as helpers
import Choice from "../../fixtures/modules/inference.wl"
import "strings"


func main() -> Int {
    let reader = helpers.Reader();
    let pair = helpers.Pair(40);
    let choice = Choice.Second;
    let qualified = helpers.Choice.Second;
    let output = strings.Builder(16);
    output.write("ok")?;
    catch(err) { return 1; }
    let text = output.build()?;
    catch(err) { return 1; }
    if (reader.value() != 42 || pair.first + pair.second != 42 || choice != qualified || text != "ok") {
        print("FAIL: module type inference");
        return 1;
    }
    print("PASS: module type inference");
    return 0;
}
