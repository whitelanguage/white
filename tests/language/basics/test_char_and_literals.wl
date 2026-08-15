// Test: CHAR_AND_LITERALS
// File: tests/language/basics/test_char_and_literals.wl
// Focus: Constant folding (CTFE), radix literal parsing, type-safe character scalars, and string coercion.


const CONST_HEX: Int = 0x20;                // hex representation
const CONST_BIN: Int = 0b1100_1010;         // binary with underscore separators
const CONST_OCT: Int = 0o75;                // octal representation
const CONST_CALC: Auto = (0x10 + 0b11) * 2;  // compile-time mixed radix evaluation
const CONST_LONG: Long = 9223372036854775807L;

func main() -> Int {
    let ctfe_ok: Bool = (CONST_HEX == 32) && (CONST_BIN == 202) && (CONST_OCT == 61) && (CONST_CALC == 38);

    let hex_val: Int  = 0xFF;
    let bin_val: Int  = 0b1010;
    let large_val: Int  = 1_000_000;
    let long_val: Long = 123L;
    
    let runtime_int_ok: Bool = (hex_val == 255) && (bin_val == 10) && (large_val == 1000000) && (long_val == 123L);

    let char_a: Char = 'A';
    let char_b: Char = 'B';
    let char_nl: Char = '\n';

    let char_cmp_ok: Bool = (char_a == 'A') && (char_a < char_b);

    let concat_str: String = "Character token data: " + char_a;
    let string_ok: Bool = (concat_str == "Character token data: A");

    if (ctfe_ok && runtime_int_ok && char_cmp_ok && string_ok) {
        print("PASS: Character and numeric literals");
    } else {
        print("FAIL: Character or numeric literal result");
        return 1;
    }

    return 0;
}
