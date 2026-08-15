// Test: STRING_BUILDER
// File: tests/language/basics/test_string_builder.wl
// Focus: Geometric growth, UTF-8 writes, numeric formatting, reset, and storage transfer.

import "strings"

func rejects_invalid_utf8() -> Bool {
    let output: strings.Builder = strings.Builder(1);
    output.write_byte(Byte(255))?;
    catch(err) { return false; }
    let result: String = output.build()?;
    catch(err) { return err == strings.StringError.InvalidUtf8; }
    return result is null;
}

func write_first(output: strings.Builder) -> String? {
    let minimum_int: Int = -2147483647;
    minimum_int -= 1;
    let minimum_long: Long = -9223372036854775807L;
    minimum_long -= 1L;
    output.write("White ")?;
    output.write_char('语')?;
    output.write_byte(Byte(32))?;
    output.write_int(minimum_int)?;
    output.write_byte(Byte(32))?;
    output.write_long(minimum_long)?;
    output.write_byte(Byte(32))?;
    output.write_uint(18446744073709551615UL)?;
    return output.build()?;
}

func write_second(output: strings.Builder) -> String? {
    output.write("next")?;
    return output.build()?;
}

func exercises_growth() -> Bool? {
    let output: strings.Builder = strings.Builder(0);
    output.reserve(1024)?;
    let reserved: Int = output.capacity();
    output.write("discard")?;
    output.clear();

    let i: Int = 0;
    while (i < 10000) {
        output.write("item-")?;
        output.write_int(i)?;
        i += 1;
    }
    let result: String = output.build()?;
    return reserved >= 1024 && result.starts_with("item-0") && result.ends_with("item-9999") && result.is_valid_utf8() && output.is_empty() && output.capacity() == 0;
}

func main() -> Int {
    let output: strings.Builder = strings.Builder(1);
    let first: String = write_first(output)?;
    catch(err) {
        print("FAIL: String builder rejected valid input");
        return 1;
    }

    let second: String = write_second(output)?;
    catch(err) {
        print("FAIL: String builder could not be reused");
        return 1;
    }

    let growth_ok: Bool = exercises_growth()?;
    catch(err) {
        print("FAIL: String builder could not grow");
        return 1;
    }

    if (first != "White 语 -2147483648 -9223372036854775808 18446744073709551615" || second != "next" || !rejects_invalid_utf8() || !growth_ok) {
        print("FAIL: String builder state or output was corrupted");
        return 1;
    }

    print("PASS: String builder");
    return 0;
}
