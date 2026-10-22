// Test: OPTIONAL_DICT
// File: tests/language/types/test_optional_dict.wl
// Focus: Map literals use the concrete dictionary arm supplied by Optional.

func main() -> Int {
    let values: Optional(Dict(String, Int)) = {"answer": 42};
    if (values is null) { return 1; }
    let answer = values.get("answer")?;
    catch(err) { return 2; }
    if (answer != 42) { return 3; }
    let empty: Optional(Dict(String, Int)) = {};
    if (empty is null) { return 4; }
    if (empty.length() != 0) { return 5; }
    values = null;
    if (values is !null) { return 6; }
    print("PASS: optional dictionaries");
    return 0;
}
