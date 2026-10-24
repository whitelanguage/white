// tests/fixtures/tooling/compiler.wl
import new_compiler, Compiler from "../../../src/compiler/context.wl"
import new_ast_arena from "../../../src/frontend/arena.wl"


func new_fixture_compiler() -> Compiler? {
// start from valid compiler state, each test replaces only the tables it exercises
    return new_compiler("", false, false, new_ast_arena())?;
}
