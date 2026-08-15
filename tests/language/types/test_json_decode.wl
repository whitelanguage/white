// Test: JSON_STRICT_DECODER
// File: tests/language/types/test_json_decode.wl
// Focus: Strict grammar, Unicode escapes, number preservation, and error domains.

import "json"

func rejects(source: String, expected: json.JsonError) -> Bool {
    let value: json.Value = json.decode(source)?;
    catch(err) {
        return err == expected;
    }
    return value is null;
}

func rejects_long(source: String, expected: json.JsonError) -> Bool {
    let value: json.Value = json.decode(source)?;
    catch(err) { return false; }
    let number: Long = value.as_long()?;
    catch(err) {
        return err == expected;
    }
    return number == 0L;
}

func rejects_limit(source: String, limit: Int, expected: json.JsonError) -> Bool {
    let decoder: json.Decoder = json.Decoder(source);
    decoder.set_max_depth(limit);
    let value: json.Value = decoder.decode()?;
    catch(err) {
        return err == expected;
    }
    return value is null;
}

func main() -> Int {
    let source: String =
        " {\"name\":\"White \\u4E2D\\uD83D\\uDE00\"," +
        "\"enabled\":true,\"count\":-9223372036854775808," +
        "\"ratio\":1.25e2,\"items\":[null,false,\"line\\nfeed\"]," +
        "\"duplicate\":1,\"duplicate\":2} ";

    let root: json.Value = json.decode(source)?;
    catch(err) {
        print("FAIL: valid JSON rejected, error " + Int(err));
        return 1;
    }
    let name: String = root.get("name")?.as_string()?;
    catch(err) { return 2; }
    let count: Long = root.get("count")?.as_long()?;
    catch(err) { return 3; }
    let ratio_source: String = root.get("ratio")?.as_number_text()?;
    catch(err) { return 4; }
    let newline_text: String = root.get("items")?.at(2)?.as_string()?;
    catch(err) { return 5; }
    let duplicate: Long = root.get("duplicate")?.as_long()?;
    catch(err) { return 6; }

    if (name != "White 中😀" ||
        count != (-9223372036854775807L - 1L) ||
        ratio_source != "1.25e2" ||
        newline_text != "line\nfeed" ||
        duplicate != 2L) {
        print("FAIL: decoded JSON value mismatch");
        return 7;
    }

    if (!rejects("", json.JsonError.UnexpectedEnd) ||
        !rejects("01", json.JsonError.InvalidNumber) ||
        !rejects("1.", json.JsonError.InvalidNumber) ||
        !rejects("1e", json.JsonError.InvalidNumber) ||
        !rejects("-", json.JsonError.UnexpectedEnd) ||
        !rejects("--1", json.JsonError.InvalidNumber) ||
        !rejects("tru", json.JsonError.UnexpectedEnd) ||
        !rejects("nulx", json.JsonError.UnexpectedToken) ||
        !rejects("\"\\x\"", json.JsonError.InvalidEscape) ||
        !rejects("\"line\nbreak\"", json.JsonError.InvalidControlCharacter) ||
        !rejects("\"\\u12xz\"", json.JsonError.InvalidUnicodeEscape) ||
        !rejects("\"\\uD800\"", json.JsonError.InvalidUnicodeEscape) ||
        !rejects("\"\\uDC00\"", json.JsonError.InvalidUnicodeEscape) ||
        !rejects("\"\\uD800\\u0041\"", json.JsonError.InvalidUnicodeEscape) ||
        !rejects("[1,]", json.JsonError.UnexpectedToken) ||
        !rejects("[1 2]", json.JsonError.UnexpectedToken) ||
        !rejects("{1:2}", json.JsonError.UnexpectedToken) ||
        !rejects("{\"a\" 1}", json.JsonError.UnexpectedToken) ||
        !rejects("{\"a\":1,}", json.JsonError.UnexpectedToken) ||
        !rejects("true false", json.JsonError.TrailingData) ||
        !rejects_long("1e2", json.JsonError.NumberNotInteger) ||
        !rejects_long("9223372036854775808", json.JsonError.NumberOutOfRange) ||
        !rejects_long("-9223372036854775809", json.JsonError.NumberOutOfRange) ||
        !rejects_limit("[]", 0, json.JsonError.InvalidOption) ||
        !rejects_limit("[]", 1025, json.JsonError.InvalidOption)) {
        print("FAIL: malformed JSON accepted");
        return 8;
    }

    let invalid_utf8: String = "中"[0:1];
    if (!rejects(invalid_utf8, json.JsonError.InvalidUtf8)) {
        print("FAIL: invalid UTF-8 accepted");
        return 9;
    }

    let decoder: json.Decoder = json.Decoder("[[0]]");
    decoder.set_max_depth(1);
    let too_deep: json.Value = decoder.decode()?;
    catch(err) {
        if (err == json.JsonError.NestingTooDeep &&
            decoder.offset() >= 0 &&
            decoder.line() == 1) {
            print("PASS: strict JSON decoder");
            return 0;
        }
        print("FAIL: wrong nesting diagnostic");
        return 10;
    }

    print("FAIL: nesting limit ignored");
    return 11;
}
