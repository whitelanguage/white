// Test: JSON_ENCODER_AND_ROUND_TRIP
// File: tests/language/types/test_json_encode.wl
// Focus: Stable object order, escaping, exact number text, pretty output, and limits.

import "json"

func rejects_indent(value: json.Value) -> Bool {
    let encoder: json.Encoder = json.Encoder();
    encoder.set_indent(17);
    let output: String = encoder.encode(value)?;
    catch(err) {
        return err == json.JsonError.InvalidIndent;
    }
    return output is null;
}

func rejects_depth(value: json.Value) -> Bool {
    let encoder: json.Encoder = json.Encoder();
    encoder.set_max_depth(1);
    let output: String = encoder.encode(value)?;
    catch(err) {
        return err == json.JsonError.NestingTooDeep;
    }
    return output is null;
}

func main() -> Int {
    let source: String =
        "{\"name\":\"White 中😀\",\"control\":\"quote: \\\" slash: \\\\ " +
        "line:\\n nul:\\u0000\",\"number\":1.2300e+4," +
        "\"items\":[true,null,\"x\"]}";

    let root: json.Value = json.decode(source)?;
    catch(err) {
        print("FAIL: encoder fixture did not parse");
        return 1;
    }
    let compact: String = json.encode(root)?;
    catch(err) {
        print("FAIL: compact JSON encoding");
        return 2;
    }
    if (compact != source) {
        print("FAIL: compact JSON was not stable");
        return 3;
    }

    let encoder: json.Encoder = json.Encoder();
    encoder.set_indent(2);
    let pretty: String = encoder.encode(root)?;
    catch(err) {
        print("FAIL: pretty JSON encoding");
        return 4;
    }
    let expected_pretty: String =
        "{\n" +
        "  \"name\": \"White 中😀\",\n" +
        "  \"control\": \"quote: \\\" slash: \\\\ line:\\n nul:\\u0000\",\n" +
        "  \"number\": 1.2300e+4,\n" +
        "  \"items\": [\n" +
        "    true,\n" +
        "    null,\n" +
        "    \"x\"\n" +
        "  ]\n" +
        "}";
    if (pretty != expected_pretty) {
        print("FAIL: pretty JSON layout");
        return 5;
    }

    let round_trip: json.Value = json.decode(compact)?;
    catch(err) {
        print("FAIL: encoded JSON could not be parsed");
        return 6;
    }
    let number_source: String = round_trip.get("number")?.as_number_text()?;
    catch(err) { return 7; }
    let control: String = round_trip.get("control")?.as_string()?;
    catch(err) { return 8; }
    if (number_source != "1.2300e+4" ||
        control.length() != 30 ||
        control[control.length() - 1] != Byte(0)) {
        print("FAIL: JSON round-trip changed a value");
        return 9;
    }

    let nested: json.Value = json.array();
    nested.append(json.array())?;
    catch(err) { return 10; }
    if (!rejects_indent(root) || !rejects_depth(nested)) {
        print("FAIL: encoder limits");
        return 11;
    }

    print("PASS: JSON encoder and round-trip");
    return 0;
}
