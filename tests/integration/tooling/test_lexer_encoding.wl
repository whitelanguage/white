// Test: LEXER_SOURCE_ENCODING
// File: tests/integration/tooling/test_lexer_encoding.wl
// Focus: Rejecting malformed UTF-8 and embedded NUL bytes in every lexical context.

import "../../../src/core/WhitelangExceptions.wl"
import Lexer, new_lexer, get_next_token from "../../../src/core/WhitelangLexer.wl"
import TOK_EOF from "../../../src/core/WhitelangTokens.wl"

func rejects(text: String) -> Bool {
    WhitelangExceptions.begin_error_collection();
    let lexer: Lexer = new_lexer("memory.wl", text);
    let done: Bool = false;
    while (!done) {
        let token: Struct = get_next_token(lexer);
        if (token is !null && token.type == TOK_EOF) { done = true; }
    }
    let rejected: Bool = WhitelangExceptions.GLOBAL_ERROR_COUNT > 0;
    WhitelangExceptions.end_error_collection();
    WhitelangExceptions.reset_errors();
    return rejected;
}

func main() -> Int {
    let invalid: String = "中"[0:1];
    let nul: String = "" + '\0';
    if (!rejects("func " + invalid + "() -> Int { return 0; }") || !rejects("func main() -> Int { let s: String = \"" + invalid + "\"; return 0; }") || !rejects("func main() -> Int { let c: Char = '" + invalid + "'; return 0; }") || !rejects("// " + invalid + "\nfunc main() -> Int { return 0; }") || !rejects("/* " + invalid + " */ func main() -> Int { return 0; }") || !rejects("func main() -> Int { return 0; }" + nul + "ignored")) {
        print("FAIL: invalid source encoding was accepted");
        return 1;
    }
    print("PASS: lexer source encoding");
    return 0;
}
