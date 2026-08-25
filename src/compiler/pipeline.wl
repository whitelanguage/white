// compiler/pipeline.wl

import * from "../frontend/ast.wl"
import * from "../frontend/tokens.wl"
import Position, GLOBAL_ERROR_COUNT, throw_import_error from "../frontend/diagnostics.wl"
import * from "context.wl"
import * from "modules.wl"
import * from "analysis.wl"
import compile_ast_pass, init_compiler_intrinsics, emit_llvm_prelude, emit_pending_generics, compile_end from "lowering/core.wl"

func register_program(ref c: Compiler, node: NodeID) -> Void {
    // discover every module before lowering; import order must not change symbol visibility
    let fake_path: Token = Token(type=TOK_STR_LIT, value="dict", line=0, col=0);
    let fake_pos: Position = Position(idx=0, ln=0, col=0, text="", fn="<prelude>");
    let star_tok: Token = Token(type=TOK_MUL, value="*", line=0, col=0);
    let star_sym: ImportSymbolNode = ImportSymbolNode(name_tok=star_tok, alias_tok=Token());
    let fake_syms: Vector(ImportSymbolNode) = [];
    fake_syms.append(star_sym);

    // error is a language-level prelude item, not part of the builtin namespace
    let error_path: Token = Token(type=TOK_STR_LIT, value="errors", line=0, col=0);
    compile_import(ref c, ImportNode(type=NODE_IMPORT, path_tok=error_path, symbols=fake_syms, alias_tok=Token(), pos=fake_pos));

    // builtin carries the hooks required by generated code
    let builtin_path: Token = Token(type=TOK_STR_LIT, value="builtin", line=0, col=0);
    compile_import(ref c, ImportNode(type=NODE_IMPORT, path_tok=builtin_path, symbols=fake_syms, alias_tok=Token(), pos=fake_pos));
    compile_import(ref c, ImportNode(type=NODE_IMPORT, path_tok=fake_path, symbols=fake_syms, alias_tok=Token(), pos=fake_pos));

    if (!has_struct(c.struct_table.lookup("dict.Variant"))) {
        throw_import_error(fake_pos, "Missing required intrinsic item '@CompilerIntrinsic struct Variant'. The standard library 'dict.wl' may be corrupted or missing.");
        return;
    }

    precompile_ast(ref c, node, "<main>", "", c.current_dir);
    let i: Int = 0;
    while (i < c.all_modules.length()) {
        let module: ParsedModule = c.all_modules[i];
        set_module_context(ref c, module);
        bind_module_prelude(ref c, Position(idx=0, ln=0, col=0, text="", fn=module.path));
        i++;
    }

    analyze_declarations(ref c);
    c.is_precompile_phase = false;
}

func prepare_program(ref c: Compiler, node: NodeID) -> Void {
    init_compiler_intrinsics(ref c);
    register_program(ref c, node);
}

func lower_llvm_program(ref c: Compiler) -> Void {
    let i: Int = 0;
    while (i < c.all_modules.length()) {
        compile_ast_pass(ref c, c.all_modules[i]);
        i++;
    }
    emit_pending_generics(ref c);
    compile_end(ref c);
}

func compile(ref c: Compiler, node: NodeID) -> Void {
    prepare_program(ref c, node);
    if (GLOBAL_ERROR_COUNT > 0) { return; }
    emit_llvm_prelude(ref c);
    lower_llvm_program(ref c);
}
