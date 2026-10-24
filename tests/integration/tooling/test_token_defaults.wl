// Test: TOKEN_DEFAULTS
// File: tests/integration/tooling/test_token_defaults.wl
// Focus: Empty tokens and explicit fields overriding the declared initialization.

import Token, TOK_EOF from "../../../src/frontend/tokens.wl"


func main() -> Int {
    let empty: Token = Token();
    let named: Token = Token(value="name", line=7);
    let positional: Token = Token(42, "text", 3, 5);

    if (empty.type != TOK_EOF || empty.value != "" || empty.line != 0 || empty.col != 0) {
        print("FAIL: empty token defaults");
        return 1;
    }
    if (named.type != TOK_EOF || named.value != "name" || named.line != 7 || named.col != 0) {
        print("FAIL: explicit token fields");
        return 1;
    }
    if (positional.type != 42 || positional.value != "text" || positional.line != 3 || positional.col != 5) {
        print("FAIL: positional token fields");
        return 1;
    }

    print("PASS: token defaults");
    return 0;
}
