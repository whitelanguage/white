// core/WhitelangUtils.wl
import "sys"
import "file"
import Dict from "dict"

import "WhitelangTokens.wl"
import * from "WhitelangNodes.wl"
import * from "WhitelangExceptions.wl"
import * from "WhitelangTarget.wl"

// Type constants
const TYPE_INT   -> Int = 1;
const TYPE_FLOAT -> Int = 2;
const TYPE_BOOL  -> Int = 3;
const TYPE_VOID  -> Int = 4;
const TYPE_STRING -> Int = 5;
const TYPE_NULL   -> Int = 6;
const TYPE_GENERIC_STRUCT   -> Int = 7;
const TYPE_GENERIC_FUNCTION -> Int = 8;
const TYPE_LONG  -> Int = 9;
const TYPE_BYTE  -> Int = 10;
const TYPE_GENERIC_CLASS -> Int = 11;
const TYPE_GENERIC_METHOD -> Int = 12;
const TYPE_AUTO -> Int = 13;
const TYPE_CHAR -> Int = 14;
const TYPE_ANYPTR -> Int = 15;
const TYPE_GENERIC_ENUM -> Int = 28;

const TYPE_INT8    -> Int = 16;
const TYPE_INT16   -> Int = 17;
//    TYPE_INT32   -> TYPE_INT
//    TYPE_INT64   -> TYPE_LONG
const TYPE_INT128  -> Int = 18;

//    TYPE_UINT8   -> TYPE_BYTE
const TYPE_UINT16  -> Int = 19;
const TYPE_UINT32  -> Int = 20;
const TYPE_UINT64  -> Int = 21;
const TYPE_UINT128 -> Int = 22;

const TYPE_FLOAT32 -> Int = 23;
//    TYPE_FLOAT64 -> TYPE_FLOAT

const TYPE_INTSIZE  -> Int = 24;
const TYPE_UINTSIZE -> Int = 25;
const TYPE_ANY_ERROR -> Int = 26;

const TYPE_POISON -> Int = 98;
const TYPE_NULLPTR -> Int = 99;


// Annotation Flags
const FLAG_ANN_INTRINSIC  -> Int = 0x001;
const FLAG_ANN_COMP_LINK  -> Int = 0x002;
const FLAG_ANN_EXPORT     -> Int = 0x004;


// Core data structures
struct GCTracker(
    reg  -> String,
    type -> Int
)

struct CompileResult(
    reg  -> String,
    type -> Int,
    origin_type -> Int,
    owns_ref -> Bool,
    is_const_access -> Bool
)

struct SystemAnnResult(
    ann_flags -> Int,
    compiler_link_name -> String,
    intrinsic_name -> String
)

struct TypeListNode(type -> Int)

struct Scope(
    table  -> Dict, // symbol table of the current level
    parent -> Struct,  // parent scope or null
    gc_vars -> Vector(Struct),
    depth  -> Int
)

struct StringConstant(
    id    -> Int,
    value -> String
)

struct SymbolInfo(
    reg  -> String, 
    type -> Int,
    origin_type -> Int, // for generic type
    is_const -> Bool, // const
    is_const_access -> Bool,
    func_arg_types -> Vector(Struct)
)

struct FuncInfo(
    name     -> String,
    base_name  -> String,
    ret_type -> Int, 
    arg_types -> Vector(Struct),
    arg_names -> Vector(String),
    is_varargs -> Bool,
    ann_flags  -> Int,
    compiler_link_name -> String,
    abi_name -> String,
    mutates_self -> Bool
)

struct FieldInfo(
    name      -> String,
    type      -> Int,
    llvm_type -> String,
    offset    -> Int,   // for getelementptr
    is_const  -> Bool
)
struct StructInfo(
    name        -> String,
    type_id     -> Int,
    fields      -> Vector(Struct),
    llvm_name   -> String,
    init_body   -> Struct,
    is_class    -> Bool,
    vtable_name -> String,
    parent_id   -> Int,
    vtable      -> Vector(Struct),
    ann_flags   -> Int,
    is_enum     -> Bool,
    is_error    -> Bool,
    is_interface -> Bool,
    interfaces  -> Vector(Struct),
    compiler_link_name -> String
)

struct ArrayInfo(
    base_type -> Int,
    size      -> Int,
    llvm_name -> String
)

struct SliceParts(
    start -> String,
    length -> String,
    owner -> String,
    data_slot -> String,
    size_slot -> String,
    data -> String
)

struct CaptureScope(
    local_vars -> Dict,
    captured_vars -> Dict,
    captured_list -> Vector(String)
)

struct Compiler(
    output_file -> file.File,
    reg_count   -> Int, 
    symbol_table -> Scope,
    global_symbol_table -> Dict,
    constant_nums -> Dict,
    constant_integers -> Dict,
    constant_wide_integers -> Dict,
    func_table   -> Dict,
    struct_table -> Dict,
    struct_id_map -> Dict,
    indent      -> String, 
    loop_stack   -> Struct, 
    scope_depth  -> Int,
    has_main     -> Bool,
    current_ret_type -> Int,
    string_list -> Vector(Struct),
    str_count   -> Int,
    type_counter -> Int, // custom type
    ptr_cache -> Dict,       // Key: "ptr_ID", Value: SymbolInfo(reg="", type=ptr_id)
    ptr_base_map -> Dict,    // Key: "ID", Value: SymbolInfo(reg="", type=base_id)
    vector_cache -> Dict,    // Key: "vec_baseID", Value: SymbolInfo(type=new_id)
    vector_base_map -> Dict, // Key: "ID", Value: SymbolInfo(type=baseID)
    array_info_map -> Dict, 
    array_type_cache -> Dict,
    func_ret_map -> Dict,
    method_ret_map -> Dict,
    declared_externs -> Dict,
    imported_modules -> Dict,
    module_prefix_owners -> Dict,
    module_id -> Int,
    current_package_prefix -> String,
    current_module_is_package -> Bool,
    current_file_visible_prefixes -> Dict,
    current_file_namespaces -> Dict,
    current_file_type_aliases -> Dict,
    alloc_regs -> Vector(String),
    current_dir -> String,
    current_file_func_aliases -> Dict,
    current_file_global_aliases -> Dict,
    global_type_aliases -> Dict,
    global_func_aliases -> Dict,
    global_var_aliases -> Dict,
    compiler_link -> Dict,
    curr_func -> FuncInfo,
    expected_type -> Int,
    hoist_scope -> Scope,
    type_drop_list -> Vector(Struct),
    global_buffer -> String,
    string_pool -> Dict,
    is_shared -> Bool,
    emit_source_context -> Bool,
    all_modules -> Vector(Struct),
    is_precompile_phase -> Bool,
    fallible_cache -> Dict,
    fallible_base_map -> Dict,
    current_catch_label -> String,
    current_catch_err_ptr -> String,
    current_catch_scope -> Struct,
    extra_libs -> Vector(String),
    error_types -> Vector(Struct)
)

struct ParsedModule(
    path -> String,
    prefix -> String,
    dir -> String,
    is_package -> Bool,
    ast -> Struct,
    visible -> Dict,
    namespaces -> Dict,
    types -> Dict,
    funcs -> Dict,
    globals -> Dict,
    imports -> Vector(Struct)
)


struct LoopScope(
    label_continue -> String,
    label_break    -> String,
    parent         -> Struct,
    loop_scope     -> Struct
)


// compiler init & state utils
func new_compiler(out_path -> String, is_shared -> Bool, emit_source_context -> Bool) -> Compiler? {
    let f -> file.File = file.create(out_path)?;
    // initialize empty scope
    let root_scope -> Scope = Scope(table=Dict(32), parent=null, gc_vars=[], depth=0);

    let comp -> Compiler = Compiler(
        output_file = f,
        reg_count = 1,
        symbol_table = root_scope,
        global_symbol_table = Dict(32),
        constant_nums = Dict(32),
        constant_integers = Dict(32),
        constant_wide_integers = Dict(32),
        func_table = Dict(32),
        struct_table = Dict(32),
        struct_id_map = Dict(32),
        indent = "  ",
        loop_stack = null,
        scope_depth = 0,
        has_main = false,
        current_ret_type = TYPE_VOID,
        string_list = [],
        str_count = 0,
        type_counter = 100,
        ptr_cache=Dict(32),
        ptr_base_map=Dict(32),
        vector_cache=Dict(32),
        vector_base_map=Dict(32),
        func_ret_map=Dict(32),
        method_ret_map=Dict(32),
        declared_externs=Dict(32),
        imported_modules=Dict(32),
        module_prefix_owners=Dict(32),
        module_id=0,
        current_module_is_package=false,
        current_file_visible_prefixes = Dict(32),
        current_file_namespaces = Dict(32),
        current_file_type_aliases = Dict(32),
        alloc_regs = [],
        current_dir = ".",
        current_file_func_aliases = Dict(32),
        current_file_global_aliases = Dict(32),
        global_type_aliases = Dict(32),
        global_func_aliases = Dict(32),
        global_var_aliases = Dict(32),
        compiler_link = Dict(16),
        current_package_prefix = "",
        curr_func = null,
        expected_type = 0,
        hoist_scope = null,
        type_drop_list = [],
        global_buffer = "",
        string_pool = Dict(128),
        array_info_map = Dict(32),
        array_type_cache = Dict(32),
        is_shared = is_shared,
        emit_source_context = emit_source_context,
        all_modules = [],
        is_precompile_phase = true,
        fallible_cache = Dict(32),
        fallible_base_map = Dict(32),
        current_catch_label = "",
        current_catch_err_ptr = "",
        current_catch_scope = null,
        extra_libs = [],
        error_types = []
    );

    comp.type_drop_list.append(TypeListNode(type=TYPE_GENERIC_FUNCTION));
    comp.type_drop_list.append(TypeListNode(type=TYPE_STRING));
    return comp;
}

func next_reg(c -> Compiler) -> String {
    let name -> String = "%t" + c.reg_count;
    c.reg_count += 1;
    return name;
}

func next_label(c -> Compiler) -> String {
    let name -> String = "L" + c.reg_count;
    c.reg_count += 1;
    return name;
}

func void_result() -> CompileResult {
    return CompileResult(reg="", type=TYPE_VOID);
}

func module_member_name(prefix -> String, path_parts -> Vector(String), field_name -> String) -> String {
    let result -> String = prefix;
    let i -> Int = path_parts.length() - 1;
    while (i >= 0) {
        result += path_parts[i] + ".";
        i -= 1;
    }
    return result + field_name;
}

func register_import_namespaces(c -> Compiler, table -> Dict, pos -> Position) -> Void {
    let i -> Int = 0;
    while (i < table.capacity) {
        if (table.hashes[i] >= 2) {
            let name -> String = table.keys[i];
            let dot -> Int = 0;
            while (dot < name.length() && name[dot] != '.') { dot += 1; }
            if (dot > 0 && dot < name.length()) {
                let namespace -> String = name.slice(0, dot);
                if (c.current_file_visible_prefixes.get(namespace) is !null) {
                    report_import_collision(c, pos, "module", namespace);
                } else {
                    c.current_file_namespaces.put(namespace, true);
                }
            }
        }
        i += 1;
    }
}

func is_visible_namespace(c -> Compiler, name -> String) -> Bool {
    if (c.current_file_visible_prefixes.get(name) is !null) { return true; }
    return c.current_file_namespaces.get(name) is !null;
}

func erase_alias_prefix(table -> Dict, prefix -> String) -> Void {
    let removed -> Vector(String) = [];
    let i -> Int = 0;
    while (i < table.capacity) {
        if (table.hashes[i] >= 2) {
            let key -> String = table.keys[i];
            if (key.starts_with(prefix)) { removed.append(key); }
        }
        i += 1;
    }
    i = 0;
    while (i < removed.length()) {
        table.remove(removed[i]);
        i += 1;
    }
}

func unbind_namespace(c -> Compiler, name -> String) -> Void {
    let prefix -> String = name + ".";
    erase_alias_prefix(c.current_file_func_aliases, prefix);
    erase_alias_prefix(c.current_file_type_aliases, prefix);
    erase_alias_prefix(c.current_file_global_aliases, prefix);
    c.current_file_namespaces.remove(name);
}


// symbol & field lookup utils
func find_symbol(c -> Compiler, name -> String) -> SymbolInfo {
    let curr -> Scope = c.symbol_table;
    while (curr is !null) {
        let info -> SymbolInfo = curr.table.get(name);
        if (info is !null) { return info; }
        curr = curr.parent;
    }

    if (c.current_package_prefix != "") {
        let fallback -> SymbolInfo = c.global_symbol_table.get(c.current_package_prefix + name);
        if (fallback is !null) { return fallback; }
    }

    let g_info -> SymbolInfo = c.global_symbol_table.get(name);
    if (g_info is !null) { return g_info; }

    let mapped_global -> String = c.current_file_global_aliases.get(name);
    if (mapped_global is !null) {
        let alias_info -> SymbolInfo = c.global_symbol_table.get(mapped_global);
        if (alias_info is !null) { return alias_info; }
    }

    let g_alias -> String = c.global_var_aliases.get(name);
    if (g_alias is !null) {
        let alias_info -> SymbolInfo = c.global_symbol_table.get(g_alias);
        if (alias_info is !null) { return alias_info; }
    }

    return c.global_symbol_table.get(name);
}

func find_field(s_info -> StructInfo, name -> String) -> FieldInfo {
    if (s_info is null) { return null; }
    let fields -> Vector(Struct) = s_info.fields;
    let len -> Int = 0; if (fields is !null) { len = fields.length(); }
    let i -> Int = 0;
    while (i < len) {
        let curr -> FieldInfo = fields[i];
        if (curr.name == name) { return curr; }
        i += 1;
    }
    return null;
}

func get_field_by_index(s_info -> StructInfo, index -> Int) -> FieldInfo {
    let fields -> Vector(Struct) = s_info.fields;
    let len -> Int = 0; if (fields is !null) { len = fields.length(); }
    if (index >= 0 && index < len) {
        return fields[index];
    }
    return null;
}

func export_module_symbols(c -> Compiler, prefix -> String, as_submodule -> Bool, module_name -> String) -> Void {
    if (c.current_package_prefix == "" || !c.current_module_is_package) { return; }
    if (as_submodule && module_name.starts_with("__")) { return; }
    
    let p_len -> Int = prefix.length();
    let export_prefix -> String = c.current_package_prefix;
    if (as_submodule) {
        export_prefix = c.current_package_prefix + module_name + ".";
    }

    let f_cap -> Int = c.func_table.capacity;
    let k -> Int = 0;
    while (k < f_cap) {
        if (c.func_table.hashes[k] >= 2) { 
            let f_key -> String = c.func_table.keys[k];
            if (f_key.starts_with(prefix)) {
                let bare_name -> String = f_key.slice(p_len, f_key.length());
                if (!bare_name.starts_with("__")) {
                    c.global_func_aliases.put(export_prefix + bare_name, f_key);
                }
            }
        }
        k += 1;
    }

    let s_cap -> Int = c.struct_table.capacity;
    k = 0;
    while (k < s_cap) {
        if (c.struct_table.hashes[k] >= 2) {
            let s_key -> String = c.struct_table.keys[k];
            if (s_key.starts_with(prefix)) {
                let bare_name -> String = s_key.slice(p_len, s_key.length());
                if (!bare_name.starts_with("__")) {
                    c.global_type_aliases.put(export_prefix + bare_name, s_key);
                }
            }
        }
        k += 1;
    }

    let g_cap -> Int = c.global_symbol_table.capacity;
    k = 0;
    while (k < g_cap) {
        if (c.global_symbol_table.hashes[k] >= 2) {
            let g_key -> String = c.global_symbol_table.keys[k];
            if (g_key.starts_with(prefix)) {
                let bare_name -> String = g_key.slice(p_len, g_key.length());
                if (!bare_name.starts_with("__")) {
                    c.global_var_aliases.put(export_prefix + bare_name, g_key);
                }
            }
        }
        k += 1;
    }

    let af_cap -> Int = c.global_func_aliases.capacity;
    k = 0;
    while (k < af_cap) {
        if (c.global_func_aliases.hashes[k] >= 2) { 
            let a_key -> String = c.global_func_aliases.keys[k];
            if (a_key.starts_with(prefix)) {
                let bare_name -> String = a_key.slice(p_len, a_key.length());
                if (!bare_name.starts_with("__")) {
                    let real_target -> String = c.global_func_aliases.values[k];
                    c.global_func_aliases.put(export_prefix + bare_name, real_target);
                }
            }
        }
        k += 1;
    }

    let at_cap -> Int = c.global_type_aliases.capacity;
    k = 0;
    while (k < at_cap) {
        if (c.global_type_aliases.hashes[k] >= 2) { 
            let a_key -> String = c.global_type_aliases.keys[k];
            if (a_key.starts_with(prefix)) {
                let bare_name -> String = a_key.slice(p_len, a_key.length());
                if (!bare_name.starts_with("__")) {
                    let real_target -> String = c.global_type_aliases.values[k];
                    c.global_type_aliases.put(export_prefix + bare_name, real_target);
                }
            }
        }
        k += 1;
    }

    let av_cap -> Int = c.global_var_aliases.capacity;
    k = 0;
    while (k < av_cap) {
        if (c.global_var_aliases.hashes[k] >= 2) { 
            let a_key -> String = c.global_var_aliases.keys[k];
            if (a_key.starts_with(prefix)) {
                let bare_name -> String = a_key.slice(p_len, a_key.length());
                if (!bare_name.starts_with("__")) {
                    let real_target -> String = c.global_var_aliases.values[k];
                    c.global_var_aliases.put(export_prefix + bare_name, real_target);
                }
            }
        }
        k += 1;
    }
}

func report_import_collision(c -> Compiler, pos -> Position, kind -> String, name -> String) -> Void {
// imports are bound in both passes; only codegen emits diagnostics
    if (!c.is_precompile_phase) {
        throw_import_error(pos, "Name collision for " + kind + " '" + name + "'. Please use explicit alias.");
    }
}

func is_direct_export(name -> String) -> Bool {
    let i -> Int = 0;
    while (i < name.length()) {
        if (name[i] == '.') { return false; }
        i += 1;
    }
    return true;
}

func bind_import_symbols(c -> Compiler, node -> ImportNode, prefix -> String, include_submodules -> Bool, keep_existing -> Bool) -> Void {
    let symbols -> Vector(Struct) = node.symbols;
    let s_len -> Int = 0; if (symbols is !null) { s_len = symbols.length(); }
    let i -> Int = 0;
    
    while (i < s_len) {
        let curr_sym -> ImportSymbolNode = symbols[i];

        if (curr_sym.name_tok.type == WhitelangTokens.TOK_MUL) {
            if (prefix == "") {
                i += 1;
                continue;
            }
            
            let p_len -> Int = prefix.length();

            let f_cap -> Int = c.func_table.capacity;
            let k -> Int = 0;
            while (k < f_cap) {
                if (c.func_table.hashes[k] >= 2) { 
                    let f_key -> String = c.func_table.keys[k];
                    if (f_key.starts_with(prefix)) {
                        let bare_name -> String = f_key.slice(p_len, f_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_f -> String = c.current_file_func_aliases.get(bare_name);
                            if (existing_f is !null && keep_existing) {
                            } else if (existing_f is !null && existing_f != f_key) {
                                report_import_collision(c, node.pos, "function", bare_name);
                            } else {
                                c.current_file_func_aliases.put(bare_name, f_key);
                            }
                        }
                    }
                }
                k += 1;
            }

            let s_cap -> Int = c.struct_table.capacity;
            k = 0;
            while (k < s_cap) {
                if (c.struct_table.hashes[k] >= 2) {
                    let s_key -> String = c.struct_table.keys[k];
                    if (s_key.starts_with(prefix)) {
                        let bare_name -> String = s_key.slice(p_len, s_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_s -> String = c.current_file_type_aliases.get(bare_name);
                            if (existing_s is !null && keep_existing) {
                            } else if (existing_s is !null && existing_s != s_key) {
                                report_import_collision(c, node.pos, "type", bare_name);
                            } else {
                                c.current_file_type_aliases.put(bare_name, s_key);
                            }
                        }
                    }
                }
                k += 1;
            }

            let g_cap -> Int = c.global_symbol_table.capacity;
            k = 0;
            while (k < g_cap) {
                if (c.global_symbol_table.hashes[k] >= 2) {
                    let g_key -> String = c.global_symbol_table.keys[k];
                    if (g_key.starts_with(prefix)) {
                        let bare_name -> String = g_key.slice(p_len, g_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_g -> String = c.current_file_global_aliases.get(bare_name);
                            if (existing_g is !null && keep_existing) {
                            } else if (existing_g is !null && existing_g != g_key) {
                                report_import_collision(c, node.pos, "global", bare_name);
                            } else {
                                c.current_file_global_aliases.put(bare_name, g_key);
                            }
                        }
                    }
                }
                k += 1;
            }

            let g_f_cap -> Int = c.global_func_aliases.capacity;
            k = 0;
            while (k < g_f_cap) {
                if (c.global_func_aliases.hashes[k] >= 2) { 
                    let f_key -> String = c.global_func_aliases.keys[k];
                    if (f_key.starts_with(prefix) && c.func_table.get(f_key) is null) {
                        let bare_name -> String = f_key.slice(p_len, f_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_f -> String = c.current_file_func_aliases.get(bare_name);
                            let val -> String = c.global_func_aliases.get(f_key);
                            if (existing_f is !null && keep_existing) {
                            } else if (existing_f is !null && existing_f != val) {
                                report_import_collision(c, node.pos, "function", bare_name);
                            } else {
                                c.current_file_func_aliases.put(bare_name, val);
                            }
                        }
                    }
                }
                k += 1;
            }

            let g_s_cap -> Int = c.global_type_aliases.capacity;
            k = 0;
            while (k < g_s_cap) {
                if (c.global_type_aliases.hashes[k] >= 2) { 
                    let s_key -> String = c.global_type_aliases.keys[k];
                    if (s_key.starts_with(prefix) && c.struct_table.get(s_key) is null) {
                        let bare_name -> String = s_key.slice(p_len, s_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_s -> String = c.current_file_type_aliases.get(bare_name);
                            let val -> String = c.global_type_aliases.get(s_key);
                            if (existing_s is !null && keep_existing) {
                            } else if (existing_s is !null && existing_s != val) {
                                report_import_collision(c, node.pos, "type", bare_name);
                            } else {
                                c.current_file_type_aliases.put(bare_name, val);
                            }
                        }
                    }
                }
                k += 1;
            }

            let g_v_cap -> Int = c.global_var_aliases.capacity;
            k = 0;
            while (k < g_v_cap) {
                if (c.global_var_aliases.hashes[k] >= 2) { 
                    let v_key -> String = c.global_var_aliases.keys[k];
                    if (v_key.starts_with(prefix) && c.global_symbol_table.get(v_key) is null) {
                        let bare_name -> String = v_key.slice(p_len, v_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_v -> String = c.current_file_global_aliases.get(bare_name);
                            let val -> String = c.global_var_aliases.get(v_key);
                            if (existing_v is !null && keep_existing) {
                            } else if (existing_v is !null && existing_v != val) {
                                report_import_collision(c, node.pos, "global", bare_name);
                            } else {
                                c.current_file_global_aliases.put(bare_name, val);
                            }
                        }
                    }
                }
                k += 1;
            }

            if include_submodules {
                register_import_namespaces(c, c.current_file_func_aliases, node.pos);
                register_import_namespaces(c, c.current_file_type_aliases, node.pos);
                register_import_namespaces(c, c.current_file_global_aliases, node.pos);
            }
            i += 1;
            continue;
        }

        let orig_name -> String = curr_sym.name_tok.value;

        if (orig_name.starts_with("__")) {
            throw_import_error(node.pos, "Cannot import '" + orig_name + "', symbol not found in module.");
            return;
        }

        let target_name -> String = orig_name;

        if (curr_sym.alias_tok is !null) {
            let a_tok -> WhitelangTokens.Token = curr_sym.alias_tok;
            target_name = a_tok.value;
        }

        let lookup_name -> String = prefix + orig_name;
        let found -> Bool = false;

        if (c.func_table.get(lookup_name) is !null) {
            let existing_f -> String = c.current_file_func_aliases.get(target_name);
            if (existing_f is !null && keep_existing) { }
            else if (existing_f is !null && existing_f != lookup_name) { report_import_collision(c, node.pos, "function", target_name); }
            else { c.current_file_func_aliases.put(target_name, lookup_name); }
            found = true;
        } else if (c.global_func_aliases.get(lookup_name) is !null) {
            let real_name -> String = c.global_func_aliases.get(lookup_name);
            let existing_f -> String = c.current_file_func_aliases.get(target_name);
            if (existing_f is !null && keep_existing) { }
            else if (existing_f is !null && existing_f != real_name) { report_import_collision(c, node.pos, "function", target_name); }
            else { c.current_file_func_aliases.put(target_name, real_name); }
            found = true;
        }
        if (c.struct_table.get(lookup_name) is !null) {
            let existing_s -> String = c.current_file_type_aliases.get(target_name);
            if (existing_s is !null && keep_existing) { }
            else if (existing_s is !null && existing_s != lookup_name) { report_import_collision(c, node.pos, "type", target_name); }
            else { c.current_file_type_aliases.put(target_name, lookup_name); }
            found = true;
        } else if (c.global_type_aliases.get(lookup_name) is !null) {
            let real_name -> String = c.global_type_aliases.get(lookup_name);
            let existing_s -> String = c.current_file_type_aliases.get(target_name);
            if (existing_s is !null && keep_existing) { }
            else if (existing_s is !null && existing_s != real_name) { report_import_collision(c, node.pos, "type", target_name); }
            else { c.current_file_type_aliases.put(target_name, real_name); }
            found = true;
        }
        if (c.global_symbol_table.get(lookup_name) is !null) {
            let existing_g -> String = c.current_file_global_aliases.get(target_name);
            if (existing_g is !null && keep_existing) { }
            else if (existing_g is !null && existing_g != lookup_name) { report_import_collision(c, node.pos, "global", target_name); }
            else { c.current_file_global_aliases.put(target_name, lookup_name); }
            found = true;
        } else if (c.global_var_aliases.get(lookup_name) is !null) {
            let real_name -> String = c.global_var_aliases.get(lookup_name);
            let existing_g -> String = c.current_file_global_aliases.get(target_name);
            if (existing_g is !null && keep_existing) { }
            else if (existing_g is !null && existing_g != real_name) { report_import_collision(c, node.pos, "global", target_name); }
            else { c.current_file_global_aliases.put(target_name, real_name); }
            found = true;
        }

        if (!found && !c.is_precompile_phase) {
            throw_import_error(node.pos, "Cannot import '" + orig_name + "', symbol not found in module.");
        }

        i += 1;
    }
}

func export_named_imports(c -> Compiler, node -> ImportNode) -> Void {
    if (!c.current_module_is_package || node.symbols is null) { return; }

    let i -> Int = 0;
    while (i < node.symbols.length()) {
        let symbol -> ImportSymbolNode = node.symbols[i];
        if (symbol.name_tok.type == WhitelangTokens.TOK_MUL) { return; }

        let target_name -> String = symbol.name_tok.value;
        if (symbol.alias_tok is !null) { target_name = symbol.alias_tok.value; }
        let export_name -> String = c.current_package_prefix + target_name;

        let mapped_func -> String = c.current_file_func_aliases.get(target_name);
        if (mapped_func is !null) { c.global_func_aliases.put(export_name, mapped_func); }

        let mapped_type -> String = c.current_file_type_aliases.get(target_name);
        if (mapped_type is !null) { c.global_type_aliases.put(export_name, mapped_type); }

        let mapped_global -> String = c.current_file_global_aliases.get(target_name);
        if (mapped_global is !null) { c.global_var_aliases.put(export_name, mapped_global); }
        i += 1;
    }
}

func format_ast_path(node_raw -> Struct) -> String {
    let node -> BaseNode = node_raw;
    if (node.type == NODE_VAR_ACCESS) {
        let v -> VarAccessNode = node_raw;
        return v.name_tok.value;
    }
    if (node.type == NODE_FIELD_ACCESS) {
        let f -> FieldAccessNode = node_raw;
        return format_ast_path(f.obj) + "." + f.field_name;
    }
    return "<unknown_path>";
}


// type system & mapping utils
func get_size_llvm_type() -> String {
    return "i" + get_target_pointer_bits();
}

func get_pointer_size_bytes() -> Int {
    return get_target_pointer_bits() / 8;
}

func align_to(value -> Int, alignment -> Int) -> Int {
    if (alignment <= 1) { return value; }
    let remainder -> Int = value % alignment;
    if (remainder == 0) { return value; }
    return value + alignment - remainder;
}

func target_i64_align() -> Int {
    if (get_target_arch() == sys.Arch.X86 && get_target_os() != sys.Os.Windows) { return 4; }
    return 8;
}

func any_error_align() -> Int {
    return target_i64_align();
}

func any_error_size() -> Int {
    return align_to(12, any_error_align());
}

func closure_payload_size() -> Int {
    return get_pointer_size_bytes() * 2;
}

func closure_env_offset() -> Int {
    return get_pointer_size_bytes();
}

func variant_payload_size() -> Int {
    return 24;
}

func get_vector_llvm_type(c -> Compiler, element_type -> Int) -> String {
    let size_ty -> String = get_size_llvm_type();
    let element_ty -> String = get_llvm_type_str(c, element_type);
    return "{ " + size_ty + ", " + size_ty + ", " + element_ty + "* }";
}

func get_llvm_type_str(c -> Compiler, type_id -> Int) -> String {
    if (type_id == TYPE_INT)   { return "i32"; }
    if (type_id == TYPE_LONG)   { return "i64"; }
    if (type_id == TYPE_BYTE)  { return "i8"; }
    if (type_id == TYPE_FLOAT) { return "double"; }
    if (type_id == TYPE_BOOL)  { return "i1"; }
    if (type_id == TYPE_VOID)  { return "void"; }
    if (type_id == TYPE_STRING){ return "%struct.$String*"; }
    if (type_id == TYPE_CHAR)  { return "i32"; }
    if (type_id == TYPE_GENERIC_STRUCT) { return "i8*"; }
    if (type_id == TYPE_GENERIC_FUNCTION) { return "i8*"; }
    if (type_id == TYPE_GENERIC_CLASS) { return "i8*"; }
    if (type_id == TYPE_GENERIC_METHOD) { return "i8*"; }
    if (type_id == TYPE_GENERIC_ENUM) { return "i32"; }
    if (type_id == TYPE_ANYPTR) { return "i8*"; }
    if (type_id == TYPE_ANY_ERROR) { return "{ i64, i32 }"; }
    
    if (type_id == TYPE_POISON) { return "void"; } // dummy type for poison variables

    if (type_id == TYPE_INT8)  { return "i8"; }
    if (type_id == TYPE_INT16) { return "i16"; }
    if (type_id == TYPE_INT128){ return "i128"; }
    if (type_id == TYPE_UINT16){ return "i16"; }
    if (type_id == TYPE_UINT32){ return "i32"; }
    if (type_id == TYPE_UINT64){ return "i64"; }
    if (type_id == TYPE_UINT128){ return "i128"; }
    if (type_id == TYPE_FLOAT32){ return "float"; }
    if (type_id == TYPE_INTSIZE || type_id == TYPE_UINTSIZE) { return get_size_llvm_type(); }

    let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
    if (arr_info is !null) {
        if (arr_info.size == -1) { return arr_info.llvm_name + "*"; }
        return arr_info.llvm_name;
    }

    if (type_id >= 100) {
        let f_info -> SymbolInfo = c.func_ret_map.get("" + type_id);
        if (f_info is !null) {
            return "i8*";
        }

        let m_info -> SymbolInfo = c.method_ret_map.get("" + type_id);
        if (m_info is !null) {
            return "i8*";
        }

        let ptr_info -> SymbolInfo = c.ptr_base_map.get("" + type_id);
        if (ptr_info is !null) {
            if (ptr_info.type == TYPE_VOID) { return "i8*"; }
            return get_llvm_type_str(c, ptr_info.type) + "*";
        }

        let s_info -> StructInfo = c.struct_id_map.get("" + type_id);
        if (s_info is !null) { 
            if (s_info.is_enum) { return "i32"; }
            if (s_info.is_interface) { return "{ i8*, i8* }"; }
            return s_info.llvm_name + "*"; 
        }

        let v_info -> SymbolInfo = c.vector_base_map.get("" + type_id);
        if (v_info is !null) {
            return get_vector_llvm_type(c, v_info.type) + "*";
        }

        let fll_info -> SymbolInfo = c.fallible_base_map.get("" + type_id);
        if (fll_info is !null) {
            if (fll_info.type == TYPE_VOID) {
                return "{ i1, { i64, i32 } }";
            }
            let elem_ty -> String = get_llvm_type_str(c, fll_info.type);
            return "{ i1, { i64, i32 }, " + elem_ty + " }";
        }
    }

    throw_internal_compiler_error(null, "Unknown type id " + type_id + " reached LLVM lowering.");
    return "void";
}

func get_type_name(c -> Compiler, type_id -> Int) -> String {
    if (type_id == TYPE_INT)   { return "Int"; }
    if (type_id == TYPE_LONG)  { return "Long"; }
    if (type_id == TYPE_BYTE)  { return "Byte"; }
    if (type_id == TYPE_FLOAT) { return "Float"; }
    if (type_id == TYPE_BOOL)  { return "Bool"; }
    if (type_id == TYPE_VOID)  { return "Void"; }
    if (type_id == TYPE_STRING) { return "String"; }
    if (type_id == TYPE_CHAR)   { return "Char"; }
    if (type_id == TYPE_NULL)   { return "null"; }
    if (type_id == TYPE_NULLPTR){ return "nullptr"; }
    if (type_id == TYPE_POISON) { return "Poison"; }
    if (type_id == TYPE_GENERIC_STRUCT) { return "Struct"; }
    if (type_id == TYPE_GENERIC_FUNCTION) { return "Function"; }
    if (type_id == TYPE_GENERIC_CLASS) { return "Class"; }
    if (type_id == TYPE_GENERIC_METHOD) { return "Method"; }
    if (type_id == TYPE_GENERIC_ENUM) { return "Enum"; }
    if (type_id == TYPE_AUTO) { return "Auto"; }
    if (type_id == TYPE_ANYPTR) { return "AnyPtr"; }
    if (type_id == TYPE_ANY_ERROR) { return "AnyError"; }

    if (type_id == TYPE_INT8)  { return "Int8"; }
    if (type_id == TYPE_INT16) { return "Int16"; }
    if (type_id == TYPE_INT128){ return "Int128"; }
    if (type_id == TYPE_UINT16){ return "UInt16"; }
    if (type_id == TYPE_UINT32){ return "UInt32"; }
    if (type_id == TYPE_UINT64){ return "UInt64"; }
    if (type_id == TYPE_UINT128){ return "UInt128"; }
    if (type_id == TYPE_FLOAT32){ return "Float32"; }
    if (type_id == TYPE_INTSIZE){ return "IntSize"; }
    if (type_id == TYPE_UINTSIZE){ return "UIntSize"; }

    if (type_id >= 100) {
        let f_info -> SymbolInfo = c.func_ret_map.get("" + type_id);
        if (f_info is !null) {
            let sig -> String = "Function(";
            let a_idx -> Int = 0;
            if (f_info.func_arg_types is !null) {
                let len -> Int = f_info.func_arg_types.length();
                while (a_idx < len) {
                    let a_node -> TypeListNode = f_info.func_arg_types[a_idx];
                    sig = sig + get_type_name(c, a_node.type) + ", ";
                    a_idx += 1;
                }
            }
            sig = sig + get_type_name(c, f_info.type) + ")";
            return sig;
        }

        let m_info -> SymbolInfo = c.method_ret_map.get("" + type_id);
        if (m_info is !null) {
            let sig -> String = "Method(";
            let a_idx -> Int = 0;
            if (m_info.func_arg_types is !null) {
                let len -> Int = m_info.func_arg_types.length();
                while (a_idx < len) {
                    let a_node -> TypeListNode = m_info.func_arg_types[a_idx];
                    sig = sig + get_type_name(c, a_node.type) + ", ";
                    a_idx += 1;
                }
            }
            sig = sig + get_type_name(c, m_info.type) + ")";
            return sig;
        }

        let s_info -> StructInfo = c.struct_id_map.get("" + type_id);
        if (s_info is !null) {
            return s_info.name;
        }

        let ptr_info -> SymbolInfo = c.ptr_base_map.get("" + type_id);
        if (ptr_info is !null) {
            return "Ptr<" + get_type_name(c, ptr_info.type) + ">";
        }

        let v_info -> SymbolInfo = c.vector_base_map.get("" + type_id);
        if (v_info is !null) {
            return "Vector(" + get_type_name(c, v_info.type) + ")";
        }

        let fll_info -> SymbolInfo = c.fallible_base_map.get("" + type_id);
        if (fll_info is !null) {
            return get_type_name(c, fll_info.type) + "?";
        }

        let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
        if (arr_info is !null) {
            return get_type_name(c, arr_info.base_type) + "[" + arr_info.size + "]";
        }
    }
    
    return "Unknown";
}

func is_pointer_type(c -> Compiler, type_id -> Int) -> Bool {
    if (type_id == TYPE_NULLPTR || type_id == TYPE_ANYPTR) { return true; }

    if (type_id >= 100) {
        let key -> String = "" + type_id;
        let info -> SymbolInfo = c.ptr_base_map.get(key);
        if (info is !null) { return true; }
    }
    
    return false;
}

func is_fallible_type(c -> Compiler, type_id -> Int) -> Bool {
    if (type_id >= 100) {
        let key -> String = "" + type_id;
        let info -> SymbolInfo = c.fallible_base_map.get(key);
        if (info is !null) { return true; }
    }
    return false;
}

func is_error_type(c -> Compiler, type_id -> Int) -> Bool {
    if (type_id == TYPE_ANY_ERROR) { return true; }
    let info -> StructInfo = c.struct_id_map.get("" + type_id);
    return info is !null && info.is_enum && info.is_error;
}

func get_inner_fallible_type(c -> Compiler, type_id -> Int) -> Int {
    if (type_id >= 100) {
        let key -> String = "" + type_id;
        let info -> SymbolInfo = c.fallible_base_map.get(key);
        if (info is !null) { return info.type; }
    }
    return TYPE_POISON;
}

func is_void_ptr(c -> Compiler, type_id -> Int) -> Bool {
    if (type_id == TYPE_ANYPTR) { return true; }
    if (type_id >= 100) {
        let base_info -> SymbolInfo = c.ptr_base_map.get("" + type_id);
        if (base_info is !null && base_info.type == TYPE_VOID) {
            return true;
        }
    }
    return false;
}

func is_ref_type(c -> Compiler, type_id -> Int) -> Bool {
    if (type_id == TYPE_STRING) { return true; }
    if (type_id == TYPE_GENERIC_STRUCT) { return true; }
    if (type_id == TYPE_GENERIC_FUNCTION) { return true; }
    if (type_id == TYPE_GENERIC_CLASS) { return true; }
    if (type_id == TYPE_GENERIC_METHOD) { return true; }

    if (type_id >= 100) {
        let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
        if (arr_info is !null) { return arr_info.size == -1; }
        let s_info -> StructInfo = c.struct_id_map.get("" + type_id);
        if (s_info is !null) {
            if (s_info.is_enum) { return false; }
            return true;
        }
        if (c.vector_base_map.get("" + type_id) is !null) { return true; }
        if (c.func_ret_map.get("" + type_id) is !null) { return true; }
        if (c.method_ret_map.get("" + type_id) is !null) { return true; }
    }
    
    return false;
}

func needs_drop(c -> Compiler, type_id -> Int) -> Bool {
    if (is_ref_type(c, type_id)) { return true; }
    if (is_fallible_type(c, type_id)) {
        return needs_drop(c, get_inner_fallible_type(c, type_id));
    }
    let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
    if (arr_info is !null && arr_info.size >= 0) {
        return needs_drop(c, arr_info.base_type);
    }
    return false;
}

func result_owns_value(c -> Compiler, type_id -> Int) -> Bool {
    if (is_ref_type(c, type_id)) { return true; }
    if (is_fallible_type(c, type_id)) {
        return needs_drop(c, get_inner_fallible_type(c, type_id));
    }
    return false;
}


func is_signed_integer(t -> Int) -> Bool {
    return t == TYPE_INT || t == TYPE_LONG || 
           t == TYPE_INT8 || t == TYPE_INT16 || t == TYPE_INT128 || 
           t == TYPE_INTSIZE;
}

func is_unsigned_integer(t -> Int) -> Bool {
    return t == TYPE_BYTE || t == TYPE_CHAR || 
           t == TYPE_UINT16 || t == TYPE_UINT32 || t == TYPE_UINT64 || t == TYPE_UINT128 || 
           t == TYPE_UINTSIZE;
}

func is_integer_type(t -> Int) -> Bool {
// Checks if the type is an integer (int, long, byte, char, etc)

    return is_signed_integer(t) || is_unsigned_integer(t);
}

func is_numeric_type(t -> Int) -> Bool {
// Checks if the type is a number (integer or float)

    return is_integer_type(t) || t == TYPE_FLOAT || t == TYPE_FLOAT32;
}

func is_primitive_type(t -> Int) -> Bool {
// Checks if the type is a non-nullable value type stored directly on the stack or in registers.

    return is_numeric_type(t) || t == TYPE_BOOL || t == TYPE_ANY_ERROR;
}

func is_small_primitive_type(t -> Int) -> Bool {
// Checks if the type is smaller than 64 bits

    return t == TYPE_BOOL || 
           t == TYPE_BYTE || t == TYPE_CHAR || 
           t == TYPE_INT || t == TYPE_INT8 || t == TYPE_INT16 || 
           t == TYPE_UINT16 || t == TYPE_UINT32;
}

func is_nullable_reference_type(c -> Compiler, t -> Int) -> Bool {
    if (t == TYPE_STRING || t == TYPE_ANYPTR || t == TYPE_NULLPTR ||
        t == TYPE_GENERIC_STRUCT || t == TYPE_GENERIC_CLASS ||
        t == TYPE_GENERIC_FUNCTION || t == TYPE_GENERIC_METHOD) {
        return true;
    }

    if (t < 100) { return false; }
    let arr_info -> ArrayInfo = c.array_info_map.get("" + t);
    if (arr_info is !null) { return arr_info.size == -1; }
    if (c.fallible_base_map.get("" + t) is !null) { return false; }
    if (c.ptr_base_map.get("" + t) is !null) { return true; }
    if (c.vector_base_map.get("" + t) is !null) { return true; }
    if (c.func_ret_map.get("" + t) is !null) { return true; }
    if (c.method_ret_map.get("" + t) is !null) { return true; }

    let s_info -> StructInfo = c.struct_id_map.get("" + t);
    return s_info is !null && !s_info.is_enum;
}


func get_ptr_type_id(c -> Compiler, base_id -> Int) -> Int {
    let key -> String = "ptr_" + base_id;
    let cached -> SymbolInfo = c.ptr_cache.get(key);
    if (cached is !null) { return cached.type; }
    
    let new_id -> Int = c.type_counter;
    c.type_counter += 1;

    c.ptr_cache.put(key, SymbolInfo(reg="", type=new_id, origin_type=0));
    c.ptr_base_map.put("" + new_id, SymbolInfo(reg="", type=base_id));
    
    return new_id;
}

func get_fallible_type_id(c -> Compiler, base_id -> Int) -> Int {
    let key -> String = "" + base_id;
    let existing -> SymbolInfo = c.fallible_cache.get(key);
    if (existing is !null) {
        return existing.type;
    }
    
    let new_id -> Int = c.type_counter;
    c.type_counter += 1;
    
    let sym -> SymbolInfo = SymbolInfo(reg="", type=new_id, origin_type=0, is_const=false, func_arg_types=null);
    let base_sym -> SymbolInfo = SymbolInfo(reg="", type=base_id, origin_type=0, is_const=false, func_arg_types=null);
    
    c.fallible_cache.put(key, sym);
    c.fallible_base_map.put("" + new_id, base_sym);
    
    return new_id;
}

func get_func_type_id(c -> Compiler, arg_types -> Vector(Struct), ret_type_id -> Int) -> Int {
    let key -> String = "func_" + ret_type_id;
    let i -> Int = 0;
    while (i < arg_types.length()) { 
        let arg_node -> TypeListNode = arg_types[i];
        key += "_" + arg_node.type; 
        i += 1; 
    }
    
    let cached -> SymbolInfo = c.ptr_cache.get(key);
    if (cached is !null) { return cached.type; }
    let new_id -> Int = c.type_counter;
    c.type_counter += 1;

    c.func_ret_map.put("" + new_id, SymbolInfo(reg="", type=ret_type_id, origin_type=0, is_const=false, func_arg_types=arg_types));
    c.ptr_cache.put(key, SymbolInfo(reg="", type=new_id, origin_type=0, is_const=false, func_arg_types=arg_types));
    return new_id;
}

func get_method_type_id(c -> Compiler, arg_types -> Vector(Struct), ret_type_id -> Int) -> Int {
    let key -> String = "meth_" + ret_type_id;
    let i -> Int = 0;
    while (i < arg_types.length()) { 
        let arg_node -> TypeListNode = arg_types[i];
        key += "_" + arg_node.type; 
        i += 1; 
    }
    
    let cached -> SymbolInfo = c.ptr_cache.get(key);
    if (cached is !null) { return cached.type; }
    let new_id -> Int = c.type_counter;
    c.type_counter += 1;

    c.method_ret_map.put("" + new_id, SymbolInfo(reg="", type=ret_type_id, origin_type=0, is_const=false, func_arg_types=arg_types));
    c.ptr_cache.put(key, SymbolInfo(reg="", type=new_id, origin_type=0, is_const=false, func_arg_types=arg_types));
    return new_id;
}

func get_vector_type_id(c -> Compiler, base_id -> Int) -> Int {
    let key -> String = "vec_" + base_id;
    let cached -> SymbolInfo = c.vector_cache.get(key);
    if (cached is !null) { return cached.type; }
    
    let new_id -> Int = c.type_counter;
    c.type_drop_list.append(TypeListNode(type=new_id));
    c.type_counter += 1;

    c.vector_cache.put(key, SymbolInfo(reg="", type=new_id, origin_type=0));
    c.vector_base_map.put("" + new_id, SymbolInfo(reg="", type=base_id, origin_type=0));
    
    return new_id;
}

func get_slice_type_id(c -> Compiler, base_id -> Int) -> Int {
    let key -> String = "slice_" + base_id;
    let cached -> SymbolInfo = c.array_type_cache.get(key);
    if (cached is !null) { return cached.type; }

    let new_id -> Int = c.type_counter;
    c.type_counter += 1;

    let elem_ty -> String = get_llvm_type_str(c, base_id);
    let size_ty -> String = get_size_llvm_type();
    let slice_ty -> String = "{ " + size_ty + ", " + size_ty + ", i8*, " + elem_ty + "**, " + size_ty + "* }";
    c.array_type_cache.put(key, SymbolInfo(reg="", type=new_id, origin_type=0, is_const=false));
    c.array_info_map.put("" + new_id, ArrayInfo(base_type=base_id, size=-1, llvm_name=slice_ty));
    return new_id;
}

func get_builtin_cast_target(name -> String) -> Int {
    if (name == "Int" || name == "Int32") { return TYPE_INT; }
    if (name == "Long" || name == "Int64") { return TYPE_LONG; }
    if (name == "Float" || name == "Float64") { return TYPE_FLOAT; }
    if (name == "Byte" || name == "UInt8") { return TYPE_BYTE; }
    if (name == "Int8") { return TYPE_INT8; }
    if (name == "Int16") { return TYPE_INT16; }
    if (name == "Int128") { return TYPE_INT128; }
    if (name == "UInt16") { return TYPE_UINT16; }
    if (name == "UInt32") { return TYPE_UINT32; }
    if (name == "UInt64") { return TYPE_UINT64; }
    if (name == "UInt128") { return TYPE_UINT128; }
    if (name == "Float32") { return TYPE_FLOAT32; }
    if (name == "IntSize") { return TYPE_INTSIZE; }
    if (name == "UIntSize") { return TYPE_UINTSIZE; }
    if (name == "Bool") { return TYPE_BOOL; }
    if (name == "Char") { return TYPE_CHAR; }
    if (name == "AnyPtr") { return TYPE_ANYPTR; }
    if (name == "String") { return TYPE_STRING; }
    return 0;
}

func is_conversion_target(type_id -> Int) -> Bool {
    return is_numeric_type(type_id) || type_id == TYPE_BOOL ||
           type_id == TYPE_CHAR || type_id == TYPE_STRING;
}

func conversion_method_name(target_type -> Int) -> String {
    return "$type$" + target_type;
}

func method_base_name(c -> Compiler, node -> MethodDefNode) -> String {
    if (node.name_tok.value != "$type") { return node.name_tok.value; }

    let target_type -> Int = resolve_type(c, node.return_type);
    if (is_fallible_type(c, target_type)) {
        target_type = get_inner_fallible_type(c, target_type);
    }
    return conversion_method_name(target_type);
}

func find_class_conversion(info -> StructInfo, target_type -> Int) -> FuncInfo {
    if (info is null || !info.is_class || info.vtable is null) { return null; }

    let wanted -> String = conversion_method_name(target_type);
    let i -> Int = 0;
    while (i < info.vtable.length()) {
        let func_info -> FuncInfo = info.vtable[i];
        if (func_info.base_name == wanted) { return func_info; }
        i += 1;
    }
    return null;
}

func needs_explicit_cast(c -> Compiler, source_type -> Int, target_type -> Int) -> Bool {
    if (source_type == target_type) { return false; }
    if (source_type == TYPE_ANY_ERROR) { source_type = TYPE_INT; }
    let source_info -> StructInfo = c.struct_id_map.get("" + source_type);
    if (source_info is !null && source_info.is_enum) { source_type = TYPE_INT; }
    if (target_type == TYPE_BOOL) {
        return source_type != TYPE_BOOL;
    }
    if (target_type == TYPE_CHAR) {
        return source_type != TYPE_CHAR && source_type != TYPE_BOOL;
    }
    if (source_type == TYPE_BOOL) { return false; }

    let source_float -> Bool = source_type == TYPE_FLOAT || source_type == TYPE_FLOAT32;
    if (source_float && is_integer_type(target_type)) { return true; }
    if (!is_integer_type(source_type) || !is_integer_type(target_type)) { return false; }

    let source_bits -> Int = get_type_bitwidth(source_type);
    let target_bits -> Int = get_type_bitwidth(target_type);
    let source_unsigned -> Bool = is_unsigned_integer(source_type);
    let target_unsigned -> Bool = is_unsigned_integer(target_type);

    if (source_unsigned == target_unsigned) {
        return source_bits > target_bits;
    }
    if (source_unsigned) {
        return source_bits >= target_bits;
    }
    return true;
}

func get_expr_type(c -> Compiler, node -> Struct) -> Int {
    if (node is null) { return 0; }
    let base -> BaseNode = node;

    if (base.type == NODE_INT) { 
        let n -> IntNode = node;
        let raw_val -> String = n.tok.value;
        if (raw_val.ends_with("ULL") || raw_val.ends_with("ull")) { return TYPE_UINT128; }
        if (raw_val.ends_with("LL") || raw_val.ends_with("ll")) { return TYPE_INT128; }
        if (raw_val.ends_with("UL") || raw_val.ends_with("ul")) { return TYPE_UINT64; }
        if (raw_val.ends_with("U") || raw_val.ends_with("u")) { return TYPE_UINT32; }
        if (exceeds_64bit_range(raw_val)) { return TYPE_INT128; }
        
        let parsed_val -> Long = string_to_long(raw_val, n.pos);
        if (raw_val.ends_with("L") || raw_val.ends_with("l")) { return TYPE_LONG; }
        if (parsed_val < -2147483648L || parsed_val > 2147483647L) { return TYPE_LONG; }
        return TYPE_INT; 
    }
    if (base.type == NODE_STRING) { return TYPE_STRING; }
    if (base.type == NODE_CHAR) { return TYPE_CHAR; }
    if (base.type == NODE_FLOAT) {
        let fn -> FloatNode = node;
        let val_str -> String = fn.tok.value;
        if (val_str.ends_with("f") || val_str.ends_with("F")) {
            return TYPE_FLOAT32;
        }
        return TYPE_FLOAT;
    }
    if (base.type == NODE_BOOL) { return TYPE_BOOL; }
    if (base.type == NODE_TYPE_LAYOUT) { return TYPE_UINTSIZE; }
    
    if (base.type == NODE_VAR_ACCESS) {
        let v -> VarAccessNode = node;
        let info -> SymbolInfo = find_symbol(c, v.name_tok.value);
        if (info is !null) { return info.type; }

        let h_curr -> Scope = c.hoist_scope;
        while (h_curr is !null) {
            let h_info -> SymbolInfo = h_curr.table.get(v.name_tok.value);
            if (h_info is !null) { return h_info.type; }
            h_curr = h_curr.parent;
        }

        let f_info -> FuncInfo = c.func_table.get(v.name_tok.value);
        if (f_info is null && c.current_package_prefix != "") { f_info = c.func_table.get(c.current_package_prefix + v.name_tok.value); }
        if (f_info is !null) { return get_func_type_id(c, f_info.arg_types, f_info.ret_type); }

        return 0;
    }
    
    if (base.type == NODE_FIELD_ACCESS) {
        let f -> FieldAccessNode = node;
        let obj_type -> Int = get_expr_type(c, f.obj);
        if (is_pointer_type(c, obj_type)) {
            let base_info -> SymbolInfo = c.ptr_base_map.get("" + obj_type);
            if (base_info is !null) { obj_type = base_info.type; }
        }
        if (obj_type >= 100) {
            let s_info -> StructInfo = c.struct_id_map.get("" + obj_type);
            if (s_info is !null) {
                let field -> FieldInfo = find_field(s_info, f.field_name);
                if (field is !null) { return field.type; }
                if (s_info.is_class) {
                    let vtable -> Vector(Struct) = s_info.vtable;
                    let v_len -> Int = 0; if (vtable is !null) { v_len = vtable.length(); }
                    let m_idx -> Int = 0;
                    while (m_idx < v_len) {
                        let m_info -> FuncInfo = vtable[m_idx];
                        if (m_info.base_name == f.field_name) {
                            let bound_args -> Vector(Struct) = [];
                            let a_idx -> Int = 1;
                            while (a_idx < m_info.arg_types.length()) {
                                bound_args.append(m_info.arg_types[a_idx]);
                                a_idx += 1;
                            }
                            return get_method_type_id(c, bound_args, m_info.ret_type);
                        }
                        m_idx += 1;
                    }
                }
            }
        }

        let obj_base -> BaseNode = f.obj;
        if (obj_base.type == NODE_VAR_ACCESS) {
            let v_node -> VarAccessNode = f.obj;
            let target_name -> String = v_node.name_tok.value;
            if (c.current_package_prefix != "") {
                if (c.struct_table.get(c.current_package_prefix + target_name) is !null) {
                    target_name = c.current_package_prefix + target_name;
                }
            }
            let s_info -> StructInfo = c.struct_table.get(target_name);
            if (s_info is !null && s_info.is_enum) {
                return s_info.type_id;
            }
        }
        return 0;
    }
    
    if (base.type == NODE_INDEX_ACCESS) {
        let idx_node -> IndexAccessNode = node;
        let target_type -> Int = get_expr_type(c, idx_node.target);
        if (is_pointer_type(c, target_type) == true) {
            let base_info -> SymbolInfo = c.ptr_base_map.get("" + target_type);
            if (base_info is !null) { return base_info.type; }
        }
        if (target_type >= 100) {
            let v_info -> SymbolInfo = c.vector_base_map.get("" + target_type);
            if (v_info is !null) { return v_info.type; }
            let arr_info -> ArrayInfo = c.array_info_map.get("" + target_type);
            if (arr_info is !null) { return arr_info.base_type; }
            let s_info -> StructInfo = c.struct_id_map.get("" + target_type);
            if (s_info is !null && s_info.name == "Dict") { return TYPE_GENERIC_STRUCT; }
        }
        if (target_type == TYPE_STRING) { return TYPE_BYTE; }
        return 0;
    }

    if (base.type == NODE_REF) {
        let ref_node -> RefNode = node;
        let ref_base -> BaseNode = ref_node.node;
        if (ref_base.type == NODE_SLICE_ACCESS) {
            let slice_node -> SliceAccessNode = ref_node.node;
            let target_type -> Int = get_expr_type(c, slice_node.target);
            if (target_type == TYPE_STRING) { return TYPE_STRING; }

            let elem_type -> Int = 0;
            if (target_type >= 100) {
                let arr_info -> ArrayInfo = c.array_info_map.get("" + target_type);
                if (arr_info is !null) { elem_type = arr_info.base_type; }
                else {
                    let vec_info -> SymbolInfo = c.vector_base_map.get("" + target_type);
                    if (vec_info is !null) { elem_type = vec_info.type; }
                }
            }
            if (elem_type != 0) { return get_slice_type_id(c, elem_type); }
            return 0;
        }
        let base_type -> Int = get_expr_type(c, ref_node.node);
        if (base_type != 0) { return get_ptr_type_id(c, base_type); }
        return 0;
    }

    if (base.type == NODE_DEREF) {
        let deref_node -> DerefNode = node;
        let ptr_type -> Int = get_expr_type(c, deref_node.node);
        if (is_pointer_type(c, ptr_type)) {
            let base_info -> SymbolInfo = c.ptr_base_map.get("" + ptr_type);
            if (base_info is !null) { return base_info.type; }
        }
        return 0;
    }

    if (base.type == NODE_SLICE_ACCESS) {
        let slice_node -> SliceAccessNode = node;
        let target_type -> Int = get_expr_type(c, slice_node.target);
        if (target_type == TYPE_STRING) { return TYPE_STRING; }

        let elem_type -> Int = 0;
        if (target_type >= 100) {
            let arr_info -> ArrayInfo = c.array_info_map.get("" + target_type);
            if (arr_info is !null) { elem_type = arr_info.base_type; }
            else {
                let v_info -> SymbolInfo = c.vector_base_map.get("" + target_type);
                if (v_info is !null) { elem_type = v_info.type; }
            }
        }
        
        if (elem_type != 0) {
            return get_slice_type_id(c, elem_type);
        }
        return 0;
    }

    if (base.type == NODE_TRY_UNWRAP) {
        let t_node -> TryUnwrapNode = node;
        let base_type -> Int = get_expr_type(c, t_node.expr);
        if (is_fallible_type(c, base_type)) {
            return get_inner_fallible_type(c, base_type);
        }
        let expr_base -> BaseNode = t_node.expr;
        if (expr_base.type == NODE_CALL) {
            let call -> CallNode = t_node.expr;
            let callee_base -> BaseNode = call.callee;
            if (callee_base.type == NODE_VAR_ACCESS) {
                let callee -> VarAccessNode = call.callee;
                let target_type -> Int = get_builtin_cast_target(callee.name_tok.value);
                if (target_type != 0) {
                    throw_invalid_syntax(t_node.pos, "conversion to " + get_type_name(c, target_type) + " cannot fail; remove '?'");
                    return 0;
                }
            }
        }
        throw_invalid_syntax(t_node.pos, "Cannot use '?' on a non-fallible type.");
        return 0;
    }

    if (base.type == NODE_CALL) {
        let call_node -> CallNode = node;
        let callee -> BaseNode = call_node.callee;
        if (callee.type == NODE_VAR_ACCESS) {
            let v -> VarAccessNode = call_node.callee;
            let callee_name -> String = v.name_tok.value;

            let cast_target -> Int = get_builtin_cast_target(callee_name);
            if (cast_target != 0) {
                let args -> Vector(Struct) = call_node.args;
                if (args is !null && args.length() == 1) {
                    let arg -> ArgNode = args[0];
                    let source_type -> Int = get_expr_type(c, arg.val);
                    let source_info -> StructInfo = c.struct_id_map.get("" + source_type);
                    let conversion -> FuncInfo = find_class_conversion(source_info, cast_target);
                    if (conversion is !null) {
                        if (call_node.preserve_fallible) { return conversion.ret_type; }
                        if (is_fallible_type(c, conversion.ret_type)) {
                            return get_inner_fallible_type(c, conversion.ret_type);
                        }
                        return conversion.ret_type;
                    }
                    if (call_node.preserve_fallible && needs_explicit_cast(c, source_type, cast_target)) {
                        return get_fallible_type_id(c, cast_target);
                    }
                }
                return cast_target;
            }

            let f_info -> FuncInfo = c.func_table.get(callee_name);
            if (f_info is null && c.current_package_prefix != "") { f_info = c.func_table.get(c.current_package_prefix + callee_name); }
            if (f_info is !null) { return f_info.ret_type; }

            let s_info -> StructInfo = c.struct_table.get(callee_name);
            if (s_info is null && c.current_package_prefix != "") { s_info = c.struct_table.get(c.current_package_prefix + callee_name); }
            if (s_info is !null) { return s_info.type_id; }

            let var_info -> SymbolInfo = find_symbol(c, callee_name);
            if (var_info is !null) {
                let p_type -> Int = var_info.type;
                let f_ret_info -> SymbolInfo = c.func_ret_map.get("" + p_type);
                if (f_ret_info is !null) { return f_ret_info.type; }
                let m_ret_info -> SymbolInfo = c.method_ret_map.get("" + p_type);
                if (m_ret_info is !null) { return m_ret_info.type; }
            }
        }
        else if (callee.type == NODE_FIELD_ACCESS) {
            let f -> FieldAccessNode = call_node.callee;
            let obj_type -> Int = get_expr_type(c, f.obj);
            if (obj_type == 0) {
                let path_parts -> Vector(String) = [];
                let curr_obj -> Struct = f.obj;
                let curr_base -> BaseNode = curr_obj;
                while (curr_base.type == NODE_FIELD_ACCESS) {
                    let inner_f -> FieldAccessNode = curr_obj;
                    path_parts.append(inner_f.field_name);
                    curr_obj = inner_f.obj;
                    curr_base = curr_obj;
                }
                if (curr_base.type == NODE_VAR_ACCESS) {
                    let inner_v -> VarAccessNode = curr_obj;
                    let root_name -> String = inner_v.name_tok.value;
                    if (find_symbol(c, root_name) is null) {
                        let full_name -> String = "";
                        let module_prefix -> String = c.current_file_visible_prefixes.get(root_name);
                        if (module_prefix is !null) {
                            full_name = module_member_name(module_prefix, path_parts, f.field_name);
                        } else {
                            let source_name -> String = module_member_name(root_name + ".", path_parts, f.field_name);
                            let mapped_func -> String = c.current_file_func_aliases.get(source_name);
                            if (mapped_func is !null) { full_name = mapped_func; }
                        }
                        let g_alias_f -> String = c.global_func_aliases.get(full_name);
                        if (g_alias_f is !null) { full_name = g_alias_f; }
                        
                        let f_info -> FuncInfo = c.func_table.get(full_name);
                        if (f_info is !null) { return f_info.ret_type; }
                    }
                }
            }

            if (is_pointer_type(c, obj_type)) {
                let base_info -> SymbolInfo = c.ptr_base_map.get("" + obj_type);
                if (base_info is !null) { obj_type = base_info.type; }
            }

            if (obj_type == TYPE_STRING) {
                let str_link -> String = c.compiler_link.get("string_" + f.field_name);
                if (str_link is !null) {
                    let f_info -> FuncInfo = c.func_table.get(str_link);
                    if (f_info is !null) { return f_info.ret_type; }
                }
            }

            if (f.field_name == "length") { return TYPE_INT; }
            if (f.field_name == "append") { return TYPE_VOID; }
            if (f.field_name == "drop") {
                if (obj_type >= 100) {
                    let v_info -> SymbolInfo = c.vector_base_map.get("" + obj_type);
                    if (v_info is !null) { return v_info.type; }
                }
                return 0;
            }

            if (obj_type >= 100) {
                let s_info -> StructInfo = c.struct_id_map.get("" + obj_type);
                if (s_info is !null && s_info.is_class) {
                    let vtable -> Vector(Struct) = s_info.vtable;
                    let v_len -> Int = 0; if (vtable is !null) { v_len = vtable.length(); }
                    let m_idx -> Int = 0;
                    while (m_idx < v_len) {
                        let m_info -> FuncInfo = vtable[m_idx];
                        if (m_info.base_name == f.field_name) {
                            return m_info.ret_type;
                        }
                        m_idx += 1;
                    }
                } else if (s_info is !null && s_info.is_interface) {
                    let vtable -> Vector(Struct) = s_info.vtable;
                    let v_len -> Int = 0; if (vtable is !null) { v_len = vtable.length(); }
                    let m_idx -> Int = 0;
                    while (m_idx < v_len) {
                        let m_node -> MethodDefNode = vtable[m_idx];
                        if (m_node.name_tok.value == f.field_name) {
                            return resolve_type(c, m_node.return_type);
                        }
                        m_idx += 1;
                    }
                }
            }
        }
        let ptr_type -> Int = get_expr_type(c, callee);
        if (ptr_type != 0) {
            let f_ret_info -> SymbolInfo = c.func_ret_map.get("" + ptr_type);
            if (f_ret_info is !null) { return f_ret_info.type; }
            let m_ret_info -> SymbolInfo = c.method_ret_map.get("" + ptr_type);
            if (m_ret_info is !null) { return m_ret_info.type; }
        }

        return 0;
    }

    if (base.type == NODE_VECTOR_LIT) {
        let vec_node -> VectorLitNode = node;
        if (vec_node.count > 0) {
            let arg -> ArgNode = vec_node.elements[0];
            let elem_type -> Int = get_expr_type(c, arg.val);
            if (elem_type != 0) { 
                let v_id -> Int = get_vector_type_id(c, elem_type); 
                return v_id;
            }
        }
        return 0;
    }

    if (base.type == NODE_MAP_LIT) {
        let s_info -> StructInfo = c.struct_table.get("Dict");
        if (s_info is !null) { return s_info.type_id; }
        return 0;
    }

    if (base.type == NODE_BINOP) {
        let b -> BinOpNode = node;
        let op -> Int = b.op_tok.type;

        if (op == WhitelangTokens.TOK_EE || op == WhitelangTokens.TOK_NE || op == WhitelangTokens.TOK_LT || 
            op == WhitelangTokens.TOK_GT || op == WhitelangTokens.TOK_LTE || op == WhitelangTokens.TOK_GTE || 
            op == WhitelangTokens.TOK_AND || op == WhitelangTokens.TOK_OR || op == WhitelangTokens.TOK_IS) {
            return TYPE_BOOL;
        }

        let left_ty -> Int = get_expr_type(c, b.left);
        let right_ty -> Int = get_expr_type(c, b.right);

        if (left_ty == TYPE_STRING || right_ty == TYPE_STRING) { return TYPE_STRING; }
        if (left_ty == TYPE_CHAR && right_ty == TYPE_CHAR && op == WhitelangTokens.TOK_PLUS) { return TYPE_STRING; }

        if (left_ty == TYPE_FLOAT || right_ty == TYPE_FLOAT) { return TYPE_FLOAT; }
        if (left_ty == TYPE_FLOAT32 || right_ty == TYPE_FLOAT32) { return TYPE_FLOAT32; }
        if (is_integer_type(left_ty) && is_integer_type(right_ty)) {
            let left_bits -> Int = get_type_bitwidth(left_ty);
            let right_bits -> Int = get_type_bitwidth(right_ty);
            if (right_bits > left_bits) { return right_ty; }
            if (left_bits > right_bits) { return left_ty; }
            if (is_unsigned_integer(right_ty)) { return right_ty; }
        }
        
        return left_ty;
    }

    if (base.type == NODE_UNARYOP) {
        let u -> UnaryOpNode = node;
        let op -> Int = u.op_tok.type;
        if (op == WhitelangTokens.TOK_NOT) { return TYPE_BOOL; }

        return get_expr_type(c, u.node); 
    }

    return 0;
}

func get_type_bitwidth(t -> Int) -> Int {
    if (t == TYPE_BOOL) { return 1; }
    if (t == TYPE_BYTE || t == TYPE_INT8) { return 8; }
    if (t == TYPE_INT16 || t == TYPE_UINT16) { return 16; }
    if (t == TYPE_INT || t == TYPE_UINT32 || t == TYPE_CHAR || t == TYPE_FLOAT32) { return 32; }
    if (t == TYPE_INTSIZE || t == TYPE_UINTSIZE) { return get_target_pointer_bits(); }
    if (t == TYPE_LONG || t == TYPE_UINT64 || t == TYPE_FLOAT) { return 64; }
    if (t == TYPE_INT128 || t == TYPE_UINT128) { return 128; }
    return get_target_pointer_bits(); // fallback for pointer-backed values
}

func get_type_size_bytes(c -> Compiler, type_id -> Int) -> Int {
// return the in-memory size used by contiguous containers
    if (type_id == TYPE_BOOL || type_id == TYPE_BYTE || type_id == TYPE_INT8) { return 1; }
    if (type_id == TYPE_INT16 || type_id == TYPE_UINT16) { return 2; }
    if (type_id == TYPE_INT || type_id == TYPE_UINT32 || type_id == TYPE_CHAR || type_id == TYPE_FLOAT32 || type_id == TYPE_GENERIC_ENUM) { return 4; }
    if (type_id == TYPE_INT128 || type_id == TYPE_UINT128) { return 16; }
    if (type_id == TYPE_INTSIZE || type_id == TYPE_UINTSIZE) { return get_pointer_size_bytes(); }
    if (type_id == TYPE_LONG || type_id == TYPE_UINT64 || type_id == TYPE_FLOAT) { return 8; }
    if (type_id == TYPE_ANY_ERROR) { return any_error_size(); }

    let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
    if (arr_info is !null) {
        if (arr_info.size < 0) { return get_pointer_size_bytes(); }
        return arr_info.size * get_type_size_bytes(c, arr_info.base_type);
    }

    let struct_info -> StructInfo = c.struct_id_map.get("" + type_id);
    if (struct_info is !null && struct_info.is_interface) { return get_pointer_size_bytes() * 2; }

    let fallible_info -> SymbolInfo = c.fallible_base_map.get("" + type_id);
    if (fallible_info is !null) {
        let error_align -> Int = any_error_align();
        let offset -> Int = align_to(1, error_align) + any_error_size();
        let layout_align -> Int = error_align;
        if (fallible_info.type != TYPE_VOID) {
            let value_align -> Int = get_type_align_bytes(c, fallible_info.type);
            offset = align_to(offset, value_align);
            offset += get_type_size_bytes(c, fallible_info.type);
            if (value_align > layout_align) { layout_align = value_align; }
        }
        return align_to(offset, layout_align);
    }

    return get_pointer_size_bytes();
}

func get_type_align_bytes(c -> Compiler, type_id -> Int) -> Int {
    if (type_id == TYPE_BOOL || type_id == TYPE_BYTE || type_id == TYPE_INT8) { return 1; }
    if (type_id == TYPE_INT16 || type_id == TYPE_UINT16) { return 2; }
    if (type_id == TYPE_INT || type_id == TYPE_UINT32 || type_id == TYPE_CHAR || type_id == TYPE_FLOAT32 || type_id == TYPE_GENERIC_ENUM) { return 4; }
    if (type_id == TYPE_INT128 || type_id == TYPE_UINT128) { return 16; }
    if (type_id == TYPE_INTSIZE || type_id == TYPE_UINTSIZE) { return get_pointer_size_bytes(); }
    if (type_id == TYPE_LONG || type_id == TYPE_UINT64 || type_id == TYPE_FLOAT || type_id == TYPE_ANY_ERROR) { return target_i64_align(); }

    let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
    if (arr_info is !null) {
        if (arr_info.size < 0) { return get_pointer_size_bytes(); }
        return get_type_align_bytes(c, arr_info.base_type);
    }

    let fallible_info -> SymbolInfo = c.fallible_base_map.get("" + type_id);
    if (fallible_info is !null) {
        let result -> Int = any_error_align();
        if (fallible_info.type != TYPE_VOID) {
            let value_align -> Int = get_type_align_bytes(c, fallible_info.type);
            if (value_align > result) { result = value_align; }
        }
        return result;
    }
    return get_pointer_size_bytes();
}

func get_signed_min_literal(type_id -> Int) -> String {
    if (type_id == TYPE_INT8) { return "-128"; }
    if (type_id == TYPE_INT16) { return "-32768"; }
    if (type_id == TYPE_INT) { return "-2147483648"; }
    if (type_id == TYPE_INTSIZE && get_target_pointer_bits() == 32) { return "-2147483648"; }
    if (type_id == TYPE_LONG || type_id == TYPE_INTSIZE) { return "-9223372036854775808"; }
    if (type_id == TYPE_INT128) { return "-170141183460469231731687303715884105728"; }
    return "";
}

func resolve_type(c -> Compiler, node -> Struct) -> Int {
    if (node is null) { return TYPE_VOID; }
    let base -> BaseNode = node;

    if (base.type == NODE_FUNCTION_TYPE) {
        let f_node -> FunctionTypeNode = node;
        let ret_id -> Int = resolve_type(c, f_node.return_type);
        let arg_types -> Vector(Struct) = [];
        let i -> Int = 0;
        let p_len -> Int = 0; if (f_node.arg_types is !null) { p_len = f_node.arg_types.length(); }
        while (i < p_len) {
            arg_types.append(TypeListNode(type=resolve_type(c, f_node.arg_types[i])));
            i += 1;
        }
        return get_func_type_id(c, arg_types, ret_id);
    }
    if (base.type == NODE_METHOD_TYPE) {
        let m_node -> MethodTypeNode = node;
        let ret_id -> Int = resolve_type(c, m_node.return_type);
        let arg_types -> Vector(Struct) = [];
        let i -> Int = 0;
        let p_len -> Int = 0; if (m_node.arg_types is !null) { p_len = m_node.arg_types.length(); }
        while (i < p_len) {
            arg_types.append(TypeListNode(type=resolve_type(c, m_node.arg_types[i])));
            i += 1;
        }
        return get_method_type_id(c, arg_types, ret_id);
    }
    if (base.type == NODE_FALLIBLE_TYPE) {
        let fll_node -> FallibleTypeNode = node;
        let base_id -> Int = resolve_type(c, fll_node.base_type);
        if (is_fallible_type(c, base_id)) {
            throw_type_error(fll_node.pos, "Cannot create a nested fallible type (e.g. T??).");
        }
        return get_fallible_type_id(c, base_id);
    }

    // Pointer Type (ptr*N Type)
    if (base.type == NODE_PTR_TYPE) {
        let p_node -> PointerTypeNode = node;
        let inner_base -> BaseNode = p_node.base_type;

        if (inner_base.type == NODE_ARRAY_TYPE) {
            let arr_node -> ArrayTypeNode = p_node.base_type;

            let fake_ptr -> PointerTypeNode = PointerTypeNode(
                type=p_node.type,
                base_type=arr_node.base_type,
                level=p_node.level,
                pos=p_node.pos
            );
            
            let fake_arr -> ArrayTypeNode = ArrayTypeNode(
                type=arr_node.type,
                base_type=fake_ptr,
                size_tok=arr_node.size_tok,
                pos=arr_node.pos
            );
            
            return resolve_type(c, fake_arr);
        }

        let base_id -> Int = resolve_type(c, p_node.base_type);

        if (base_id == TYPE_VOID) {
            throw_type_error(p_node.pos, "Cannot create a pointer to 'Void' (it has no size and no value), use 'AnyPtr' instead.");
            return TYPE_ANYPTR;
        }
        
        let current_id -> Int = base_id;
        let i -> Int = 0;
        while (i < p_node.level) {
            current_id = get_ptr_type_id(c, current_id);
            i += 1;
        }
        return current_id;
    }

    // Vector
    if (base.type == NODE_VECTOR_TYPE) {
        let v_node -> VectorTypeNode = node;
        let elem_id -> Int = resolve_type(c, v_node.element_type);
        return get_vector_type_id(c, elem_id);
    }

    if (base.type == NODE_ARRAY_TYPE) {
        let arr_node -> ArrayTypeNode = node;
        let base_id -> Int = resolve_type(c, arr_node.base_type);

        let parsed_size -> Long = string_to_long(arr_node.size_tok.value, arr_node.pos);
        if (parsed_size < 0L || parsed_size > 2147483647L) {
            throw_overflow_error(arr_node.pos, "Array size overflows maximum allowed 32-bit limit.");
            return 0;
        }

        let size -> Int = string_to_int(arr_node.size_tok.value, arr_node.pos);

        let cache_key -> String = "arr_" + base_id + "_" + size;
        let cached -> SymbolInfo = c.array_type_cache.get(cache_key);
        
        if (cached is !null) {
            return cached.type;
        }
        
        let new_id -> Int = c.type_counter;
        c.type_counter += 1;
        
        c.array_type_cache.put(cache_key, SymbolInfo(reg="", type=new_id, origin_type=0, is_const=false));
        
        let llvm_name -> String = "[" + size + " x " + get_llvm_type_str(c, base_id) + "]";
        c.array_info_map.put("" + new_id, ArrayInfo(base_type=base_id, size=size, llvm_name=llvm_name));
        
        return new_id;
    }

    if (base.type == NODE_SLICE_TYPE) {
        let s_node -> SliceTypeNode = node;
        let elem_id -> Int = resolve_type(c, s_node.element_type);
        return get_slice_type_id(c, elem_id);
    }
    
    // Named Type (Int, Float, StructName)
    if (base.type == NODE_VAR_ACCESS) {
        let v -> VarAccessNode = node;
        let name -> String = v.name_tok.value;

        if (name == "Int" || name == "Int32") { return TYPE_INT; }
        if (name == "Long" || name == "Int64") { return TYPE_LONG; }
        if (name == "Float" || name == "Float64") { return TYPE_FLOAT; }
        if (name == "Byte" || name == "UInt8") { return TYPE_BYTE; }

        if (name == "Int8") { return TYPE_INT8; }
        if (name == "Int16") { return TYPE_INT16; }
        if (name == "Int128") { return TYPE_INT128; }
        if (name == "UInt16") { return TYPE_UINT16; }
        if (name == "UInt32") { return TYPE_UINT32; }
        if (name == "UInt64") { return TYPE_UINT64; }
        if (name == "UInt128") { return TYPE_UINT128; }
        if (name == "Float32") { return TYPE_FLOAT32; }
        if (name == "IntSize") { return TYPE_INTSIZE; }
        if (name == "UIntSize") { return TYPE_UINTSIZE; }

        if (name == "Bool") { return TYPE_BOOL; }
        if (name == "String") { return TYPE_STRING; }
        if (name == "Char") { return TYPE_CHAR; }
        if (name == "Void") { return TYPE_VOID; }
        if (name == "Struct") { return TYPE_GENERIC_STRUCT; }
        if (name == "Function") { return TYPE_GENERIC_FUNCTION; }
        if (name == "Class") { return TYPE_GENERIC_CLASS; }
        if (name == "Method") { return TYPE_GENERIC_METHOD; }
        if (name == "Enum") { return TYPE_GENERIC_ENUM; }
        if (name == "Auto") { return TYPE_AUTO; }
        if (name == "AnyPtr") { return TYPE_ANYPTR; }

        let internal_info -> StructInfo = c.struct_table.get(c.current_package_prefix + name);
        if (internal_info is !null) { return internal_info.type_id; }

        let full_name -> String = c.current_file_type_aliases.get(name);
        if (full_name is !null) {
            let s_info -> StructInfo = c.struct_table.get(full_name);
            if (s_info is !null) { return s_info.type_id; }
        }

        let s_info -> StructInfo = c.struct_table.get(name);
        if (s_info is !null) { return s_info.type_id; }
        
        let local_alias -> String = c.current_file_type_aliases.get(name);
        if (local_alias is !null) {
            let s_info -> StructInfo = c.struct_table.get(local_alias);
            if (s_info is !null) { return s_info.type_id; }
        }

        let g_alias -> String = c.global_type_aliases.get(name);
        if (g_alias is !null) {
            let s_info -> StructInfo = c.struct_table.get(g_alias);
            if (s_info is !null) { return s_info.type_id; }
        }

        throw_type_error(v.pos, "Unknown type: " + name);
    }

    if (base.type == NODE_FIELD_ACCESS) {
        let f_acc -> FieldAccessNode = node;
        let path_parts -> Vector(String) = [];
        let curr_obj -> Struct = f_acc.obj;
        let curr_base -> BaseNode = curr_obj;
        while (curr_base.type == NODE_FIELD_ACCESS) {
            let inner_f -> FieldAccessNode = curr_obj;
            path_parts.append(inner_f.field_name);
            curr_obj = inner_f.obj;
            curr_base = curr_obj;
        }
        if (curr_base.type == NODE_VAR_ACCESS) {
            let pkg_node -> VarAccessNode = curr_obj;
            let pkg_name -> String = pkg_node.name_tok.value;
            let type_name -> String = f_acc.field_name;
            if (type_name.starts_with("__")) {
                if (!c.is_precompile_phase) {
                    throw_type_error(f_acc.pos, "Unknown module type: " + pkg_name + "." + type_name);
                }
                return TYPE_POISON;
            }

            let full_name -> String = "";
            let module_prefix -> String = c.current_file_visible_prefixes.get(pkg_name);
            if (module_prefix is !null) {
                full_name = module_member_name(module_prefix, path_parts, type_name);
            } else {
                let source_name -> String = module_member_name(pkg_name + ".", path_parts, type_name);
                let mapped_type -> String = c.current_file_type_aliases.get(source_name);
                if (mapped_type is !null) { full_name = mapped_type; }
            }

            let s_info -> StructInfo = c.struct_table.get(full_name);
            if (s_info is !null) { return s_info.type_id; }
            
            let g_alias -> String = c.global_type_aliases.get(full_name);
            if (g_alias is !null) {
                let type_s_info -> StructInfo = c.struct_table.get(g_alias);
                if (type_s_info is !null) { return type_s_info.type_id; }
            }
            
            throw_type_error(f_acc.pos, "Unknown module type: " + full_name);
        }
    }
    
    return TYPE_POISON;
}

func get_func_sig_str(c -> Compiler, info -> FuncInfo) -> String {
    let ret_str -> String = get_llvm_type_str(c, info.ret_type);
    let args_str -> String = "";
    let arg_types -> Vector(Struct) = info.arg_types;
    let len -> Int = 0; if (arg_types is !null) { len = arg_types.length(); }
    let i -> Int = 0;
    
    while (i < len) {
        let curr -> TypeListNode = arg_types[i];
        if (i > 0) { args_str = args_str + ", "; }
        args_str += get_llvm_type_str(c, curr.type);
        i += 1;
    }

    if (info.is_varargs) {
        if (len > 0) { args_str = args_str + ", ..."; }
        else { args_str = "..."; }
    }
    
    return ret_str + " (" + args_str + ")*";
}

func get_method_def_sig_str(c -> Compiler, m_node -> MethodDefNode) -> String {
    let ret_type -> Int = resolve_type(c, m_node.return_type);
    let ret_str -> String = get_llvm_type_str(c, ret_type);
    let args_str -> String = "i8*"; // Self pointer is always i8* for interfaces
    
    let params -> Vector(Struct) = m_node.params;
    let len -> Int = 0; if (params is !null) { len = params.length(); }
    let i -> Int = 0;
    
    while (i < len) {
        let p_node -> ParamNode = params[i];
        let p_type -> Int = resolve_type(c, p_node.type_tok);
        args_str = args_str + ", " + get_llvm_type_str(c, p_type);
        i += 1;
    }
    
    return ret_str + " (" + args_str + ")*";
}

func mangle_type(c -> Compiler, type_id -> Int) -> String {
    if (type_id == TYPE_VOID) { return "v"; }
    if (type_id == TYPE_BOOL) { return "b"; }
    if (type_id == TYPE_INT8) { return "a"; }
    if (type_id == TYPE_INT16) { return "s"; }
    if (type_id == TYPE_INT) { return "i"; }
    if (type_id == TYPE_LONG) { return "x"; }
    if (type_id == TYPE_INT128) { return "n"; }
    if (type_id == TYPE_BYTE) { return "h"; }
    if (type_id == TYPE_UINT16) { return "t"; }
    if (type_id == TYPE_UINT32) { return "j"; }
    if (type_id == TYPE_UINT64) { return "y"; }
    if (type_id == TYPE_UINT128) { return "o"; }
    if (type_id == TYPE_FLOAT32) { return "f"; }
    if (type_id == TYPE_FLOAT) { return "d"; }
    if (type_id == TYPE_CHAR) { return "w"; }
    if (type_id == TYPE_INTSIZE) { return "l"; }
    if (type_id == TYPE_UINTSIZE) { return "m"; }
    if (type_id == TYPE_STRING) { return "S"; }
    if (type_id == TYPE_ANYPTR) { return "Pv"; }
    if (type_id == TYPE_ANY_ERROR) { return "E"; }
    if (type_id == TYPE_GENERIC_STRUCT) { return "Gs"; }
    if (type_id == TYPE_GENERIC_CLASS) { return "Gc"; }
    if (type_id == TYPE_GENERIC_FUNCTION) { return "Gf"; }
    if (type_id == TYPE_GENERIC_METHOD) { return "Gm"; }
    if (type_id == TYPE_GENERIC_ENUM) { return "Ge"; }

    let ptr_info -> SymbolInfo = c.ptr_base_map.get("" + type_id);
    if (ptr_info is !null) {
        return "P" + mangle_type(c, ptr_info.type);
    }

    let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
    if (arr_info is !null) {
        if (arr_info.size == -1) {
            return "Q" + mangle_type(c, arr_info.base_type);
        }
        return "A" + arr_info.size + "_" + mangle_type(c, arr_info.base_type);
    }

    let vec_info -> SymbolInfo = c.vector_base_map.get("" + type_id);
    if (vec_info is !null) {
        return "V" + mangle_type(c, vec_info.type);
    }

    let fallible_info -> SymbolInfo = c.fallible_base_map.get("" + type_id);
    if (fallible_info is !null) {
        return "R" + mangle_type(c, fallible_info.type);
    }

    let func_info -> SymbolInfo = c.func_ret_map.get("" + type_id);
    if (func_info is !null) {
        let encoded -> String = "F";
        let args -> Vector(Struct) = func_info.func_arg_types;
        let len -> Int = 0; if (args is !null) { len = args.length(); }
        let i -> Int = 0;
        while (i < len) {
            let arg -> TypeListNode = args[i];
            encoded += mangle_type(c, arg.type);
            i += 1;
        }
        return encoded + "E" + mangle_type(c, func_info.type);
    }

    let method_info -> SymbolInfo = c.method_ret_map.get("" + type_id);
    if (method_info is !null) {
        let encoded -> String = "M";
        let args -> Vector(Struct) = method_info.func_arg_types;
        let len -> Int = 0; if (args is !null) { len = args.length(); }
        let i -> Int = 0;
        while (i < len) {
            let arg -> TypeListNode = args[i];
            encoded += mangle_type(c, arg.type);
            i += 1;
        }
        return encoded + "E" + mangle_type(c, method_info.type);
    }

    let struct_info -> StructInfo = c.struct_id_map.get("" + type_id);
    if (struct_info is !null) {
        return "N" + struct_info.name.length() + struct_info.name + "E";
    }

    throw_internal_compiler_error(null, "Cannot mangle unknown type id " + type_id + ".");
    return "v";
}

func mangle_wl_name(c -> Compiler, prefix -> String, base_name -> String, arg_types -> Vector(Struct)) -> String {
    if (base_name == "main" && prefix == "") { return "main"; }
    
    let mangled -> String = "_WL";

    if (prefix != "") {
        let clean_prefix -> String = prefix.slice(0, prefix.length() - 1);
        mangled += "" + clean_prefix.length() + clean_prefix;
    }

    mangled += "" + base_name.length() + base_name;

    let len -> Int = 0; if (arg_types is !null) { len = arg_types.length(); }
    if (len == 0) { return mangled + "v"; }
    
    let i -> Int = 0;
    while (i < len) {
        let t_node -> TypeListNode = arg_types[i];
        mangled += mangle_type(c, t_node.type);
        i += 1;
    }
    return mangled;
}

func get_mangled_symbol(c -> Compiler, link_name -> String, pos -> Position) -> String {
    let func_key -> String = c.compiler_link.get(link_name);
    let name -> String = null;
    
    if (func_key is !null) {
        let f_info -> FuncInfo = c.func_table.get(func_key);
        if (f_info is !null) {
            name = f_info.name;
        }
    }

    if (name is null && pos is !null) {
        throw_type_error(pos, "Missing CompilerLink hook '" + link_name + "'. Did you import 'builtin'?");
        return "__wl_missing_hook";
    }

    return name;
}

func consume_annotations(anns -> Vector(Struct), default_name -> String) -> SystemAnnResult {
    let res -> SystemAnnResult = SystemAnnResult(ann_flags=0, compiler_link_name="", intrinsic_name="");
    if (anns is null) { return res; }
    
    let len -> Int = anns.length();
    let i -> Int = 0;
    while (i < len) {
        let ann_node -> AnnotationNode = anns[i];
        let name -> String = ann_node.name;
        
        if (name == "ExportLib") {
            if (ann_node.args is !null && ann_node.args.length() > 0) {
                throw_invalid_syntax(ann_node.pos, "@" + name + " annotation cannot have arguments.");
            }
            res.ann_flags = res.ann_flags | FLAG_ANN_EXPORT;
        } else if (name == "CompilerIntrinsic") {
            let arg_count -> Int = 0;
            if (ann_node.args is !null) { arg_count = ann_node.args.length(); }
            if (arg_count > 1) {
                throw_invalid_syntax(ann_node.pos, "@CompilerIntrinsic accepts at most one string literal argument.");
            } else if (arg_count == 1) {
                let a_node -> ArgNode = ann_node.args[0];
                let base_val -> BaseNode = a_node.val;
                if (base_val is null || base_val.type != NODE_STRING) {
                    throw_invalid_syntax(ann_node.pos, "@CompilerIntrinsic argument must be a string literal.");
                } else {
                    let str_node -> StringNode = a_node.val;
                    res.intrinsic_name = str_node.tok.value;
                }
            }
            res.ann_flags = res.ann_flags | FLAG_ANN_INTRINSIC;
        } else if (name == "CompilerLink") {
            let link_name -> String = default_name;
            if (ann_node.args is !null && ann_node.args.length() > 0) {
                let a_node -> ArgNode = ann_node.args[0];
                let base_val -> BaseNode = a_node.val;
                if (base_val is null || base_val.type != NODE_STRING) {
                    throw_invalid_syntax(ann_node.pos, "@CompilerLink argument must be a string literal.");
                } else {
                    let str_node -> StringNode = a_node.val;
                    link_name = str_node.tok.value;
                }
            }
            res.compiler_link_name = link_name;
            res.ann_flags = res.ann_flags | FLAG_ANN_COMP_LINK;
        } else {
            throw_type_error(ann_node.pos, "Unknown system annotation: @" + name + ". User-defined annotations are not supported.");
        }
        i += 1;
    }
    return res;
}

func string_to_int(val_str -> String, pos -> Position) -> Int {
    let len -> Int = val_str.length();
    if (len == 0) { return 0; }
    let start -> Int = 0; let is_neg -> Bool = false;
    if (val_str[0] == '-') { start = 1; is_neg = true; }
    let end -> Int = len;
    if (val_str.ends_with("ULL") || val_str.ends_with("ull")) {
        end = len - 3;
    } else if (val_str.ends_with("LL") || val_str.ends_with("ll") || val_str.ends_with("UL") || val_str.ends_with("ul")) {
        end = len - 2;
    } else {
        let last_char -> Int = Int(val_str[len - 1]);
        if (last_char == 76 || last_char == 108 || last_char == 85 || last_char == 117) {
            end = len - 1;
        }
    }

    let base_val -> Int = 10;
    if (end - start >= 2 && val_str[start] == '0') { 
        let second_char -> Int = Int(val_str[start + 1]);
        if (second_char == 120 || second_char == 88) { base_val = 16; start += 2; } 
        else if (second_char == 98 || second_char == 66) { base_val = 2; start += 2; } 
        else if (second_char == 111 || second_char == 79) { base_val = 8; start += 2; }
    }

    let val -> Int = 0; let j -> Int = start;
    while (j < end) {
        let code -> Int = Int(val_str[j]);
        if (code == 95) { j += 1; continue; }
        let digit -> Int = -1;
        if (code >= 48 && code <= 57) { digit = code - 48; } 
        else if (code >= 97 && code <= 102) { digit = code - 87; } 
        else if (code >= 65 && code <= 70) { digit = code - 55; } 
        
        let is_valid -> Bool = false;
        if (digit >= 0) {
            if (base_val == 10 && digit < 10) { is_valid = true; }
            else if (base_val == 16 && digit < 16) { is_valid = true; }
            else if (base_val == 2 && digit < 2) { is_valid = true; }
            else if (base_val == 8 && digit < 8) { is_valid = true; }
        }
        if is_valid {
            val = val * base_val + digit;
        } else {
            throw_invalid_syntax(pos, "Invalid character in numeric literal '" + val_str + "'");
            return 0;
        }
        j += 1;
    }
    if is_neg { return 0 - val; }
    return val;
}

func exceeds_64bit_range(val_str -> String) -> Bool {
    let len -> Int = val_str.length();
    if (len == 0) { return false; }
    let start -> Int = 0;
    if (val_str[0] == '-') { // '-'
        start = 1;
    }
    let end -> Int = len;
    if (val_str.ends_with("ULL") || val_str.ends_with("ull")) {
        end = len - 3;
    } else if (val_str.ends_with("LL") || val_str.ends_with("ll") || val_str.ends_with("UL") || val_str.ends_with("ul")) {
        end = len - 2;
    } else {
        let last_char -> Int = Int(val_str[len - 1]);
        if (last_char == 76 || last_char == 108 || last_char == 85 || last_char == 117) {
            end = len - 1;
        }
    }
    
    // check hex/bin/octal
    if (end - start >= 2 && val_str[start] == '0') { 
        let second_char -> Char = val_str[start + 1];
        if (second_char == 'x' || second_char == 'X') { // 0x
            return (end - start) > 18; // 0x + 16 chars
        } else if (second_char == 'b' || second_char == 'B') { // 0b
            return (end - start) > 66; // 0b + 64 chars
        } else if (second_char == 'o' || second_char == 'O') { // 0o
            return (end - start) > 24; // 0o + 22 chars approx
        }
    }

    // base 10: remove leading zeros
    while (start < end - 1 && val_str[start] == '0') {
        start += 1;
    }
    
    let digit_count -> Int = 0;
    let i -> Int = start;
    while (i < end) {
        if (val_str[i] != '_') { // ignore '_'
            digit_count += 1;
        }
        i += 1;
    }

    if (digit_count > 19) { return true; }
    if (digit_count < 19) { return false; }
    
    // exact 19 digits, compare string
    let max_str -> String = "9223372036854775807"; // 19 digits
    if (val_str[0] == '-') {
        max_str = "9223372036854775808"; 
    }
    
    let max_idx -> Int = 0;
    i = start;
    while (i < end) {
        if (val_str[i] == '_') { 
            i += 1;
            continue; 
        }
        if (val_str[i] > max_str[max_idx]) { return true; }
        if (val_str[i] < max_str[max_idx]) { return false; }
        max_idx += 1;
        i += 1;
    }
    return false;
}

func string_to_long(val_str -> String, pos -> Position) -> Long {
    let len -> Int = val_str.length();
    if (len == 0) { return 0L; }
    
    let start -> Int = 0;
    let is_neg -> Bool = false;
    
    if (val_str[0] == '-') {
        start = 1;
        is_neg = true;
    }

    let end -> Int = len;
    if (val_str.ends_with("ULL") || val_str.ends_with("ull")) {
        end = len - 3;
    } else if (val_str.ends_with("LL") || val_str.ends_with("ll") || val_str.ends_with("UL") || val_str.ends_with("ul")) {
        end = len - 2;
    } else {
        let last_char -> Char = val_str[len - 1];
        if (last_char == 'L' || last_char == 'l' || last_char == 'U' || last_char == 'u') {
            end = len - 1;
        }
    }

    let base_val -> Long = 10L;
    if (end - start >= 2 && val_str[start] == '0') { 
        let second_char -> Char = val_str[start + 1];
        if (second_char == 'x' || second_char == 'X') {
            base_val = 16L;
            start += 2;
        } else if (second_char == 'b' || second_char == 'B') {
            base_val = 2L;
            start += 2;
        } else if (second_char == 'o' || second_char == 'O') {
            base_val = 8L;
            start += 2;
        }
    }

    let val -> Long = 0L;
    let j -> Int = start;
    while (j < end) {
        let code -> Char = val_str[j];
        if (code == '_') {
            j += 1;
            continue;
        }

        let digit -> Long = -1L;
        if (code >= '0' && code <= '9') { digit = Int(code) - Int('0'); }
        else if (code >= 'a' && code <= 'f') { digit = Int(code) - Int('a') + 10; }
        else if (code >= 'A' && code <= 'F') { digit = Int(code) - Int('A') + 10; }


        let is_valid -> Bool = false;
        if (digit >= 0L) {
            if (base_val == 10L && digit < 10L) { is_valid = true; }
            else if (base_val == 16L && digit < 16L) { is_valid = true; }
            else if (base_val == 2L && digit < 2L) { is_valid = true; }
            else if (base_val == 8L && digit < 8L) { is_valid = true; }
        }

        if is_valid {
            val = val * base_val + digit;
        } else {
            throw_invalid_syntax(pos, "Invalid character in numeric literal '" + val_str + "'");
            return 0L;
        }
        
        j += 1;
    }
    
    if is_neg { return 0L - val; }
    return val;
}


// file & text utils
func string_escape(s -> String) -> String {
    let res -> String = "";
    let i -> Int = 0;
    let len -> Int = s.length();
    
    while (i < len) {
        let code -> Char = s[i];
        
    if (code == '"') { // "
            res = res + "\\22";
        } else if (code == '\\') {
            res = res + "\\5C";
        } else if (code == '\n') {
            res = res + "\\0A";
        } else if (code == '\r') {
            res = res + "\\0D";
        } else {
            res += s.slice(i, i + 1);
        }
        i += 1;
    }
    return res;
}

func file_exists(path -> String) -> Bool {
    return file.exists(path);
}

func get_dir_name(path -> String) -> String {
    let len -> Int = path.length();
    let i -> Int = len - 1;
    while (i >= 0) {
        let c -> Char = path[i];
        if (c == '/' || c == '\\') {
            return path.slice(0, i);
        }
        i -= 1;
    }
    return ".";
}

func to_normpath(path -> String) -> String {
    let len -> Int = path.length();
    let parts -> Vector(String) = [];
    let i -> Int = 0;
    let start_idx -> Int = 0;
    
    while (i <= len) {
        let c -> Char = ' ';
        if (i < len) { c = path[i]; }
        if (c == '/' || c == '\\' || i == len) {
            if (i > start_idx) {
                parts.append(path.slice(start_idx, i));
            }
            start_idx = i + 1;
        }
        i += 1;
    }
    
    let norm_parts -> Vector(String) = [];
    let num_parts -> Int = parts.length();
    let j -> Int = 0;
    
    while (j < num_parts) {
        let p -> String = parts[j];
        if (p == ".") {
            // ignore
        } else if (p == "..") {
            let cur_len -> Int = norm_parts.length();
            if (cur_len > 0 && norm_parts[cur_len - 1] != "..") {
                let temp -> Vector(String) = [];
                let k -> Int = 0;
                while (k < cur_len - 1) {
                    temp.append(norm_parts[k]);
                    k += 1;
                }
                norm_parts = temp;
            } else {
                norm_parts.append("..");
            }
        } else {
            norm_parts.append(p);
        }
        j += 1;
    }
    
    let res -> String = "";
    if (len > 0) {
        let first_char -> Char = path[0];
        if (first_char == '/' || first_char == '\\') {
            res = "/";
        }
    }
    
    let norm_len -> Int = norm_parts.length();
    let k -> Int = 0;
    while (k < norm_len) {
        res += norm_parts[k];
        if (k < norm_len - 1) {
            res += "/";
        }
        k += 1;
    }
    
    if (res == "") { return "."; }
    return res;
}

func import_security_path(path -> String) -> String {
    let result -> String = "";
    let i -> Int = 0;
    while (i < path.length()) {
        let ch -> Char = path[i];
        if (ch == '\\') {
            ch = '/';
        } else if (ch >= 'A' && ch <= 'Z') {
            ch = Char(Int(ch) + 32);
        }
        result += ch;
        i += 1;
    }
    return result;
}

func resolve_import_path(c -> Compiler, raw_path -> String, pos -> Position) -> String {
    if (raw_path.ends_with(".wl")) {
        let final_path -> String = "";
        if (c.current_dir == ".") {
            final_path = to_normpath(raw_path);
        } else {
            final_path = to_normpath(c.current_dir + "/" + raw_path);
        }

        let active_wl_path -> String = sys.env.get_env("WL_PATH");
        if (active_wl_path is !null) {
            let std_root -> String = import_security_path(to_normpath(active_wl_path + "/std"));
            let internal_root -> String = std_root + "/internal";
            let importer -> String = import_security_path(to_normpath(c.current_dir));
            let checked_final_path -> String = import_security_path(final_path);
            let targets_internal -> Bool = checked_final_path == internal_root || checked_final_path.starts_with(internal_root + "/");
            let importer_is_std -> Bool = importer == std_root || importer.starts_with(std_root + "/");
            if (targets_internal && !importer_is_std) {
                throw_import_error(pos, "Module '" + raw_path + "' is internal to the standard library.");
                return "";
            }
        }
        return final_path;
    }

    let wl_path -> String = sys.env.get_env("WL_PATH");
    if (wl_path is null) {
        throw_environment_error("Missing 'WL_PATH' variable.");
    }

    let std_root -> String = import_security_path(to_normpath(wl_path + "/std"));
    let importer -> String = import_security_path(to_normpath(c.current_dir));
    let importer_is_std -> Bool = importer == std_root || importer.starts_with(std_root + "/");
    let checked_raw_path -> String = import_security_path(raw_path);
    if ((checked_raw_path == "internal" || checked_raw_path.starts_with("internal/")) && !importer_is_std) {
        throw_import_error(pos, "Module '" + raw_path + "' is internal to the standard library.");
        return "";
    }

    let pkg_entry -> String = wl_path + "/std/" + raw_path + "/_pkg.wl";
    if (file_exists(pkg_entry)) {
        return to_normpath(pkg_entry);
    }

    let file_entry -> String = wl_path + "/std/" + raw_path + ".wl";
    if (file_exists(file_entry)) {
        return to_normpath(file_entry);
    }

    throw_import_error(pos, "Cannot find module '" + raw_path + "'. Searched:\n - " + pkg_entry + "\n - " + file_entry);
    return "";
}


// closure analysis utils
func record_capture(scope -> CaptureScope, v_name -> String) -> Void {
    if (scope.local_vars.get(v_name) is null) {
        if (scope.captured_vars.get(v_name) is null) {
            scope.captured_vars.put(v_name, TypeListNode(type=1));
            scope.captured_list.append(v_name);
        }
    }
}

func analyze_captures(node -> Struct, scope -> CaptureScope) -> Void {
    if (node is null) { return; }
    let base -> BaseNode = node;
    let type -> Int = base.type;

    if (type == NODE_BLOCK) {
        let b -> BlockNode = node;
        let stmts -> Vector(Struct) = b.stmts;
        let i -> Int = 0;
        let len -> Int = 0; if (stmts is !null) { len = stmts.length(); }
        while (i < len) {
            analyze_captures(stmts[i], scope);
            i += 1;
        }
    }
    else if (type == NODE_VAR_DECL) {
        let decl -> VarDeclareNode = node;
        scope.local_vars.put(decl.name_tok.value, TypeListNode(type=1));
        if (decl.value is !null) {
            analyze_captures(decl.value, scope);
        }
    }
    else if (type == NODE_VAR_ACCESS) {
        let acc -> VarAccessNode = node;
        record_capture(scope, acc.name_tok.value);
    }
    else if (type == NODE_VAR_ASSIGN) {
        let assign -> VarAssignNode = node;
        record_capture(scope, assign.name_tok.value);
        if (assign.value is !null) {
            analyze_captures(assign.value, scope);
        }
    }
    else if (type == NODE_BINOP) {
        let binop -> BinOpNode = node;
        analyze_captures(binop.left, scope);
        analyze_captures(binop.right, scope);
    }
    else if (type == NODE_UNARYOP) {
        let uop -> UnaryOpNode = node;
        analyze_captures(uop.node, scope);
    }
    else if (type == NODE_POSTFIX) {
        let pop -> PostfixOpNode = node;
        analyze_captures(pop.node, scope);
    }
    else if (type == NODE_IF) {
        let if_n -> IfNode = node;
        analyze_captures(if_n.condition, scope);
        analyze_captures(if_n.body, scope);
        analyze_captures(if_n.else_body, scope);
    }
    else if (type == NODE_WHILE) {
        let w_n -> WhileNode = node;
        analyze_captures(w_n.condition, scope);
        analyze_captures(w_n.body, scope);
    }
    else if (type == NODE_FOR) {
        let f_n -> ForNode = node;
        analyze_captures(f_n.init, scope);
        analyze_captures(f_n.cond, scope);
        analyze_captures(f_n.step, scope);
        analyze_captures(f_n.body, scope);
    }
    else if (type == NODE_CALL) {
        let call -> CallNode = node;
        analyze_captures(call.callee, scope);
        let args -> Vector(Struct) = call.args;
        let i -> Int = 0;
        let len -> Int = 0; if (args is !null) { len = args.length(); }
        while (i < len) {
            let arg -> ArgNode = args[i];
            analyze_captures(arg.val, scope);
            i += 1;
        }
    }
    else if (type == NODE_RETURN) {
        let ret -> ReturnNode = node;
        analyze_captures(ret.value, scope);
    }
    else if (type == NODE_FIELD_ACCESS) {
        let fa -> FieldAccessNode = node;
        analyze_captures(fa.obj, scope);
    }
    else if (type == NODE_FIELD_ASSIGN) {
        let fass -> FieldAssignNode = node;
        analyze_captures(fass.obj, scope);
        analyze_captures(fass.value, scope);
    }
    else if (type == NODE_INDEX_ACCESS) {
        let ia -> IndexAccessNode = node;
        analyze_captures(ia.target, scope);
        analyze_captures(ia.index_node, scope);
    }
    else if (type == NODE_INDEX_ASSIGN) {
        let iass -> IndexAssignNode = node;
        analyze_captures(iass.target, scope);
        analyze_captures(iass.index_node, scope);
        analyze_captures(iass.value, scope);
    }
    else if (type == NODE_VECTOR_LIT) {
        let vec -> VectorLitNode = node;
        let elems -> Vector(Struct) = vec.elements;
        let i -> Int = 0;
        let len -> Int = 0; if (elems is !null) { len = elems.length(); }
        while (i < len) {
            let arg -> ArgNode = elems[i];
            analyze_captures(arg.val, scope);
            i += 1;
        }
    }
    else if (type == NODE_REF) {
        let ref_n -> RefNode = node;
        analyze_captures(ref_n.node, scope);
    }
    else if (type == NODE_DEREF) {
        let deref_n -> DerefNode = node;
        analyze_captures(deref_n.node, scope);
    }
    else if (type == NODE_PTR_ASSIGN) {
        let pass -> PtrAssignNode = node;
        analyze_captures(pass.pointer, scope);
        analyze_captures(pass.value, scope);
    }
    else if (type == NODE_FUNC_DEF) {
        let func_def -> FunctionDefNode = node;
        scope.local_vars.put(func_def.name_tok.value, TypeListNode(type=1));

        let child_scope -> CaptureScope = CaptureScope(local_vars=Dict(32), captured_vars=Dict(32), captured_list=[]);

        let params -> Vector(Struct) = func_def.params;
        let i -> Int = 0;
        let len -> Int = 0; if (params is !null) { len = params.length(); }
        while (i < len) {
            let p_node -> ParamNode = params[i];
            child_scope.local_vars.put(p_node.name_tok.value, TypeListNode(type=1));
            i += 1;
        }

        analyze_captures(func_def.body, child_scope);
        let k_i -> Int = 0;
        let k_len -> Int = child_scope.captured_list.length();
        while (k_i < k_len) {
            let k_str -> String = child_scope.captured_list[k_i];
            record_capture(scope, k_str);
            k_i += 1;
        }
    }
}

// vector util
func check_out_index(c -> Compiler, target_node -> Struct, index_node -> Struct, pos -> Position) -> Void {
    let base_idx -> BaseNode = index_node;
    if (base_idx.type == NODE_INT) {
        let i_node -> IntNode = index_node;
        let val_str -> String = i_node.tok.value;
        let idx_val -> Long = string_to_long(i_node.tok.value, i_node.pos);

        if (idx_val < 0) {
            throw_index_error(pos, "Negative index " + val_str + " is not supported yet.");
        }

        let base_target -> BaseNode = target_node;
        if (base_target.type == NODE_VECTOR_LIT) {
            let vec_node -> VectorLitNode = target_node;
            let count -> Int = vec_node.count;
            
            if (idx_val >= count) {
                throw_index_error(pos, "Index " + val_str + " is out of bounds for vector of size " + count + ".");
            }
        }

        if (base_target.type == NODE_STRING) {
            let str_node -> StringNode = target_node;
            let s_len -> Int = str_node.tok.value.length();

            if (idx_val >= s_len) {
                throw_index_error(pos, "Index " + val_str + " is out of bounds for string of length " + s_len + ".");
            }
        }
    }
}

// oop
func is_subclass(c -> Compiler, child_id -> Int, parent_id -> Int) -> Bool {
    if (child_id == parent_id) { return true; }
    let s_info -> StructInfo = c.struct_id_map.get("" + child_id);
    if (s_info is null) { return false; }
    if (parent_id == TYPE_GENERIC_ENUM && s_info.is_enum) { return true; }
    let curr_parent -> Int = s_info.parent_id;
    while (curr_parent != 0) {
        if (curr_parent == parent_id) { return true; }
        let p_info -> StructInfo = c.struct_id_map.get("" + curr_parent);
        if (p_info is null) { return false; }
        curr_parent = p_info.parent_id;
    }
    return false;
}

