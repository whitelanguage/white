// Test: UNICODE_STRING
// File: tests/language/basics/test_unicode_string.wl
// Focus: UTF-8 byte indexing, scalar access, validation, and boundaries.
import Error from "errors"

func rejects_invalid_utf8(value: String) -> Bool {
    let count: Int = value.char_count()?;
    catch(err) {
        return err == Error.InvalidArgument;
    }
    return count < 0;
}

func rejects_missing_byte(value: String) -> Bool {
    let byte: Byte = value.byte_at(value.length())?;
    catch(err) {
        return err == Error.IndexOutOfBounds;
    }
    return byte == 0;
}

func main() -> Int {
    let text: String = "A中😀";
    if (text.length() != 8) {
        print("FAIL: String length is not the UTF-8 byte length");
        return 1;
    }

    let first: Byte = text[0];
    let chinese_lead: Byte = text[1];
    let emoji_lead: Byte = text[4];
    let inferred: Auto = text[0];
    let inferred_byte: Byte = inferred;
    if (first != Byte(65) ||
        chinese_lead != Byte(228) ||
        emoji_lead != Byte(240) ||
        inferred_byte != Byte(65)) {
        print("FAIL: String indexing is not byte based");
        return 1;
    }

    let count: Int = text.char_count()?;
    catch(err) {
        print("FAIL: Valid UTF-8 was rejected");
        return 1;
    }
    if (count != 3) {
        print("FAIL: Unicode scalar count");
        return 1;
    }

    let chinese: Char = text.char_at(1)?;
    catch(err) {
        print("FAIL: Chinese scalar lookup");
        return 1;
    }
    let emoji: Char = text.char_at(2)?;
    catch(err) {
        print("FAIL: Emoji scalar lookup");
        return 1;
    }
    if (Int(chinese) != 20013 || Int(emoji) != 128512) {
        print("FAIL: Unicode scalar decoding");
        return 1;
    }
    if (Int('中') != 20013 || Int('😀') != 128512) {
        print("FAIL: Unicode character literals");
        return 1;
    }
    let joined: String = "char=" + '中' + " emoji=" + '😀';
    if (joined != "char=中 emoji=😀") {
        print("FAIL: Unicode Char to String encoding");
        return 1;
    }

    if (!text.is_valid_utf8() ||
        !text.is_char_boundary(0) ||
        !text.is_char_boundary(1) ||
        text.is_char_boundary(2) ||
        !text.is_char_boundary(4) ||
        text.is_char_boundary(5) ||
        !text.is_char_boundary(8)) {
        print("FAIL: UTF-8 boundary detection");
        return 1;
    }

    let invalid: String = "中".slice(0, 1);
    if (invalid.is_valid_utf8() || !rejects_invalid_utf8(invalid)) {
        print("FAIL: Invalid UTF-8 detection");
        return 1;
    }

    if (!rejects_missing_byte(text)) {
        print("FAIL: Byte bounds error");
        return 1;
    }

    print("PASS: Unicode String primitives");
    return 0;
}
