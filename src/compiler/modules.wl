// compiler/modules.wl
import "file"
import * from "../frontend/ast.wl"
import * from "../frontend/tokens.wl"
import * from "context.wl"
import * from "../frontend/diagnostics.wl"
import Lexer, new_lexer, get_next_token from "../frontend/lexer.wl"
import Parser, parse from "../frontend/parser.wl"
import * from "target_eval.wl"
import * from "registration.wl"

func precompile_ast(c: Compiler, node: Struct, final_path: String, import_prefix: String, old_dir: String) -> Void {
// imports must be bound before this module publishes its declarations
    let block: BlockNode = node;
    let stmts: Vector(Struct) = block.stmts;
    let len: Int = 0;
    if (stmts is !null) { len = stmts.length(); }

    let imports: Vector(Struct) = [];
    let i: Int = 0;
    while (i < len) {
        let base: BaseNode = stmts[i];
        if (base.type == NODE_IMPORT) {
            compile_import(c, stmts[i]);
            imports.append(stmts[i]);
        }
        i += 1;
    }

    bind_module_prelude(c, Position(idx=0, ln=0, col=0, text="", fn=final_path));
    pre_register_structs(c, node);
    pre_register_funcs(c, node);
    pre_register_globals(c, node);

    let p_mod: ParsedModule = ParsedModule(
        path = final_path,
        prefix = import_prefix,
        dir = old_dir,
        is_package = c.current_module_is_package,
        ast = node,
        visible = c.current_file_visible_prefixes,
        namespaces = c.current_file_namespaces,
        types = c.current_file_type_aliases,
        funcs = c.current_file_func_aliases,
        globals = c.current_file_global_aliases,
        imports = imports
    );

    c.all_modules.append(p_mod);
}

func module_symbol_stem(name: String) -> String {
    let stem: String = "";
    let i: Int = 0;
    while (i < name.length()) {
        let ch: Char = name[i];
        let valid: Bool = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                            (ch >= '0' && ch <= '9') || ch == '_';
        if valid { stem += ch; } else { stem += '_'; }
        i += 1;
    }
    if (stem.length() == 0) { return "module"; }
    return stem;
}

func reserve_module_prefix(c: Compiler, canonical_name: String, final_path: String) -> String {
// readable prefixes are kept when possible, colliding file stems get a stable module id
    let stem: String = module_symbol_stem(canonical_name);
    let prefix: String = stem + ".";
    let owner: StringConstant = c.module_prefix_owners.lookup(prefix);
    if (owner is null || owner.value == final_path) {
        c.module_prefix_owners.put(prefix, StringConstant(id=0, value=final_path));
        return prefix;
    }

    while true {
        prefix = stem + "__m" + c.module_id + ".";
        c.module_id += 1;
        owner = c.module_prefix_owners.lookup(prefix);
        if (owner is null || owner.value == final_path) {
            c.module_prefix_owners.put(prefix, StringConstant(id=0, value=final_path));
            return prefix;
        }
    }
    return "";
}

func bind_loaded_prelude(c: Compiler, path: String, pos: Position) -> Void {
    let final_path: String = resolve_import_path(c, path, pos);
    if (final_path is null || final_path.length() == 0) { return; }
    let loaded: StringConstant = c.imported_modules.lookup(final_path);
    if (loaded is null) { return; }
    let star: Token = Token(type=TOK_MUL, value="*", line=pos.ln, col=pos.col);
    let symbols: Vector(Struct) = [ImportSymbolNode(name_tok=star, alias_tok=null)];
    let path_tok: Token = Token(type=TOK_STR_LIT, value=path, line=pos.ln, col=pos.col);
    bind_import_symbols(c, ImportNode(type=NODE_IMPORT, path_tok=path_tok, symbols=symbols, alias_tok=null, pos=pos), loaded.value, false, true);
}

func bind_module_prelude(c: Compiler, pos: Position) -> Void {
    bind_loaded_prelude(c, "errors", pos);
    bind_loaded_prelude(c, "builtin", pos);
    bind_loaded_prelude(c, "dict", pos);
}

func compile_import(c: Compiler, node: ImportNode) -> Void {
    let raw_path: String = node.path_tok.value;
    let final_path: String = resolve_import_path(c, raw_path, node.pos);
    if (final_path is null || final_path.length() == 0) { return; }

    let is_pkg: Bool = final_path.ends_with("/_pkg.wl") || final_path.ends_with("\\_pkg.wl");

    let len: Int = raw_path.length();
    let end_idx: Int = len;
    if (raw_path.ends_with(".wl")) {
        end_idx = len - 3;
    }
    let start_idx: Int = 0;
    let i: Int = len - 1;
    while (i >= 0) {
        let ch: Char = raw_path[i];
        if (ch == '/' || ch == '\\') {
            start_idx = i + 1;
            break;
        }
        i -= 1;
    }
    let canonical_name: String = raw_path.slice(start_idx, end_idx);

    let module_name: String = canonical_name;
    if (node.alias_tok is !null) {
        module_name = node.alias_tok.value;
    }

    let loaded_module: StringConstant = c.imported_modules.lookup(final_path);
    let import_prefix: String = "";
    if (loaded_module is !null) {
        import_prefix = loaded_module.value;
    } else {
        import_prefix = reserve_module_prefix(c, canonical_name, final_path);
    }
    if (node.symbols is null) {
        if (c.current_file_namespaces.contains_key(module_name)) { unbind_namespace(c, module_name); }
        let existing_prefix: String = c.current_file_visible_prefixes.lookup(module_name);
        if (existing_prefix is !null && existing_prefix != import_prefix) {
            throw_import_error(node.pos, "Module name '" + module_name + "' is already bound to another module.");
            return;
        }
        c.current_file_visible_prefixes.put(module_name, import_prefix);
    }

    if (loaded_module is !null) {
        if (node.symbols is !null) {
            bind_import_symbols(c, node, import_prefix, true, false);
            let s_len: Int = node.symbols.length();
            let i: Int = 0;
            let is_star: Bool = false;
            while (i < s_len) {
                let curr_sym: ImportSymbolNode = node.symbols[i];
                if (curr_sym.name_tok.type == TOK_MUL) { is_star = true; break; }
                i += 1;
            }
            if is_star {
                export_module_symbols(c, import_prefix, false, "");
            } else {
                export_named_imports(c, node);
            }
        } else {
            export_module_symbols(c, import_prefix, true, module_name);
        }
        return; 
    }

    let f: file.File = file.open(final_path)?;
    catch(err) {
        throw_import_error(node.pos, "Failed to open module '" + final_path + "' (error " + Int(err) + ").");
        return;
    }
    let source: String = f.read_all()?;
    catch(err) {
        f.close();
        throw_import_error(node.pos, "Failed to read module '" + final_path + "' (error " + Int(err) + ").");
        return;
    }
    f.close();

    let marker: StringConstant = StringConstant(id=0, value=import_prefix);
    c.imported_modules.put(final_path, marker);

    let old_prefix: String = c.current_package_prefix;
    let old_is_package: Bool = c.current_module_is_package;
    let old_dir: String = c.current_dir;

    c.current_dir = get_dir_name(final_path);
    c.current_package_prefix = import_prefix;
    c.current_module_is_package = is_pkg;

    let backup_visible: Dict(String, String) = c.current_file_visible_prefixes;
    let backup_namespaces: Dict(String, Bool) = c.current_file_namespaces;
    let backup_types: Dict(String, String) = c.current_file_type_aliases;
    let backup_funcs: Dict(String, String) = c.current_file_func_aliases;
    let backup_globals: Dict(String, String) = c.current_file_global_aliases;
    c.current_file_visible_prefixes = Dict();
    c.current_file_namespaces       = Dict();
    c.current_file_type_aliases     = Dict();
    c.current_file_func_aliases     = Dict();
    c.current_file_global_aliases   = Dict();
    let lexer: Lexer = new_lexer(final_path, source);
    let parser: Parser = Parser(lexer=lexer, current_tok=get_next_token(lexer), nesting=0);
    let mod_ast: Struct = parse(parser);

    precompile_ast(c, mod_ast, final_path, import_prefix, c.current_dir);

    c.current_file_visible_prefixes = backup_visible;
    c.current_file_namespaces       = backup_namespaces;
    c.current_file_type_aliases     = backup_types;
    c.current_file_func_aliases     = backup_funcs;
    c.current_file_global_aliases   = backup_globals;

    c.current_package_prefix = old_prefix;
    c.current_module_is_package = old_is_package;
    c.current_dir = old_dir;

    if (node.symbols is !null) {
        bind_import_symbols(c, node, import_prefix, true, false);
        let s_len: Int = node.symbols.length();
        let i: Int = 0;
        let is_star: Bool = false;
        while (i < s_len) {
            let curr_sym: ImportSymbolNode = node.symbols[i];
            if (curr_sym.name_tok.type == TOK_MUL) { is_star = true; break; }
            i += 1;
        }
        if is_star {
            export_module_symbols(c, import_prefix, false, "");
        } else {
            export_named_imports(c, node);
        }
    } else {
        export_module_symbols(c, import_prefix, true, module_name);
    }
}

