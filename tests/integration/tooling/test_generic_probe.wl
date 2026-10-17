// Test: GENERIC_PROBE
// File: tests/integration/tooling/test_generic_probe.wl
// Focus: Generic lookahead stays inside the current expression and preserves lexer state.

import Lexer, new_lexer, get_next_token from "../../../src/frontend/lexer.wl"
import Parser, may_generic_postfix from "../../../src/frontend/parser.wl"
import new_ast_arena from "../../../src/frontend/arena.wl"
import GLOBAL_ERROR_COUNT from "../../../src/frontend/diagnostics.wl"


func probe(text: String, expected: Bool) -> Bool {
    let lexer = new_lexer("probe.wl", text);
    let token = get_next_token(ref lexer);
    let parser = Parser(lexer=lexer, current_tok=token, nesting=0, arena=new_ast_arena());
    let before = parser.lexer.pos.idx;
    let errors = GLOBAL_ERROR_COUNT;
    let result = may_generic_postfix(ref parser);
    return result == expected && parser.lexer.pos.idx == before && GLOBAL_ERROR_COUNT == errors;
}

func main() -> Int {
    if (!probe("<Int>(", true) || !probe("<pkg.Type, Vector(Int)>;", true) ||
        !probe("<Function(String..., sep: String) -> Int[4]?>,", true) ||
        !probe("<ptr*2 Int, Array(ptr Byte)>]", true)) {
        print("FAIL: generic type lookahead rejected a valid type list");
        return 1;
    }
    // an unrelated string error must not be reached by speculative tokenization.
    if (!probe("< limit) { value > other; \"unterminated", false) ||
        !probe("< limit && other > value;", false) ||
        !probe("< limit; next > value;", false) ||
        !probe("< limit] > value;", false)) {
        print("FAIL: comparison lookahead escaped its expression");
        return 1;
    }
    print("PASS: bounded generic lookahead");
    return 0;
}
