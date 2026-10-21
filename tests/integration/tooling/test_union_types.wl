// Test: UNION_TYPES
// File: tests/integration/tooling/test_union_types.wl
// Focus: Union normalization and generic aliases resolve without changing nominal identity.

import * from "../../../src/frontend/ast.wl"
import * from "../../../src/frontend/arena.wl"
import new_lexer, get_next_token from "../../../src/frontend/lexer.wl"
import Parser, parse from "../../../src/frontend/parser.wl"
import * from "../../../src/compiler/context.wl"
import reserve_named_types, resolve_named_types from "../../../src/compiler/registration.wl"
import check_errors_and_abort from "../../../src/frontend/diagnostics.wl"

func main() -> Int {
    let text: String = "type (T | Null) as Optional<T>; type T as Identity<T>; " +
        "type (Int | String) as Mixed; type (String | Int | Int) as Reordered; " +
        "type (Mixed | Bool) as Nested; type (Bool | String | Int) as Flat; " +
        "type (Int | Int) as Single; type Number = Int; type (Number | Int) as Nominal; " +
        "type Optional(Int) as MaybeInt; type (Null | Int) as RawInt; " +
        "type Identity(Optional(Int)) as AliasInt; type (MaybeInt)? as Result;";
    let arena: AstArena = new_ast_arena();
    let lexer = new_lexer("memory.wl", text);
    let first = get_next_token(ref lexer);
    let parser: Parser = Parser(lexer=lexer, current_tok=first, nesting=0, arena=arena);
    let root: NodeID = parse(ref parser);
    let compiler: Compiler = new_compiler("", false, false, arena)?;
    catch(err) { return 1; }

    reserve_named_types(ref compiler, root);
    resolve_named_types(ref compiler, root);
    check_errors_and_abort();
    let mixed = compiler.named_types.lookup("Mixed").type_id;
    let maybe = compiler.named_types.lookup("MaybeInt").type_id;
    let nominal = compiler.named_types.lookup("Nominal").type_id;
    if (mixed != compiler.named_types.lookup("Reordered").type_id ||
        compiler.named_types.lookup("Nested").type_id != compiler.named_types.lookup("Flat").type_id ||
        compiler.named_types.lookup("Single").type_id != TYPE_INT ||
        maybe != compiler.named_types.lookup("RawInt").type_id ||
        maybe != compiler.named_types.lookup("AliasInt").type_id ||
        get_inner_fallible_type(ref compiler, compiler.named_types.lookup("Result").type_id) != maybe ||
        get_union_type(ref compiler, nominal).members.length() != 2) {
        print("FAIL: union identity or alias substitution");
        return 1;
    }

    let members: Vector(Int) = get_union_type(ref compiler, maybe).members;
    if (members.length() != 2 || members[0] != TYPE_NULL || members[1] != TYPE_INT) {
        print("FAIL: union tag order is unstable");
        return 1;
    }

    print("PASS: union type normalization and aliases");
    return 0;
}
