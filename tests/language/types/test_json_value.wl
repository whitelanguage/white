// Test: JSON_VALUE_MODEL
// File: tests/language/types/test_json_value.wl
// Focus: JSON scalar, array, object, and exact integer access.

import "json"

func main() -> Int {
    let root: json.Value = json.object();
    let name_value: json.Value = json.string("White Language")?;
    catch(err) {
        print("FAIL: JSON value construction, error " + Int(err));
        return 1;
    }
    root.set("name", name_value)?;
    catch(err) {
        print("FAIL: JSON object construction, kind " + Int(root.kind()) + ", error " + Int(err));
        return 1;
    }
    root.set("year", json.integer(2026L)?)?;
    catch(err) {
        print("FAIL: JSON number construction");
        return 1;
    }

    let values: json.Value = json.array();
    values.append(json.boolean(true))?;
    catch(err) {
        print("FAIL: JSON array construction");
        return 1;
    }
    root.set("values", values)?;
    catch(err) {
        print("FAIL: JSON object insertion");
        return 1;
    }

    let name: String = String(root.get("name")?)?;
    catch(err) {
        print("FAIL: JSON string access");
        return 1;
    }
    let year: Long = Long(root.get("year")?)?;
    catch(err) {
        print("FAIL: JSON integer access");
        return 1;
    }
    let first: Bool = Bool(root.get("values")?.at(0)?)?;
    catch(err) {
        print("FAIL: JSON array access");
        return 1;
    }
    let root_length: Int = root.length()?;
    catch(err) {
        print("FAIL: JSON object length");
        return 1;
    }

    if (name != "White Language" || year != 2026L || !first || root_length != 3) {
        print("FAIL: JSON value model");
        return 1;
    }

    print("PASS: JSON value model");
    return 0;
}
