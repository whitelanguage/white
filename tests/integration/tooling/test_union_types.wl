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

func alias_id(ref compiler: Compiler, name: String) -> Int {
    let info = compiler.named_types.get(name)?;
    catch(err) { print("FAIL: missing alias", name); return 0; }
    return info.type_id;
}

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
    let mixed = alias_id(ref compiler, "Mixed");
    let maybe = alias_id(ref compiler, "MaybeInt");
    let nominal = alias_id(ref compiler, "Nominal");
    let nominal_info = get_union_type(ref compiler, nominal);
    if (nominal_info is null) {
        print("FAIL: nominal union metadata missing");
        return 1;
    }
    if (mixed != alias_id(ref compiler, "Reordered") ||
        alias_id(ref compiler, "Nested") != alias_id(ref compiler, "Flat") ||
        alias_id(ref compiler, "Single") != TYPE_INT ||
        maybe != alias_id(ref compiler, "RawInt") ||
        maybe != alias_id(ref compiler, "AliasInt") ||
        get_inner_fallible_type(ref compiler, alias_id(ref compiler, "Result")) != maybe ||
        nominal_info.members.length() != 2) {
        print("FAIL: union identity or alias substitution");
        return 1;
    }

    let maybe_info = get_union_type(ref compiler, maybe);
    if (maybe_info is null) {
        print("FAIL: Optional metadata missing");
        return 1;
    }
    let members: Vector(Int) = maybe_info.members;
    if (members.length() != 2 || members[0] != TYPE_NULL || members[1] != TYPE_INT) {
        print("FAIL: union tag order is unstable");
        return 1;
    }

    if (get_union_type(ref compiler, TYPE_INT) is !null ||
        get_union_type(ref compiler, compiler.type_counter + 1000) is !null ||
        is_union_type(ref compiler, TYPE_INT) || !is_union_type(ref compiler, maybe) ||
        union_member_index(ref compiler, TYPE_INT, TYPE_INT) != -1) {
        print("FAIL: missing union metadata must remain absent");
        return 1;
    }

    let i = 0;
    while (i < 100) {
        let info = get_union_type(ref compiler, maybe);
        if (info is null || info.members.length() != 2 || info.members[0] != TYPE_NULL) {
            print("FAIL: repeated metadata query lost its members");
            return 1;
        }
        i++;
    }

    print("PASS: union type normalization and aliases");
    return 0;
}
