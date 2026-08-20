// Test: AST_ARENA
// File: tests/integration/tooling/test_ast_arena.wl
// Focus: Typed AST handles preserve node kinds and child relationships.

import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import Lexer, new_lexer, get_next_token from "../../../src/frontend/lexer.wl"
import Parser, parse from "../../../src/frontend/parser.wl"

func main() -> Int {
    let arena: AstArena = new_ast_arena();
    let lexer: Lexer = new_lexer("memory.wl", "func main() -> Int { let same = 1 is 1; return 0; }");
    let parser: Parser = Parser(lexer=lexer, current_tok=get_next_token(lexer), nesting=0, arena=arena);
    let root: NodeID = parse(parser);

    if (node_tag(root) != NODE_BLOCK) {
        print("FAIL: Parser did not return a block handle");
        return 1;
    }

    let module: BlockNode = get_block_node(arena, root);
    if (module.stmts.length() != 1 || node_tag(module.stmts[0]) != NODE_FUNC_DEF) {
        print("FAIL: Function handle was not stored in the module block");
        return 1;
    }

    let function_node: FunctionDefNode = get_func_def_node(arena, module.stmts[0]);
    let body: BlockNode = get_block_node(arena, function_node.body);
    if (body.stmts.length() != 2 || node_tag(body.stmts[0]) != NODE_VAR_DECL) {
        print("FAIL: Function body lost its statement handles");
        return 1;
    }

    let declaration: VarDeclareNode = get_var_decl_node(arena, body.stmts[0]);
    if (node_tag(declaration.value) != NODE_IS) {
        print("FAIL: Shared binary payload lost the original node kind");
        return 1;
    }

    let comparison: BinOpNode = get_binop_node(arena, declaration.value);
    if (comparison.type != NODE_IS || node_tag(comparison.left) != NODE_INT || node_tag(comparison.right) != NODE_INT) {
        print("FAIL: Binary expression children were not stored correctly");
        return 1;
    }

    print("PASS: typed AST arena");
    return 0;
}
