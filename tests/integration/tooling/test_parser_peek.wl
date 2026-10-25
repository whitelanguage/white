// Test: PARSER_PEEK
// File: tests/integration/tooling/test_parser_peek.wl
// Focus: Lookahead preserves the lexer cursor and does not duplicate comments.
import Lexer, new_lexer_trivia, get_next_token from "../../../src/frontend/lexer.wl"
import Parser, peek_type, parser_advance from "../../../src/frontend/parser.wl"
import new_ast_arena from "../../../src/frontend/arena.wl"
import TOK_ASSIGN from "../../../src/frontend/tokens.wl"


func main() -> Int {
    let lexer: Lexer = new_lexer_trivia("memory.wl", "key /* once */ = 1");
    let token = get_next_token(ref lexer);
    let parser: Parser = Parser(lexer=lexer, current_tok=token, nesting=0, arena=new_ast_arena());
    let offset: Int = parser.lexer.pos.idx;

    if (peek_type(ref parser) != TOK_ASSIGN || peek_type(ref parser) != TOK_ASSIGN ||
        parser.lexer.pos.idx != offset || parser.lexer.trivia.length() != 0) {
        print("FAIL: parser lookahead changed lexer state");
        return 1;
    }

    parser_advance(ref parser);
    if (parser.current_tok.type != TOK_ASSIGN || parser.lexer.trivia.length() != 1) {
        print("FAIL: comment recorded more than once");
        return 1;
    }

    print("PASS: parser lookahead");
    return 0;
}
