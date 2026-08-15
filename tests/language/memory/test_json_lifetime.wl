// Test: JSON_LIFETIME
// File: tests/language/memory/test_json_lifetime.wl
// Focus: Releasing JSON arrays, their Value elements, and encoder output across repeated construction.

import "json"

func main() -> Int {
    let round: Int = 0;
    while (round < 10) {
        let value: json.Value = json.array();
        let i: Int = 0;
        while (i < 10000) {
            value.append(json.integer(Long(i))?)?;
            catch(err) {
                print("FAIL: JSON value construction");
                return 1;
            }
            i += 1;
        }
        let encoded: String = json.encode(value)?;
        catch(err) {
            print("FAIL: JSON encoding");
            return 1;
        }
        if (encoded.length() == 0 || encoded[0] != Byte('[')) {
            print("FAIL: JSON encoder output");
            return 1;
        }
        value = null;
        encoded = null;
        round += 1;
    }
    print("PASS: JSON value lifetime");
    return 0;
}
