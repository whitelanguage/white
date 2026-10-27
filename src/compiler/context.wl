// src/compiler/context.wl
import "sys"
import "file"
import Dict from "dict"

import "../frontend/tokens.wl" as WhitelangTokens
import * from "../frontend/ast.wl"
import * from "../frontend/arena.wl"
import * from "../frontend/diagnostics.wl"
import * from "target.wl"


// primitive and compiler-only type ids
const TYPE_INT: Int = 1;
const TYPE_FLOAT: Int = 2;
const TYPE_BOOL: Int = 3;
const TYPE_VOID: Int = 4;
const TYPE_STRING: Int = 5;
const TYPE_NULL: Int = 6;
const TYPE_GENERIC_STRUCT: Int = 7;
const TYPE_GENERIC_FUNCTION: Int = 8;
const TYPE_LONG: Int = 9;
const TYPE_BYTE: Int = 10;
const TYPE_GENERIC_CLASS: Int = 11;
const TYPE_GENERIC_METHOD: Int = 12;
const TYPE_AUTO: Int = 13;
const TYPE_CHAR: Int = 14;
const TYPE_ANYPTR: Int = 15;
const TYPE_GENERIC_ENUM: Int = 28;

const TYPE_INT8: Int = 16;
const TYPE_INT16: Int = 17;
//    TYPE_INT32: TYPE_INT
//    TYPE_INT64: TYPE_LONG
const TYPE_INT128: Int = 18;

//    TYPE_UINT8: TYPE_BYTE
const TYPE_UINT16: Int = 19;
const TYPE_UINT32: Int = 20;
const TYPE_UINT64: Int = 21;
const TYPE_UINT128: Int = 22;

const TYPE_FLOAT32: Int = 23;
//    TYPE_FLOAT64: TYPE_FLOAT

const TYPE_INTSIZE: Int = 24;
const TYPE_UINTSIZE: Int = 25;
const TYPE_ANY_ERROR: Int = 26;

const TYPE_POISON: Int = 98;
const TYPE_NULLPTR: Int = 99;

// parsed annotation flags
const FLAG_ANN_INTRINSIC: Int = 0x001;
const FLAG_ANN_COMP_LINK: Int = 0x002;
const FLAG_ANN_EXPORT: Int = 0x004;

// state shared by semantic analysis and lowering
struct GCTracker(
    reg: String,
    type: Int
)

struct CompileResult(
    reg: String,
    type: Int,
    origin_type: Int,
    owns_ref: Bool,
    is_const_access: Bool
)

struct SystemAnnResult(
    ann_flags: Int,
    compiler_link_name: String,
    intrinsic_name: String
)

struct TypeListNode(
    type: Int,
    pass_mode: Int
)

struct Scope(
    table: Optional(Dict(String, SymbolInfo)), // inactive scopes do not allocate a symbol table
    parent: Int,  // parent scope index, or -1 at the root
    gc_vars: Vector(Struct),
    depth: Int
)

struct StringConstant(
    id: Int,
    value: String
)

struct SymbolInfo(
    reg: String,
    type: Int,
    origin_type: Int, // for generic type
    is_const: Bool, // const
    is_const_access: Bool,
    is_ref_param: Bool,
    is_reference: Bool,
    func_arg_types: Vector(Struct),
    arg_names: Vector(String),
    variadic_param: Int
)

struct FuncInfo(
    name: String,
    base_name: String,
    ret_type: Int,
    arg_types: Vector(Struct),
    arg_names: Vector(String),
    is_varargs: Bool,
    ann_flags: Int,
    compiler_link_name: String,
    abi_name: String,
    mutates_self: Bool,
    variadic_param: Int,
    default_args: Vector(NodeID),
    ref_body: NodeID,
    ref_context: Optional(GenericTemplate),
    ref_bindings: Optional(Dict(String, SymbolInfo))
)

struct VariadicSource(
    value: CompileResult,
    spread: Bool,
    length: String,
    data: String
)

struct PrintArgument(
    value: CompileResult,
    spread: Bool,
    length: String,
    data: String,
    elem_type: Int
)

struct FieldInfo(
    name: String,
    type: Int,
    llvm_type: String,
    offset: Int,
    is_const: Bool,
    default_val: NodeID
)
struct StructInfo(
    name: String,
    type_id: Int,
    fields: Vector(Struct),
    llvm_name: String,
    init_body: NodeID,
    is_class: Bool,
    vtable_name: String,
    parent_id: Int,
    vtable: Vector(Struct),
    ann_flags: Int,
    is_enum: Bool,
    is_error: Bool,
    is_interface: Bool,
    interfaces: Vector(Struct),
    compiler_link_name: String,
    layout_ready: Bool
)

struct GenericTemplate(
    name: String,
    node: NodeID,
    type_params: Vector(GenericParamNode),
    prefix: String,
    dir: String,
    visible: Dict(String, String),
    namespaces: Dict(String, Bool),
    types: Dict(String, String),
    funcs: Dict(String, String),
    globals: Dict(String, String)
)

struct StaticConstant(node: NodeID, source_type: Int, context: GenericTemplate)

struct GenericFuncInstance(
    template: GenericTemplate,
    bindings: Dict(String, SymbolInfo),
    func_key: String,
    depth: Int
)

struct GenericClassInstance(
    template: GenericTemplate,
    bindings: Dict(String, SymbolInfo),
    type_id: Int,
    depth: Int
)

struct GenericMethodInstance(
    template: GenericTemplate,
    bindings: Dict(String, SymbolInfo),
    func_key: String,
    owner_name: String,
    depth: Int
)

struct ArrayInfo(
    base_type: Int,
    size: Int,
    llvm_name: String
)

struct NamedTypeInfo(
    name            : String,
    type_id         : Int,
    underlying_type : Int,
    is_alias        : Bool,
    target_node     : NodeID,
    pos             : Position,
    resolving       : Bool,
    resolved        : Bool
)

struct UnionInfo(
    members: Vector(Int),
    key: String,
    pos: Position
)

struct UnionLayout(
    valid: Bool,
    size: Int,
    alignment: Int,
    payload_offset: Int,
    payload_type: Int,
    payload_count: Int
)

struct SliceParts(
    start: String,
    length: String,
    owner: String,
    data_slot: String,
    size_slot: String,
    data: String
)

struct CaptureScope(
    local_vars: Dict(String, Bool),
    captured_vars: Dict(String, Bool),
    captured_list: Vector(String)
)

struct FlowType(path: String, type: Int, unstable: Bool)

struct Compiler(
    // shared state for discovery, checking and lowering, per-function state stays in Scope
    arena: AstArena,
    output_file: Optional(file.File),
    reg_count: Int,
    symbol_table: Scope,
    scope_stack: Vector(Scope),
    global_symbol_table: Dict(String, SymbolInfo),
    constant_nums: Dict(String, Float),
    constant_integers: Dict(String, Long),
    constant_wide_integers: Dict(String, UInt128),
    static_constants: Dict(String, StaticConstant),
    func_table: Dict(String, FuncInfo),
    struct_table: Dict(String, StructInfo),
    struct_id_map: Dict(Int, StructInfo),
    named_types: Dict(String, NamedTypeInfo),
    named_type_ids: Dict(Int, NamedTypeInfo),
    union_types: Dict(Int, UnionInfo),
    union_cache: Dict(String, SymbolInfo),
    flow_types: Vector(FlowType),
    flow_exposed: Vector(String),
    flow_skip: NodeID,
    type_revision: Int,
    drop_cache: Vector(Int),
    indent: String,
    ptr loop_stack: LoopScope,
    scope_depth: Int,
    has_main: Bool,
    current_ret_type: Int,
    string_list: Vector(Struct),
    str_count: Int,
    type_counter: Int, // custom type
    ptr_cache: Dict(String, SymbolInfo),       // Key: "ptr_ID", Value: SymbolInfo(reg="", type=ptr_id)
    ptr_base_map: Dict(Int, SymbolInfo),    // type ID -> pointee
    vector_cache: Dict(String, SymbolInfo),    // Key: "vec_baseID", Value: SymbolInfo(type=new_id)
    vector_base_map: Dict(Int, SymbolInfo), // type ID -> element
    array_info_map: Dict(Int, ArrayInfo),
    array_type_cache: Dict(String, SymbolInfo),
    func_ret_map: Dict(Int, SymbolInfo),
    method_ret_map: Dict(Int, SymbolInfo),
    declared_externs: Dict(String, StringConstant),
    native_adapters: Dict(String, FuncInfo),
    imported_modules: Dict(String, StringConstant),
    module_prefix_owners: Dict(String, StringConstant),
    module_id: Int,
    current_package_prefix: String,
    current_module_is_package: Bool,
    current_file_visible_prefixes: Dict(String, String),
    current_file_namespaces: Dict(String, Bool),
    current_file_type_aliases: Dict(String, String),
    alloc_regs: Vector(String),
    current_dir: String,
    current_file_func_aliases: Dict(String, String),
    current_file_global_aliases: Dict(String, String),
    global_type_aliases: Dict(String, String),
    global_func_aliases: Dict(String, String),
    global_var_aliases: Dict(String, String),
    compiler_link: Dict(String, String),
    curr_func: Optional(FuncInfo),
    expected_type: Int,
    hoist_scope: Scope,
    hoist_scope_stack: Vector(Scope),
    type_drop_list: Vector(Struct),
    global_buffer: String,
    string_pool: Dict(String, StringConstant),
    is_shared: Bool,
    emit_source_context: Bool,
    all_modules: Vector(Struct),
    is_precompile_phase: Bool,
    fallible_cache: Dict(String, SymbolInfo),
    fallible_base_map: Dict(Int, SymbolInfo),
    current_catch_label: String,
    current_catch_err_ptr: String,
    current_catch_scope: Scope,
    extra_libs: Vector(String),
    error_types: Vector(Struct),
    generic_structs: Dict(String, GenericTemplate),
    generic_funcs: Dict(String, GenericTemplate),
    generic_methods: Dict(String, GenericTemplate),
    generic_class_methods: Dict(String, GenericTemplate),
    generic_methods_queued: Dict(String, Bool),
    generic_instances: Dict(String, SymbolInfo),
    generic_type_names: Dict(String, StringConstant),
    generic_instance_bindings: Dict(String, Dict(String, SymbolInfo)),
    generic_instance_templates: Dict(String, GenericTemplate),
    struct_contexts: Dict(Int, GenericTemplate),
    generic_type_defs: String,
    generic_vtables: Vector(Struct),
    generic_worklist: Vector(Struct),
    generic_func_emitted: Int,
    generic_class_worklist: Vector(Struct),
    generic_class_emitted: Int,
    generic_method_worklist: Vector(Struct),
    generic_method_emitted: Int,
    generic_bindings: Dict(String, SymbolInfo),
    generic_depth: Int,
    generic_instance_count: Int,
    generic_func_key: String,
    generic_method_key: String,
    generic_class_type: Int,
    erased_checks: Dict(String, StringConstant),
    hash_types: Dict(String, StringConstant),
    ref_targets: Dict(UInt32, Bool),
    ref_files: Dict(String, Bool),
    ref_scan: Int,
    ref_call_scan: Int,
    ref_callees: Dict(String, Bool),
    ref_index_ready: Bool
)

struct ParsedModule(
    path: String,
    prefix: String,
    dir: String,
    is_package: Bool,
    ast: NodeID,
    visible: Dict(String, String),
    namespaces: Dict(String, Bool),
    types: Dict(String, String),
    funcs: Dict(String, String),
    globals: Dict(String, String),
    imports: Vector(NodeID)
)

func set_module_context(ref c: Compiler, module: ParsedModule) -> Void {
    c.current_file_visible_prefixes = module.visible;
    c.current_file_namespaces = module.namespaces;
    c.current_file_type_aliases = module.types;
    c.current_file_func_aliases = module.funcs;
    c.current_file_global_aliases = module.globals;
    c.current_package_prefix = module.prefix;
    c.current_module_is_package = module.is_package;
    c.current_dir = module.dir;
}

struct LoopScope(
    label_continue: String,
    label_break: String,
    ptr parent: LoopScope,
    loop_scope: Scope
)

func has_func(info: FuncInfo) -> Bool {
    return info.name.length() != 0;
}
func has_struct(info: StructInfo) -> Bool {
    return info.type_id != 0;
}
func has_template(info: GenericTemplate) -> Bool {
    return info.name.length() != 0;
}
func has_named_type(info: NamedTypeInfo) -> Bool {
    return info.name.length() != 0;
}
func has_bound_args(info: BoundCallArgs) -> Bool {
    return info.valid;
}
func has_result(info: CompileResult) -> Bool {
    return info.type != 0 || info.reg.length() != 0;
}

func scope_lookup(scope: Scope, name: String) -> Optional(SymbolInfo) {
    let table = scope.table;
    if (table is null) { return null; }
    return table.lookup(name);
}

func scope_put(scope: Scope, name: String, info: SymbolInfo) -> Void {
    let table = scope.table;
    if (table is null) {
        throw_internal_compiler_error(no_position(), "Cannot bind a symbol in an inactive scope.");
        return;
    }
    table.put(name, info);
}

func store_struct(ref c: Compiler, info: StructInfo) -> Void {
    if (!has_struct(info)) {
        return;
    }
    c.struct_table.put(info.name, info);
    c.struct_id_map.put(info.type_id, info);
    c.type_revision++;
}

func store_named_type(ref c: Compiler, info: NamedTypeInfo) -> Void {
    if (!has_named_type(info)) {
        return;
    }
    c.named_types.put(info.name, info);
    if (!info.is_alias) {
        c.named_type_ids.put(info.type_id, info);
        c.type_revision++;
    }
}

// compiler init & state utils
func write_ir(ref c: Compiler, text: String) -> Void {
// machine emission has no text file, reaching this path without one is a driver error
    let output = c.output_file;
    if (output is null) {
        throw_internal_compiler_error(no_position(), "LLVM output file is not open.");
        abort_and_clean(1);
        return;
    }
    output.write(text);
}

func close_ir(ref c: Compiler) -> Void {
    let output = c.output_file;
    if (output is !null) { output.close(); }
}

func new_compiler(out_path: String, is_shared: Bool, emit_source_context: Bool, arena: AstArena) -> Compiler? {
    let f: Optional(file.File) = null;
    if (out_path.length() != 0) { f = file.create(out_path)?; }
    // initialize empty scope
    let root_scope: Scope = Scope(table=Dict(), parent=-1, gc_vars=[], depth=0);

    let comp: Compiler = Compiler(
        arena = arena,
        output_file = f,
        reg_count = 1,
        symbol_table = root_scope,
        scope_stack = [],
        global_symbol_table = Dict(),
        constant_nums = Dict(),
        constant_integers = Dict(),
        constant_wide_integers = Dict(),
        static_constants = Dict(),
        func_table = Dict(),
        struct_table = Dict(),
        struct_id_map = Dict(),
        named_types = Dict(),
        named_type_ids = Dict(),
        union_types = Dict(),
        union_cache = Dict(),
        type_revision = 0,
        drop_cache = [],
        indent = "  ",
        loop_stack = nullptr,
        scope_depth = 0,
        has_main = false,
        current_ret_type = TYPE_VOID,
        string_list = [],
        str_count = 0,
        type_counter = 100,
        ptr_cache=Dict(),
        ptr_base_map=Dict(),
        vector_cache=Dict(),
        vector_base_map=Dict(),
        func_ret_map=Dict(),
        method_ret_map=Dict(),
        declared_externs=Dict(),
        native_adapters=Dict(),
        imported_modules=Dict(),
        module_prefix_owners=Dict(),
        module_id=0,
        current_module_is_package=false,
        current_file_visible_prefixes = Dict(),
        current_file_namespaces = Dict(),
        current_file_type_aliases = Dict(),
        alloc_regs = [],
        current_dir = ".",
        current_file_func_aliases = Dict(),
        current_file_global_aliases = Dict(),
        global_type_aliases = Dict(),
        global_func_aliases = Dict(),
        global_var_aliases = Dict(),
        compiler_link = Dict(),
        current_package_prefix = "",
        curr_func = null,
        expected_type = 0,
        hoist_scope = Scope(table=null, parent=-1, gc_vars=[], depth=0),
        hoist_scope_stack = [],
        type_drop_list = [],
        global_buffer = "",
        string_pool = Dict(),
        array_info_map = Dict(),
        array_type_cache = Dict(),
        is_shared = is_shared,
        emit_source_context = emit_source_context,
        all_modules = [],
        is_precompile_phase = true,
        fallible_cache = Dict(),
        fallible_base_map = Dict(),
        current_catch_label = "",
        current_catch_err_ptr = "",
        current_catch_scope = Scope(table=null, parent=-1, gc_vars=[], depth=0),
        extra_libs = [],
        error_types = [],
        generic_structs = Dict(),
        generic_funcs = Dict(),
        generic_methods = Dict(),
        generic_class_methods = Dict(),
        generic_methods_queued = Dict(),
        generic_instances = Dict(),
        generic_type_names = Dict(),
        generic_instance_bindings = Dict(),
        generic_instance_templates = Dict(),
        generic_type_defs = "",
        generic_vtables = [],
        generic_worklist = [],
        generic_func_emitted = 0,
        generic_class_worklist = [],
        generic_class_emitted = 0,
        generic_method_worklist = [],
        generic_method_emitted = 0,
        generic_bindings = Dict(),
        generic_depth = 0,
        generic_instance_count = 0,
        generic_func_key = "",
        generic_method_key = "",
        generic_class_type = 0,
        erased_checks = Dict(),
        hash_types = Dict(),
        flow_types=[],
        flow_exposed=[],
        flow_skip=NodeID(0U),
        ref_targets=Dict(),
        ref_files=Dict(),
        ref_scan=0,
        ref_call_scan=0,
        ref_callees=Dict(),
        ref_index_ready=false,
        struct_contexts=Dict()
    );

    comp.type_drop_list.append(TypeListNode(type=TYPE_GENERIC_FUNCTION, pass_mode=0));
    comp.type_drop_list.append(TypeListNode(type=TYPE_STRING, pass_mode=0));
    return comp;
}

func next_reg(ref c: Compiler) -> String {
    let name: String = "%t" + c.reg_count;
    c.reg_count += 1;
    return name;
}

func next_label(ref c: Compiler) -> String {
    let name: String = "L" + c.reg_count;
    c.reg_count += 1;
    return name;
}

func void_result() -> CompileResult {
    return CompileResult(reg="", type=TYPE_VOID, origin_type=0, owns_ref=false, is_const_access=false);
}

func module_member_name(prefix: String, path_parts: Vector(String), field_name: String) -> String {
    let result: String = prefix;
    let i: Int = path_parts.length() - 1;
    while (i >= 0) {
        result += path_parts[i] + ".";
        i -= 1;
    }
    return result + field_name;
}

func register_import_namespaces(ref c: Compiler, table: Dict(String, String), pos: Position) -> Void {
    let i: Int = 0;
    while (i < table.capacity) {
        if (table.hashes[i] >= 2) {
            let name: String = table.keys[i];
            let dot: Int = 0;
            while (dot < name.length() && name[dot] != '.') { dot += 1; }
            if (dot > 0 && dot < name.length()) {
                let namespace: String = name.slice(0, dot);
                if (c.current_file_visible_prefixes.lookup(namespace) is !null) {
                    report_import_collision(ref c, pos, "module", namespace);
                } else {
                    c.current_file_namespaces.put(namespace, true);
                }
            }
        }
        i += 1;
    }
}

func is_visible_namespace(ref c: Compiler, name: String) -> Bool {
    if (c.current_file_visible_prefixes.lookup(name) is !null) { return true; }
    return c.current_file_namespaces.contains_key(name);
}

func erase_alias_prefix(table: Dict(String, String), prefix: String) -> Void {
    let removed: Vector(String) = [];
    let i: Int = 0;
    while (i < table.capacity) {
        if (table.hashes[i] >= 2) {
            let key: String = table.keys[i];
            if (key.starts_with(prefix)) {
                removed.append(key);
            }
        }
        i += 1;
    }
    i = 0;
    while (i < removed.length()) {
        table.remove(removed[i]);
        i += 1;
    }
}

func unbind_namespace(ref c: Compiler, name: String) -> Void {
    let prefix: String = name + ".";
    erase_alias_prefix(c.current_file_func_aliases, prefix);
    erase_alias_prefix(c.current_file_type_aliases, prefix);
    erase_alias_prefix(c.current_file_global_aliases, prefix);
    c.current_file_namespaces.remove(name);
}

// symbol & field lookup utils
func find_symbol(ref c: Compiler, name: String) -> Optional(SymbolInfo) {
    let curr: Scope = c.symbol_table;
    while true {
        if (curr.table is !null) {
            let info: Optional(SymbolInfo) = scope_lookup(curr, name);
            if ((info is !null)) { return info; }
        }
        if (curr.parent < 0 || curr.parent >= c.scope_stack.length()) {
            break;
        }
        curr = c.scope_stack[curr.parent];
    }

    if (c.current_package_prefix != "") {
        let fallback: Optional(SymbolInfo) = c.global_symbol_table.lookup(c.current_package_prefix + name);
        if ((fallback is !null)) { return fallback; }
    }

    let g_info: Optional(SymbolInfo) = c.global_symbol_table.lookup(name);
    if ((g_info is !null)) { return g_info; }

    let mapped_global: Optional(String) = c.current_file_global_aliases.lookup(name);
    if (mapped_global is !null) {
        let alias_info: Optional(SymbolInfo) = c.global_symbol_table.lookup(mapped_global);
        if ((alias_info is !null)) { return alias_info; }
    }

    let g_alias: Optional(String) = c.global_var_aliases.lookup(name);
    if (g_alias is !null) {
        let alias_info: Optional(SymbolInfo) = c.global_symbol_table.lookup(g_alias);
        if ((alias_info is !null)) { return alias_info; }
    }

    return null;
}

func update_symbol(ref c: Compiler, name: String, info: SymbolInfo) -> Void {
    let curr: Scope = c.symbol_table;
    while true {
        if ((scope_lookup(curr, name) is !null)) {
            scope_put(curr, name, info);
            return;
        }
        if (curr.parent < 0) {
            break;
        }
        curr = c.scope_stack[curr.parent];
    }

    if (c.current_package_prefix != "") {
        let qualified: String = c.current_package_prefix + name;
        if ((c.global_symbol_table.lookup(qualified) is !null)) {
            c.global_symbol_table.put(qualified, info);
            return;
        }
    }

    if ((c.global_symbol_table.lookup(name) is !null)) {
        c.global_symbol_table.put(name, info);
        return;
    }

    let mapped_global: Optional(String) = c.current_file_global_aliases.lookup(name);
    if (mapped_global is !null && (c.global_symbol_table.lookup(mapped_global) is !null)) {
        c.global_symbol_table.put(mapped_global, info);
        return;
    }

    let global_alias: Optional(String) = c.global_var_aliases.lookup(name);
    if (global_alias is !null && (c.global_symbol_table.lookup(global_alias) is !null)) {
        c.global_symbol_table.put(global_alias, info);
    }
}

func find_field(found: Optional(StructInfo), name: String) -> Optional(FieldInfo) {
    if (found is null) {
        return null;
    }
    let s_info: StructInfo = found;
    let fields: Vector(Struct) = s_info.fields;
    let len: Int = fields.length();
    let i: Int = 0;
    while (i < len) {
        let curr: FieldInfo = fields[i];
        if (curr.name == name) { return curr; }
        i += 1;
    }
    return null;
}

func get_field_by_index(found: Optional(StructInfo), index: Int) -> Optional(FieldInfo) {
    if (found is null) { return null; }
    let s_info: StructInfo = found;
    let fields: Vector(Struct) = s_info.fields;
    let len: Int = fields.length();
    if (index >= 0 && index < len) {
        let field: FieldInfo = fields[index];
        return field;
    }
    return null;
}

func export_module_symbols(ref c: Compiler, prefix: String, as_submodule: Bool, module_name: String) -> Void {
    if (c.current_package_prefix == "" || !c.current_module_is_package) { return; }
    if (as_submodule && module_name.starts_with("__")) {
        return;
    }

    let p_len: Int = prefix.length();
    let export_prefix: String = c.current_package_prefix;
    if as_submodule { export_prefix = c.current_package_prefix + module_name + "."; }

    let f_cap: Int = c.func_table.capacity;
    let k: Int = 0;
    while (k < f_cap) {
        if (c.func_table.hashes[k] >= 2) {
            let f_key: String = c.func_table.keys[k];
            if (f_key.starts_with(prefix)) {
                let bare_name: String = f_key.slice(p_len, f_key.length());
                if (!bare_name.starts_with("__")) {
                    c.global_func_aliases.put(export_prefix + bare_name, f_key);
                }
            }
        }
        k += 1;
    }

    let s_cap: Int = c.struct_table.capacity;
    k = 0;
    while (k < s_cap) {
        if (c.struct_table.hashes[k] >= 2) {
            let s_key: String = c.struct_table.keys[k];
            if (s_key.starts_with(prefix)) {
                let bare_name: String = s_key.slice(p_len, s_key.length());
                if (!bare_name.starts_with("__")) {
                    c.global_type_aliases.put(export_prefix + bare_name, s_key);
                }
            }
        }
        k += 1;
    }

    let nt_cap: Int = c.named_types.capacity;
    k = 0;
    while (k < nt_cap) {
        if (c.named_types.hashes[k] >= 2) {
            let type_key: String = c.named_types.keys[k];
            if (type_key.starts_with(prefix)) {
                let bare_name: String = type_key.slice(p_len, type_key.length());
                if (!bare_name.starts_with("__")) {
                    c.global_type_aliases.put(export_prefix + bare_name, type_key);
                }
            }
        }
        k += 1;
    }

    let gs_cap: Int = c.generic_structs.capacity;
    k = 0;
    while (k < gs_cap) {
        if (c.generic_structs.hashes[k] >= 2) {
            let s_key: String = c.generic_structs.keys[k];
            if (s_key.starts_with(prefix)) {
                let bare_name: String = s_key.slice(p_len, s_key.length());
                if (!bare_name.starts_with("__")) {
                    c.global_type_aliases.put(export_prefix + bare_name, s_key);
                }
            }
        }
        k += 1;
    }

    let g_cap: Int = c.global_symbol_table.capacity;
    k = 0;
    while (k < g_cap) {
        if (c.global_symbol_table.hashes[k] >= 2) {
            let g_key: String = c.global_symbol_table.keys[k];
            if (g_key.starts_with(prefix)) {
                let bare_name: String = g_key.slice(p_len, g_key.length());
                if (!bare_name.starts_with("__")) {
                    c.global_var_aliases.put(export_prefix + bare_name, g_key);
                }
            }
        }
        k += 1;
    }

    let af_cap: Int = c.global_func_aliases.capacity;
    k = 0;
    while (k < af_cap) {
        if (c.global_func_aliases.hashes[k] >= 2) {
            let a_key: String = c.global_func_aliases.keys[k];
            if (a_key.starts_with(prefix)) {
                let bare_name: String = a_key.slice(p_len, a_key.length());
                if (!bare_name.starts_with("__")) {
                    let real_target: String = c.global_func_aliases.values[k];
                    c.global_func_aliases.put(export_prefix + bare_name, real_target);
                }
            }
        }
        k += 1;
    }

    let at_cap: Int = c.global_type_aliases.capacity;
    k = 0;
    while (k < at_cap) {
        if (c.global_type_aliases.hashes[k] >= 2) {
            let a_key: String = c.global_type_aliases.keys[k];
            if (a_key.starts_with(prefix)) {
                let bare_name: String = a_key.slice(p_len, a_key.length());
                if (!bare_name.starts_with("__")) {
                    let real_target: String = c.global_type_aliases.values[k];
                    c.global_type_aliases.put(export_prefix + bare_name, real_target);
                }
            }
        }
        k += 1;
    }

    let av_cap: Int = c.global_var_aliases.capacity;
    k = 0;
    while (k < av_cap) {
        if (c.global_var_aliases.hashes[k] >= 2) {
            let a_key: String = c.global_var_aliases.keys[k];
            if (a_key.starts_with(prefix)) {
                let bare_name: String = a_key.slice(p_len, a_key.length());
                if (!bare_name.starts_with("__")) {
                    let real_target: String = c.global_var_aliases.values[k];
                    c.global_var_aliases.put(export_prefix + bare_name, real_target);
                }
            }
        }
        k += 1;
    }
}

func report_import_collision(ref c: Compiler, pos: Position, kind: String, name: String) -> Void {
// imports are bound in both passes, only codegen emits diagnostics
    if (!c.is_precompile_phase) {
        throw_import_error(pos, "Name collision for " + kind + " '" + name + "'. Please use explicit alias.");
    }
}

func is_direct_export(name: String) -> Bool {
    let i: Int = 0;
    while (i < name.length()) {
        if (name[i] == '.') { return false; }
        i += 1;
    }
    return true;
}

func bind_import_symbols(ref c: Compiler, node: ImportNode, prefix: String, include_submodules: Bool, keep_existing: Bool) -> Void {
    let symbols: Vector(ImportSymbolNode) = node.symbols;
    let s_len: Int = symbols.length();
    let i: Int = 0;

    while (i < s_len) {
        let curr_sym: ImportSymbolNode = symbols[i];

        if (curr_sym.name_tok.type == WhitelangTokens.TOK_MUL) {
            if (prefix == "") {
                i += 1;
                continue;
            }

            let p_len: Int = prefix.length();

            let f_cap: Int = c.func_table.capacity;
            let k: Int = 0;
            while (k < f_cap) {
                if (c.func_table.hashes[k] >= 2) {
                    let f_key: String = c.func_table.keys[k];
                    if (f_key.starts_with(prefix)) {
                        let bare_name: String = f_key.slice(p_len, f_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_f: Optional(String) = c.current_file_func_aliases.lookup(bare_name);
                            if (existing_f is !null && keep_existing) {
                            } else if (existing_f is !null && existing_f != f_key) {
                                report_import_collision(ref c, node.pos, "function", bare_name);
                            } else {
                                c.current_file_func_aliases.put(bare_name, f_key);
                            }
                        }
                    }
                }
                k += 1;
            }

            let gf_cap: Int = c.generic_funcs.capacity;
            k = 0;
            while (k < gf_cap) {
                if (c.generic_funcs.hashes[k] >= 2) {
                    let f_key: String = c.generic_funcs.keys[k];
                    if (f_key.starts_with(prefix)) {
                        let bare_name: String = f_key.slice(p_len, f_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_f: Optional(String) = c.current_file_func_aliases.lookup(bare_name);
                            if (existing_f is !null && keep_existing) {
                                /* pass */
                            } else if (existing_f is !null && existing_f != f_key) {
                                report_import_collision(ref c, node.pos, "function", bare_name);
                            } else {
                                c.current_file_func_aliases.put(bare_name, f_key);
                            }
                        }
                    }
                }
                k += 1;
            }

            let s_cap: Int = c.struct_table.capacity;
            k = 0;
            while (k < s_cap) {
                if (c.struct_table.hashes[k] >= 2) {
                    let s_key: String = c.struct_table.keys[k];
                    if (s_key.starts_with(prefix)) {
                        let bare_name: String = s_key.slice(p_len, s_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_s: Optional(String) = c.current_file_type_aliases.lookup(bare_name);
                            if (existing_s is !null && keep_existing) {
                            } else if (existing_s is !null && existing_s != s_key) {
                                report_import_collision(ref c, node.pos, "type", bare_name);
                            } else {
                                c.current_file_type_aliases.put(bare_name, s_key);
                            }
                        }
                    }
                }
                k += 1;
            }

            let nt_cap: Int = c.named_types.capacity;
            k = 0;
            while (k < nt_cap) {
                if (c.named_types.hashes[k] >= 2) {
                    let type_key: String = c.named_types.keys[k];
                    if (type_key.starts_with(prefix)) {
                        let bare_name: String = type_key.slice(p_len, type_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_s: Optional(String) = c.current_file_type_aliases.lookup(bare_name);
                            if (existing_s is !null && keep_existing) {
                            } else if (existing_s is !null && existing_s != type_key) {
                                report_import_collision(ref c, node.pos, "type", bare_name);
                            } else {
                                c.current_file_type_aliases.put(bare_name, type_key);
                            }
                        }
                    }
                }
                k += 1;
            }

            let gs_cap: Int = c.generic_structs.capacity;
            k = 0;
            while (k < gs_cap) {
                if (c.generic_structs.hashes[k] >= 2) {
                    let s_key: String = c.generic_structs.keys[k];
                    if (s_key.starts_with(prefix)) {
                        let bare_name: String = s_key.slice(p_len, s_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_s: Optional(String) = c.current_file_type_aliases.lookup(bare_name);
                            if (existing_s is !null && keep_existing) {
                                /* pass */
                            } else if (existing_s is !null && existing_s != s_key) {
                                report_import_collision(ref c, node.pos, "type", bare_name);
                            } else {
                                c.current_file_type_aliases.put(bare_name, s_key);
                            }
                        }
                    }
                }
                k += 1;
            }

            let g_cap: Int = c.global_symbol_table.capacity;
            k = 0;
            while (k < g_cap) {
                if (c.global_symbol_table.hashes[k] >= 2) {
                    let g_key: String = c.global_symbol_table.keys[k];
                    if (g_key.starts_with(prefix)) {
                        let bare_name: String = g_key.slice(p_len, g_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_g: Optional(String) = c.current_file_global_aliases.lookup(bare_name);
                            if (existing_g is !null && keep_existing) {
                            } else if (existing_g is !null && existing_g != g_key) {
                                report_import_collision(ref c, node.pos, "global", bare_name);
                            } else {
                                c.current_file_global_aliases.put(bare_name, g_key);
                            }
                        }
                    }
                }
                k += 1;
            }

            let g_f_cap: Int = c.global_func_aliases.capacity;
            k = 0;
            while (k < g_f_cap) {
                if (c.global_func_aliases.hashes[k] >= 2) {
                    let f_key: String = c.global_func_aliases.keys[k];
                    if (f_key.starts_with(prefix) && !(c.func_table.lookup(f_key) is !null)) {
                        let bare_name: String = f_key.slice(p_len, f_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_f: Optional(String) = c.current_file_func_aliases.lookup(bare_name);
                            let val: String = c.global_func_aliases.values[k];
                            if (existing_f is !null && keep_existing) {
                            } else if (existing_f is !null && existing_f != val) {
                                report_import_collision(ref c, node.pos, "function", bare_name);
                            } else {
                                c.current_file_func_aliases.put(bare_name, val);
                            }
                        }
                    }
                }
                k += 1;
            }

            let g_s_cap: Int = c.global_type_aliases.capacity;
            k = 0;
            while (k < g_s_cap) {
                if (c.global_type_aliases.hashes[k] >= 2) {
                    let s_key: String = c.global_type_aliases.keys[k];
                    if (s_key.starts_with(prefix) && !(c.struct_table.lookup(s_key) is !null)) {
                        let bare_name: String = s_key.slice(p_len, s_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_s: Optional(String) = c.current_file_type_aliases.lookup(bare_name);
                            let val: String = c.global_type_aliases.values[k];
                            if (existing_s is !null && keep_existing) {
                            } else if (existing_s is !null && existing_s != val) {
                                report_import_collision(ref c, node.pos, "type", bare_name);
                            } else {
                                c.current_file_type_aliases.put(bare_name, val);
                            }
                        }
                    }
                }
                k += 1;
            }

            let g_v_cap: Int = c.global_var_aliases.capacity;
            k = 0;
            while (k < g_v_cap) {
                if (c.global_var_aliases.hashes[k] >= 2) {
                    let v_key: String = c.global_var_aliases.keys[k];
                    if (v_key.starts_with(prefix) && !(c.global_symbol_table.lookup(v_key) is !null)) {
                        let bare_name: String = v_key.slice(p_len, v_key.length());
                        if (!bare_name.starts_with("__") && (include_submodules || is_direct_export(bare_name))) {
                            let existing_v: Optional(String) = c.current_file_global_aliases.lookup(bare_name);
                            let val: String = c.global_var_aliases.values[k];
                            if (existing_v is !null && keep_existing) {
                            } else if (existing_v is !null && existing_v != val) {
                                report_import_collision(ref c, node.pos, "global", bare_name);
                            } else {
                                c.current_file_global_aliases.put(bare_name, val);
                            }
                        }
                    }
                }
                k += 1;
            }

            if include_submodules {
                register_import_namespaces(ref c, c.current_file_func_aliases, node.pos);
                register_import_namespaces(ref c, c.current_file_type_aliases, node.pos);
                register_import_namespaces(ref c, c.current_file_global_aliases, node.pos);
            }
            i += 1;
            continue;
        }

        let orig_name: String = curr_sym.name_tok.value;

        if (orig_name.starts_with("__")) {
            throw_import_error(node.pos, "Cannot import '" + orig_name + "', symbol not found in module.");
            return;
        }

        let target_name: String = orig_name;

        if (curr_sym.alias_tok.value.length() != 0) {
            let a_tok: WhitelangTokens.Token = curr_sym.alias_tok;
            target_name = a_tok.value;
        }

        let lookup_name: String = prefix + orig_name;
        let found: Bool = false;

        if ((c.func_table.lookup(lookup_name) is !null) || (c.generic_funcs.lookup(lookup_name) is !null)) {
            let existing_f: Optional(String) = c.current_file_func_aliases.lookup(target_name);
            if (existing_f is !null && keep_existing) { }
            else if (existing_f is !null && existing_f != lookup_name) {
                report_import_collision(ref c, node.pos, "function", target_name);
            }
            else { c.current_file_func_aliases.put(target_name, lookup_name); }
            found = true;
        } else if (c.global_func_aliases.lookup(lookup_name) is !null) {
            let real_name: Optional(String) = c.global_func_aliases.lookup(lookup_name);
            if (real_name is null) { i++; continue; }
            let existing_f: Optional(String) = c.current_file_func_aliases.lookup(target_name);
            if (existing_f is !null && keep_existing) { }
            else if (existing_f is !null && existing_f != real_name) {
                report_import_collision(ref c, node.pos, "function", target_name);
            }
            else { c.current_file_func_aliases.put(target_name, real_name); }
            found = true;
        }
        if ((c.struct_table.lookup(lookup_name) is !null) || (c.generic_structs.lookup(lookup_name) is !null) || (c.named_types.lookup(lookup_name) is !null)) {
            let existing_s: Optional(String) = c.current_file_type_aliases.lookup(target_name);
            if (existing_s is !null && keep_existing) { }
            else if (existing_s is !null && existing_s != lookup_name) {
                report_import_collision(ref c, node.pos, "type", target_name);
            }
            else { c.current_file_type_aliases.put(target_name, lookup_name); }
            found = true;
        } else if (c.global_type_aliases.lookup(lookup_name) is !null) {
            let real_name: Optional(String) = c.global_type_aliases.lookup(lookup_name);
            if (real_name is null) { i++; continue; }
            let existing_s: Optional(String) = c.current_file_type_aliases.lookup(target_name);
            if (existing_s is !null && keep_existing) { }
            else if (existing_s is !null && existing_s != real_name) {
                report_import_collision(ref c, node.pos, "type", target_name);
            }
            else { c.current_file_type_aliases.put(target_name, real_name); }
            found = true;
        }
        if ((c.global_symbol_table.lookup(lookup_name) is !null)) {
            let existing_g: Optional(String) = c.current_file_global_aliases.lookup(target_name);
            if (existing_g is !null && keep_existing) { }
            else if (existing_g is !null && existing_g != lookup_name) {
                report_import_collision(ref c, node.pos, "global", target_name);
            }
            else { c.current_file_global_aliases.put(target_name, lookup_name); }
            found = true;
        } else if (c.global_var_aliases.lookup(lookup_name) is !null) {
            let real_name: Optional(String) = c.global_var_aliases.lookup(lookup_name);
            if (real_name is null) { i++; continue; }
            let existing_g: Optional(String) = c.current_file_global_aliases.lookup(target_name);
            if (existing_g is !null && keep_existing) { }
            else if (existing_g is !null && existing_g != real_name) {
                report_import_collision(ref c, node.pos, "global", target_name);
            }
            else { c.current_file_global_aliases.put(target_name, real_name); }
            found = true;
        }

        if (!found && !c.is_precompile_phase) {
            throw_import_error(node.pos, "Cannot import '" + orig_name + "', symbol not found in module.");
        }

        i += 1;
    }
}

func export_named_imports(ref c: Compiler, node: ImportNode) -> Void {
    if (!c.current_module_is_package || node.symbols.length() == 0) { return; }

    let i: Int = 0;
    while (i < node.symbols.length()) {
        let symbol: ImportSymbolNode = node.symbols[i];
        if (symbol.name_tok.type == WhitelangTokens.TOK_MUL) {
            return;
        }

        let target_name: String = symbol.name_tok.value;
        if (symbol.alias_tok.value.length() != 0) { target_name = symbol.alias_tok.value; }
        let export_name: String = c.current_package_prefix + target_name;

        let mapped_func: Optional(String) = c.current_file_func_aliases.lookup(target_name);
        if (mapped_func is !null) {
            c.global_func_aliases.put(export_name, mapped_func);
        }

        let mapped_type: Optional(String) = c.current_file_type_aliases.lookup(target_name);
        if (mapped_type is !null) {
            c.global_type_aliases.put(export_name, mapped_type);
        }

        let mapped_global: Optional(String) = c.current_file_global_aliases.lookup(target_name);
        if (mapped_global is !null) {
            c.global_var_aliases.put(export_name, mapped_global);
        }
        i += 1;
    }
}

func format_ast_path(ref c: Compiler, node_raw: NodeID) -> String {
    let node: Int = node_tag(node_raw);
    if (node == NODE_VAR_ACCESS) {
        let v: VarAccessNode = get_var_access_node(ref c.arena, node_raw);
        return v.name_tok.value;
    }
    if (node == NODE_FIELD_ACCESS) {
        let f: FieldAccessNode = get_field_access_node(ref c.arena, node_raw);
        return format_ast_path(ref c, f.obj) + "." + f.field_name;
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

func align_to(value: Int, alignment: Int) -> Int {
    if (alignment <= 1) { return value; }
    let remainder: Int = value % alignment;
    if (remainder == 0) { return value; }
    return value + alignment - remainder;
}

func target_i64_align() -> Int {
    if (get_target_arch() == sys.Arch.X86 && get_target_os() != sys.Os.Windows) { return 4; }
    return 8;
}

func target_i128_align() -> Int {
    if (get_target_arch() == sys.Arch.Arm) { return 8; }
    return 16;
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

func get_vector_llvm_type(ref c: Compiler, element_type: Int) -> String {
    let size_ty: String = get_size_llvm_type();
    let element_ty: String = get_llvm_type_str(ref c, element_type);
    return "{ " + size_ty + ", " + size_ty + ", " + element_ty + "* }";
}

func get_named_type(ref c: Compiler, type_id: Int) -> Optional(NamedTypeInfo) {
    if (type_id < 100) { return null; }
    return c.named_type_ids.lookup(type_id);
}

func get_repr_type(ref c: Compiler, type_id: Int) -> Int {
    if (type_id < 100) { return type_id; }
    let current: Int = type_id;
    let depth: Int = 0;
    while (depth < 64) {
        let info: Optional(NamedTypeInfo) = get_named_type(ref c, current);
        if (!(info is !null) || info.underlying_type == current) { return current; }
        current = info.underlying_type;
        depth += 1;
    }
    throw_internal_compiler_error(no_position(), "Named type representation is recursive.");
    return TYPE_POISON;
}

func is_union_type(ref c: Compiler, type_id: Int) -> Bool {
// layout and conversion probes need only membership, avoid copying metadata there
    return type_id >= 100 && c.union_types.contains_key(type_id);
}

func get_union_type(ref c: Compiler, type_id: Int) -> Optional(UnionInfo) {
    if (type_id < 100 || c.union_types.length() == 0) {
        return null;
    }
    let info: UnionInfo = c.union_types.get(type_id)?;
    catch(err) { return null; }
    return info;
}

func add_union_member(ref c: Compiler, members: Vector(Int), type_id: Int, pos: Position) -> Bool {
// aliases have already resolved, distinct named types keep their own identity
    if (type_id == TYPE_POISON) { return false; }
    if (type_id == TYPE_AUTO || type_id == TYPE_VOID || is_fallible_type(ref c, type_id)) {
        throw_type_error(pos, "Union members must be value types, got " + get_type_name(ref c, type_id) + ".");
        return false;
    }

    let found_nested: Optional(UnionInfo) = get_union_type(ref c, type_id);
    if (found_nested is !null) {
        let nested: UnionInfo = found_nested;
        let i: Int = 0;
        while (i < nested.members.length()) {
            if (!add_union_member(ref c, members, nested.members[i], pos)) { return false; }
            i++;
        }
        return true;
    }

    let i: Int = 0;
    while (i < members.length()) {
        if (members[i] == type_id) { return true; }
        i++;
    }
    members.append(type_id);
    return true;
}

func union_member_index(ref c: Compiler, union_type: Int, member_type: Int) -> Int {
    let found_union: Optional(UnionInfo) = get_union_type(ref c, union_type);
    if (found_union is null) { return -1; }
    let union: UnionInfo = found_union;
    let i: Int = 0;
    while (i < union.members.length()) {
        if (union.members[i] == member_type) { return i; }
        i++;
    }
    return -1;
}

func union_member_target(ref c: Compiler, target: Int, source: Int) -> Int {
// prefer identity, then allow one ordinary class upcast, numeric and nominal conversions stay explicit
    if (union_member_index(ref c, target, source) >= 0) { return source; }
    if (get_named_type(ref c, source) is !null) { return 0; }
    let origin = c.struct_id_map.lookup(source);
    if (origin is null || !origin.is_class) { return 0; }
    let found = get_union_type(ref c, target);
    if (found is null) { return 0; }
    let union: UnionInfo = found;
    let candidate = 0;
    let i = 0;
    while (i < union.members.length()) {
        let member = union.members[i];
        let info = c.struct_id_map.lookup(member);
        let accepts = false;
        if (info is !null) {
            accepts = (info.is_class && is_subclass(ref c, source, member)) ||
                (info.is_interface && implements_interface(ref c, source, member));
        }
        if accepts {
            if (candidate != 0) { return TYPE_POISON; }
            candidate = member;
        }
        i++;
    }
    return candidate;
}

func union_accepts_type(ref c: Compiler, target_type: Int, source_type: Int) -> Bool {
    if (target_type == source_type) { return true; }
    if (!is_union_type(ref c, target_type)) { return false; }

    let found_source: Optional(UnionInfo) = get_union_type(ref c, source_type);
    if (found_source is null) {
        let member = union_member_target(ref c, target_type, source_type);
        return member != 0 && member != TYPE_POISON;
    }
    let source: UnionInfo = found_source;
    let i: Int = 0;
    while (i < source.members.length()) {
        let member = union_member_target(ref c, target_type, source.members[i]);
        if (member == 0 || member == TYPE_POISON) {
            return false;
        }
        i++;
    }
    return true;
}

func union_vector_target(ref c: Compiler, target: Int, node: NodeID, pos: Position) -> Int {
// one container arm supplies context for [], multiple arms need an exact match
    let found_union: Optional(UnionInfo) = get_union_type(ref c, target);
    if (found_union is null) {
        throw_type_error(pos, "Expected a union type.");
        return TYPE_POISON;
    }
    let union: UnionInfo = found_union;
    let candidate: Int = 0;
    let count: Int = 0;
    let i: Int = 0;
    while (i < union.members.length()) {
        let member: Int = union.members[i];
        let array = c.array_info_map.lookup(member);
        if ((c.vector_base_map.lookup(member) is !null) || ((array is !null) && array.size >= 0)) {
            candidate = member;
            count++;
        }
        i++;
    }
    if (count == 1) { return candidate; }

    let inferred: Int = get_expr_type(ref c, node);
    if (inferred != 0 && union_member_index(ref c, target, inferred) >= 0) {
        return inferred;
    }
    throw_type_error(pos, "Cannot infer a container member for " + get_type_name(ref c, target) + ".");
    return TYPE_POISON;
}

func union_map_target(ref c: Compiler, target: Int, node: NodeID, pos: Position) -> Int {
// the annotated union chooses a typed dictionary before any keys are lowered
    let found_union: Optional(UnionInfo) = get_union_type(ref c, target);
    if (found_union is null) {
        throw_type_error(pos, "Expected a union type.");
        return TYPE_POISON;
    }
    let union: UnionInfo = found_union;
    let candidate = 0;
    let count = 0;
    let i = 0;
    while (i < union.members.length()) {
        let member = get_repr_type(ref c, union.members[i]);
        let info = c.struct_id_map.lookup(member);
        let template: Optional(GenericTemplate) = c.generic_instance_templates.lookup("" + member);
        let dynamic = (info is !null) && (info.name == "Dict" || info.name == "dict.Dict");
        let typed = (template is !null) && (template.name == "Dict" || template.name.ends_with(".Dict"));
        if (dynamic || typed) {
            candidate = union.members[i];
            count++;
        }
        i++;
    }
    if (count == 1) { return candidate; }
    let inferred = get_expr_type(ref c, node);
    if (count > 1 && inferred != 0 && union_member_index(ref c, target, inferred) >= 0) { return inferred; }
    throw_type_error(pos, "Cannot infer a dictionary member for " + get_type_name(ref c, target) + ".");
    return TYPE_POISON;
}

func get_union_layout(ref c: Compiler, type_id: Int) -> UnionLayout {
// the tag selects the live member, the payload reserves its size and alignment
    let found_union: Optional(UnionInfo) = get_union_type(ref c, type_id);
    if (found_union is null) { return UnionLayout(valid=false, size=0, alignment=0, payload_offset=0, payload_type=0, payload_count=0); }
    let union: UnionInfo = found_union;

    let payload_size: Int = 0;
    let payload_align: Int = 1;
    let i: Int = 0;
    while (i < union.members.length()) {
        let member: Int = union.members[i];
        // Null has no payload, its tag distinguishes it from nullable members.
        if (member != TYPE_NULL) {
            let size: Int = get_type_size_bytes(ref c, member);
            let alignment: Int = get_type_align_bytes(ref c, member);
            if (size > payload_size) { payload_size = size; }
            if (alignment > payload_align) { payload_align = alignment; }
        }
        i++;
    }

    let carrier: Int = TYPE_BYTE;
    if (payload_align == 2) { carrier = TYPE_UINT16; }
    else if (payload_align == 4) { carrier = TYPE_UINT32; }
    else if (payload_align == 8) { carrier = TYPE_UINT64; }
    else if (payload_align == 16) { carrier = TYPE_UINT128; }
    else if (payload_align != 1) {
        throw_type_error(union.pos, "Unsupported union payload alignment.");
        return UnionLayout(valid=false, size=0, alignment=0, payload_offset=0, payload_type=0, payload_count=0);
    }

    let carrier_size: Int = get_type_size_bytes(ref c, carrier);
    let alignment: Int = payload_align;
    if (alignment < 4) { alignment = 4; }
    let offset: Int = align_to(4, payload_align);
    if (payload_size < 0 || payload_size > 2147483647 - carrier_size - offset - alignment) {
        throw_type_error(union.pos, "Union storage exceeds the supported size.");
        return UnionLayout(valid=false, size=0, alignment=0, payload_offset=0, payload_type=0, payload_count=0);
    }

    let count: Int = (payload_size + carrier_size - 1) / carrier_size;
    let size: Int = align_to(offset + count * carrier_size, alignment);
    return UnionLayout(valid=true, size=size, alignment=alignment,
        payload_offset=offset, payload_type=carrier, payload_count=count);
}

func get_union_llvm_storage(ref c: Compiler, type_id: Int) -> String {
    let layout: UnionLayout = get_union_layout(ref c, type_id);
    if (!layout.valid) { return "void"; }
    return "{ i32, [" + layout.payload_count + " x " + get_llvm_type_str(ref c, layout.payload_type) + "] }";
}

func type_key_before(left: String, right: String) -> Bool {
    let count: Int = left.length();
    if (right.length() < count) { count = right.length(); }
    let i: Int = 0;
    while (i < count) {
        if (left[i] != right[i]) { return left[i] < right[i]; }
        i++;
    }
    return left.length() < right.length();
}

func get_union_type_id(ref c: Compiler, members: Vector(Int), pos: Position) -> Int {
// sort by type spelling in the ABI, discovery order must not change a union's tag order
    if (members.length() == 0) {
        throw_type_error(pos, "A union must contain a value type.");
        return TYPE_POISON;
    }
    if (members.length() == 1) { return members[0]; }
    let keys: Vector(String) = [];
    let i: Int = 0;
    while (i < members.length()) {
        keys.append(mangle_type(ref c, members[i]));
        i++;
    }
    i = 1;
    while (i < members.length()) {
        let member: Int = members[i];
        let key: String = keys[i];
        let j: Int = i;
        while (j > 0 && type_key_before(key, keys[j - 1])) {
            members[j] = members[j - 1];
            keys[j] = keys[j - 1];
            j--;
        }
        members[j] = member;
        keys[j] = key;
        i++;
    }

    let key: String = "U" + members.length() + "_";
    i = 0;
    while (i < keys.length()) {
        key += "" + keys[i].length() + "_" + keys[i];
        i++;
    }
    let cached: Optional(SymbolInfo) = c.union_cache.lookup(key);
    if ((cached is !null)) { return cached.type; }

    let type_id: Int = c.type_counter;
    c.type_counter++;
    c.union_types.put(type_id, UnionInfo(members=members, key=key, pos=pos));
    c.union_cache.put(key, SymbolInfo(type=type_id, reg="", origin_type=0, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    c.type_revision++;
    return type_id;
}

func instantiate_alias(ref c: Compiler, template: GenericTemplate, concrete: Vector(Struct), key: String, pos: Position) -> Int {
// reuse the template's import context, T belongs to this alias even when its caller has a T
    if (c.generic_depth >= 64) {
        throw_type_error(pos, "Generic instantiation depth exceeds 64.");
        return TYPE_POISON;
    }
    c.generic_instances.put(key, SymbolInfo(type=TYPE_POISON, reg="", origin_type=0, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    c.generic_depth++;
    let bindings: Dict(String, SymbolInfo) = generic_bindings(template.type_params, concrete);
    if (!check_generic_constraints(ref c, template, bindings, concrete, pos)) {
        c.generic_depth--;
        c.generic_instances.remove(key);
        return TYPE_POISON;
    }

    let old_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
    let previous: GenericTemplate = use_generic_context(ref c, template, bindings);
    let decl: TypeDeclNode = get_type_decl_node(ref c.arena, template.node);
    let target: Int = resolve_type(ref c, decl.target_type);
    c.generic_depth--;
    restore_generic_context(ref c, previous, old_bindings);

    if (target == TYPE_AUTO) {
        throw_type_error(decl.pos, "A type declaration cannot use Auto as its underlying type.");
        target = TYPE_POISON;
    }
    if (target == TYPE_POISON) {
        c.generic_instances.remove(key);
        return TYPE_POISON;
    }
    c.generic_instances.put(key, SymbolInfo(type=target, reg="", origin_type=0, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    return target;
}

func resolve_named_type(ref c: Compiler, found: Optional(NamedTypeInfo)) -> Int {
    if (found is null) { return TYPE_POISON; }
    let info: NamedTypeInfo = found;
    if (info.resolved) { return info.type_id; }
    if (info.resolving) {
        throw_type_error(info.pos, "Type declaration for '" + info.name + "' is recursive.");
        return TYPE_POISON;
    }

    info.resolving = true;
    store_named_type(ref c, info);
    let target: Int = resolve_type(ref c, info.target_node);
    info.resolving = false;
    if (target == TYPE_POISON || target == TYPE_AUTO) {
        if (target == TYPE_AUTO) {
            throw_type_error(info.pos, "A type declaration cannot use Auto as its underlying type.");
        }
        info.type_id = TYPE_POISON;
        store_named_type(ref c, info);
        return TYPE_POISON;
    }

    if (info.is_alias) {
        info.type_id = target;
        info.underlying_type = get_repr_type(ref c, target);
    } else {
        if (target == TYPE_VOID || is_fallible_type(ref c, target)) {
            throw_type_error(info.pos, "Type '" + info.name + "' requires a concrete non-fallible underlying type.");
            info.type_id = TYPE_POISON;
            store_named_type(ref c, info);
            return TYPE_POISON;
        }
        if (target == info.type_id) {
            throw_type_error(info.pos, "Type declaration for '" + info.name + "' is recursive.");
            info.type_id = TYPE_POISON;
            store_named_type(ref c, info);
            return TYPE_POISON;
        }
        info.underlying_type = target;
    }
    info.resolved = true;
    store_named_type(ref c, info);
    return info.type_id;
}

func get_llvm_type_str(ref c: Compiler, type_id: Int) -> String {
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, type_id);
    if ((named is !null)) {
        return get_llvm_type_str(ref c, named.underlying_type);
    }
    let union: Bool = is_union_type(ref c, type_id);
    if (union) {
        return get_union_llvm_storage(ref c, type_id);
    }
    if (type_id == TYPE_NULL) { return "i8*"; }
    if (type_id == TYPE_INT) {
        return "i32";
    }
    if (type_id == TYPE_LONG) {
        return "i64";
    }
    if (type_id == TYPE_BYTE)  { return "i8"; }
    if (type_id == TYPE_FLOAT) {
        return "double";
    }
    if (type_id == TYPE_BOOL) {
        return "i1";
    }
    if (type_id == TYPE_VOID)  { return "void"; }
    if (type_id == TYPE_STRING) {
        return "%struct.$String*";
    }
    if (type_id == TYPE_CHAR) {
        return "i32";
    }
    if (type_id == TYPE_GENERIC_STRUCT) { return "i8*"; }
    if (type_id == TYPE_GENERIC_FUNCTION) {
        return "i8*";
    }
    if (type_id == TYPE_GENERIC_CLASS) {
        return "i8*";
    }
    if (type_id == TYPE_GENERIC_METHOD) { return "i8*"; }
    if (type_id == TYPE_GENERIC_ENUM) {
        return "i32";
    }
    if (type_id == TYPE_ANYPTR) {
        return "i8*";
    }
    if (type_id == TYPE_ANY_ERROR) { return "{ i64, i32 }"; }

    if (type_id == TYPE_POISON) { return "void"; } // dummy type for poison variables

    if (type_id == TYPE_INT8) {
        return "i8";
    }
    if (type_id == TYPE_INT16) {
        return "i16";
    }
    if (type_id == TYPE_INT128) {
        return "i128";
    }
    if (type_id == TYPE_UINT16) {
        return "i16";
    }
    if (type_id == TYPE_UINT32){ return "i32"; }
    if (type_id == TYPE_UINT64) {
        return "i64";
    }
    if (type_id == TYPE_UINT128) {
        return "i128";
    }
    if (type_id == TYPE_FLOAT32){ return "float"; }
    if (type_id == TYPE_INTSIZE || type_id == TYPE_UINTSIZE) {
        return get_size_llvm_type();
    }

    let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
    if ((arr_info is !null)) {
        if (arr_info.size == -1) {
            return arr_info.llvm_name + "*";
        }
        return arr_info.llvm_name;
    }

    if (type_id >= 100) {
        let f_info: Optional(SymbolInfo) = c.func_ret_map.lookup(type_id);
        if ((f_info is !null)) {
            return "i8*";
        }

        let m_info: Optional(SymbolInfo) = c.method_ret_map.lookup(type_id);
        if ((m_info is !null)) {
            return "i8*";
        }

        let ptr_info: Optional(SymbolInfo) = c.ptr_base_map.lookup(type_id);
        if ((ptr_info is !null)) {
            if (ptr_info.type == TYPE_VOID) {
                return "i8*";
            }
            return get_llvm_type_str(ref c, ptr_info.type) + "*";
        }

        let s_info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
        if ((s_info is !null)) {
            if (s_info.is_enum) {
                return "i32";
            }
            if (s_info.is_interface) { return "{ i8*, i8* }"; }
            if (s_info.is_class) {
                return s_info.llvm_name + "*";
            }
            return s_info.llvm_name;
        }

        let v_info: Optional(SymbolInfo) = c.vector_base_map.lookup(type_id);
        if ((v_info is !null)) {
            return get_vector_llvm_type(ref c, v_info.type) + "*";
        }

        let fll_info: Optional(SymbolInfo) = c.fallible_base_map.lookup(type_id);
        if ((fll_info is !null)) {
            if (fll_info.type == TYPE_VOID) {
                return "{ i1, { i64, i32 } }";
            }
            let elem_ty: String = get_llvm_type_str(ref c, fll_info.type);
            return "{ i1, { i64, i32 }, " + elem_ty + " }";
        }
    }

    throw_internal_compiler_error(no_position(), "Unknown type id " + type_id + " reached LLVM lowering.");
    return "void";
}

func get_type_name(ref c: Compiler, type_id: Int) -> String {
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, type_id);
    if ((named is !null)) { return named.name; }
    let found_union: Optional(UnionInfo) = get_union_type(ref c, type_id);
    if (found_union is !null) {
        let union: UnionInfo = found_union;
        let name: String = "";
        let i: Int = 0;
        while (i < union.members.length()) {
            if (i > 0) { name += " | "; }
            name += get_type_name(ref c, union.members[i]);
            i++;
        }
        return "(" + name + ")";
    }
    if (type_id == TYPE_INT) {
        return "Int";
    }
    if (type_id == TYPE_LONG)  { return "Long"; }
    if (type_id == TYPE_BYTE) {
        return "Byte";
    }
    if (type_id == TYPE_FLOAT) {
        return "Float";
    }
    if (type_id == TYPE_BOOL) {
        return "Bool";
    }
    if (type_id == TYPE_VOID) {
        return "Void";
    }
    if (type_id == TYPE_STRING) {
        return "String";
    }
    if (type_id == TYPE_CHAR) {
        return "Char";
    }
    if (type_id == TYPE_NULL) {
        return "Null";
    }
    if (type_id == TYPE_NULLPTR){ return "nullptr"; }
    if (type_id == TYPE_POISON) {
        return "Poison";
    }
    if (type_id == TYPE_GENERIC_STRUCT) {
        return "Struct";
    }
    if (type_id == TYPE_GENERIC_FUNCTION) { return "Function"; }
    if (type_id == TYPE_GENERIC_CLASS) {
        return "Class";
    }
    if (type_id == TYPE_GENERIC_METHOD) {
        return "Method";
    }
    if (type_id == TYPE_GENERIC_ENUM) { return "Enum"; }
    if (type_id == TYPE_AUTO) {
        return "Auto";
    }
    if (type_id == TYPE_ANYPTR) {
        return "AnyPtr";
    }
    if (type_id == TYPE_ANY_ERROR) { return "AnyError"; }

    if (type_id == TYPE_INT8) {
        return "Int8";
    }
    if (type_id == TYPE_INT16) {
        return "Int16";
    }
    if (type_id == TYPE_INT128) {
        return "Int128";
    }
    if (type_id == TYPE_UINT16) {
        return "UInt16";
    }
    if (type_id == TYPE_UINT32) {
        return "UInt32";
    }
    if (type_id == TYPE_UINT64) {
        return "UInt64";
    }
    if (type_id == TYPE_UINT128) {
        return "UInt128";
    }
    if (type_id == TYPE_FLOAT32) {
        return "Float32";
    }
    if (type_id == TYPE_INTSIZE) {
        return "IntSize";
    }
    if (type_id == TYPE_UINTSIZE){ return "UIntSize"; }

    if (type_id >= 100) {
        let generic_name: Optional(StringConstant) = c.generic_type_names.lookup("" + type_id);
        if ((generic_name is !null)) { return generic_name.value; }

        let f_info: Optional(SymbolInfo) = c.func_ret_map.lookup(type_id);
        if ((f_info is !null)) {
            let meta_f_info: SymbolInfo = f_info;
            let sig: String = "Function(";
            let a_idx: Int = 0;
            if (meta_f_info.func_arg_types is !null) {
                let len: Int = meta_f_info.func_arg_types.length();
                while (a_idx < len) {
                    let a_node: TypeListNode = meta_f_info.func_arg_types[a_idx];
                    if (a_idx > 0) { sig += ", "; }
                    if (a_idx < meta_f_info.arg_names.length() && meta_f_info.arg_names[a_idx].length() > 0) {
                        sig += meta_f_info.arg_names[a_idx] + ": ";
                    }
                    if (a_node.pass_mode == PARAM_REF) { sig += "ref "; }
                    if (meta_f_info.variadic_param == a_idx + 1) {
                        let pack: Optional(ArrayInfo) = c.array_info_map.lookup(a_node.type);
                        if (pack is null) { return "<invalid callable>"; }
                        sig += get_type_name(ref c, pack.base_type) + "...";
                    } else {
                        sig += get_type_name(ref c, a_node.type);
                    }
                    a_idx += 1;
                }
            }
            sig += ") -> " + get_type_name(ref c, meta_f_info.type);
            return sig;
        }

        let m_info: Optional(SymbolInfo) = c.method_ret_map.lookup(type_id);
        if ((m_info is !null)) {
            let meta_m_info: SymbolInfo = m_info;
            let sig: String = "Method(";
            let a_idx: Int = 0;
            if (meta_m_info.func_arg_types is !null) {
                let len: Int = meta_m_info.func_arg_types.length();
                while (a_idx < len) {
                    let a_node: TypeListNode = meta_m_info.func_arg_types[a_idx];
                    if (a_idx > 0) { sig += ", "; }
                    if (a_idx < meta_m_info.arg_names.length() && meta_m_info.arg_names[a_idx].length() > 0) {
                        sig += meta_m_info.arg_names[a_idx] + ": ";
                    }
                    if (a_node.pass_mode == PARAM_REF) { sig += "ref "; }
                    if (meta_m_info.variadic_param == a_idx + 1) {
                        let pack: Optional(ArrayInfo) = c.array_info_map.lookup(a_node.type);
                        if (pack is null) { return "<invalid callable>"; }
                        sig += get_type_name(ref c, pack.base_type) + "...";
                    } else {
                        sig += get_type_name(ref c, a_node.type);
                    }
                    a_idx += 1;
                }
            }
            sig += ") -> " + get_type_name(ref c, meta_m_info.type);
            return sig;
        }

        let s_info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
        if ((s_info is !null)) { return s_info.name; }

        let ptr_info: Optional(SymbolInfo) = c.ptr_base_map.lookup(type_id);
        if ((ptr_info is !null)) {
            return "Ptr<" + get_type_name(ref c, ptr_info.type) + ">";
        }

        let v_info: Optional(SymbolInfo) = c.vector_base_map.lookup(type_id);
        if ((v_info is !null)) {
            return "Vector(" + get_type_name(ref c, v_info.type) + ")";
        }

        let fll_info: Optional(SymbolInfo) = c.fallible_base_map.lookup(type_id);
        if ((fll_info is !null)) {
            return get_type_name(ref c, fll_info.type) + "?";
        }

        let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
        if ((arr_info is !null)) {
            return get_type_name(ref c, arr_info.base_type) + "[" + arr_info.size + "]";
        }
    }

    return "Unknown";
}

func is_pointer_type(ref c: Compiler, type_id: Int) -> Bool {
    if (type_id < 100) { return type_id == TYPE_NULLPTR || type_id == TYPE_ANYPTR; }
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, type_id);
    if ((named is !null)) {
        return is_pointer_type(ref c, named.underlying_type);
    }
    return c.ptr_base_map.contains_key(type_id);
}

func is_fallible_type(ref c: Compiler, type_id: Int) -> Bool {
    if (type_id < 100) { return false; }
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, type_id);
    if ((named is !null)) {
        return is_fallible_type(ref c, named.underlying_type);
    }
    return c.fallible_base_map.contains_key(type_id);
}

func is_error_type(ref c: Compiler, type_id: Int) -> Bool {
    if (type_id < 100) { return type_id == TYPE_ANY_ERROR; }
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, type_id);
    if ((named is !null)) {
        return is_error_type(ref c, named.underlying_type);
    }
    let info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    return (info is !null) && info.is_enum && info.is_error;
}

func get_inner_fallible_type(ref c: Compiler, type_id: Int) -> Int {
    if (type_id >= 100) {
        let info: Optional(SymbolInfo) = c.fallible_base_map.lookup(type_id);
        if ((info is !null)) { return info.type; }
    }
    return TYPE_POISON;
}

func is_void_ptr(ref c: Compiler, type_id: Int) -> Bool {
    if (type_id < 100) { return type_id == TYPE_ANYPTR; }
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, type_id);
    if ((named is !null)) {
        return is_void_ptr(ref c, named.underlying_type);
    }
    let base_info: Optional(SymbolInfo) = c.ptr_base_map.lookup(type_id);
    return (base_info is !null) && base_info.type == TYPE_VOID;
}

func is_value_struct(ref c: Compiler, type_id: Int) -> Bool {
    if (type_id < 100) { return false; }
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, type_id);
    if ((named is !null)) {
        return is_value_struct(ref c, named.underlying_type);
    }
    let info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    return (info is !null) && !info.is_class && !info.is_enum && !info.is_interface;
}

func is_ref_type(ref c: Compiler, type_id: Int) -> Bool {
    // builtin IDs have no declaration metadata, avoid constructing empty named records.
    if (type_id < 100) {
        return type_id == TYPE_STRING || type_id == TYPE_GENERIC_STRUCT || type_id == TYPE_GENERIC_FUNCTION ||
               type_id == TYPE_GENERIC_CLASS || type_id == TYPE_GENERIC_METHOD;
    }
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, type_id);
    if ((named is !null)) {
        return is_ref_type(ref c, named.underlying_type);
    }
    let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
    if ((arr_info is !null)) {
        return arr_info.size == -1;
    }
    let s_info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if ((s_info is !null)) {
        if (s_info.is_enum) { return false; }
        return s_info.is_class || s_info.is_interface;
    }

    return c.vector_base_map.contains_key(type_id) || c.func_ret_map.contains_key(type_id) ||
           c.method_ret_map.contains_key(type_id);
}

func needs_native_check(ref c: Compiler, type_id: Int) -> Bool {
// inline storage can carry non-null references even when its outer type is a value
    if (is_ref_type(ref c, type_id)) { return true; }
    let repr = get_repr_type(ref c, type_id);
    if (is_union_type(ref c, repr)) { return true; }
    if (is_fallible_type(ref c, repr)) {
        return needs_native_check(ref c, get_inner_fallible_type(ref c, repr));
    }
    let array = c.array_info_map.lookup(repr);
    if (array is !null && array.size >= 0) {
        return needs_native_check(ref c, array.base_type);
    }
    if (is_value_struct(ref c, repr)) {
        let info = c.struct_id_map.lookup(repr);
        let i = 0;
        while (info is !null && i < info.fields.length()) {
            let field: FieldInfo = info.fields[i];
            if (needs_native_check(ref c, field.type)) { return true; }
            i++;
        }
    }
    return false;
}

func needs_drop(ref c: Compiler, type_id: Int) -> Bool {
    if (type_id < 100) { return is_ref_type(ref c, type_id); }
    if (type_id > c.type_counter) {
        return type_needs_drop(ref c, type_id);
    }

    // declarations can gain fields while generic instances are being completed.
    // the stamp also covers new pointer, array and callable IDs.
    let stamp: Int = c.type_revision + c.type_counter + 1;
    while (c.drop_cache.length() <= type_id) { c.drop_cache.append(0); }
    let cached: Int = c.drop_cache[type_id];
    if (cached == stamp) { return true; }
    if (cached == -stamp) { return false; }

    let result: Bool = type_needs_drop(ref c, type_id);
    if result { c.drop_cache[type_id] = stamp; }
    else { c.drop_cache[type_id] = -stamp; }
    return result;
}

func type_needs_drop(ref c: Compiler, type_id: Int) -> Bool {
    let repr: Int = get_repr_type(ref c, type_id);
    if (repr != type_id) { return needs_drop(ref c, repr); }
    let found_union: Optional(UnionInfo) = get_union_type(ref c, type_id);
    if (found_union is !null) {
        let union: UnionInfo = found_union;
        let i: Int = 0;
        while (i < union.members.length()) {
            if (needs_drop(ref c, union.members[i])) { return true; }
            i++;
        }
        return false;
    }
    if (is_ref_type(ref c, type_id)) { return true; }
    if (is_fallible_type(ref c, type_id)) {
        return needs_drop(ref c, get_inner_fallible_type(ref c, type_id));
    }
    let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
    if ((arr_info is !null) && arr_info.size >= 0) {
        return needs_drop(ref c, arr_info.base_type);
    }
    if (is_value_struct(ref c, type_id)) {
        let info: Optional(StructInfo) = c.struct_id_map.lookup(get_repr_type(ref c, type_id));
        let i: Int = 0;
        while ((info is !null) && i < info.fields.length()) {
            let field: FieldInfo = info.fields[i];
            if (needs_drop(ref c, field.type)) { return true; }
            i += 1;
        }
    }
    return false;
}

func result_owns_value(ref c: Compiler, type_id: Int) -> Bool {
    return needs_drop(ref c, type_id);
}

func is_signed_integer(t: Int) -> Bool {
    return t == TYPE_INT || t == TYPE_LONG ||
           t == TYPE_INT8 || t == TYPE_INT16 || t == TYPE_INT128 ||
           t == TYPE_INTSIZE;
}

func is_unsigned_integer(t: Int) -> Bool {
    return t == TYPE_BYTE || t == TYPE_CHAR ||
           t == TYPE_UINT16 || t == TYPE_UINT32 || t == TYPE_UINT64 || t == TYPE_UINT128 ||
           t == TYPE_UINTSIZE;
}

func is_integer_type(t: Int) -> Bool {
    return is_signed_integer(t) || is_unsigned_integer(t);
}

func is_numeric_type(t: Int) -> Bool {
    return is_integer_type(t) || t == TYPE_FLOAT || t == TYPE_FLOAT32;
}

func is_primitive_type(t: Int) -> Bool {
// these values never carry ARC ownership
    return is_numeric_type(t) || t == TYPE_BOOL || t == TYPE_ANY_ERROR;
}

func is_small_primitive_type(t: Int) -> Bool {
    return t == TYPE_BOOL ||
           t == TYPE_BYTE || t == TYPE_CHAR ||
           t == TYPE_INT || t == TYPE_INT8 || t == TYPE_INT16 ||
           t == TYPE_UINT16 || t == TYPE_UINT32;
}

func is_nullable_reference_type(ref c: Compiler, t: Int) -> Bool {
// inactive storage may contain zero bits, source values still need an explicit Null member
    return get_repr_type(ref c, t) == TYPE_NULL || union_member_index(ref c, t, TYPE_NULL) >= 0;
}

func has_reference_storage(ref c: Compiler, t: Int) -> Bool {
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, t);
    if ((named is !null)) {
        return has_reference_storage(ref c, named.underlying_type);
    }
    if (t == TYPE_NULL || t == TYPE_STRING || t == TYPE_ANYPTR || t == TYPE_NULLPTR ||
        t == TYPE_GENERIC_STRUCT || t == TYPE_GENERIC_CLASS ||
        t == TYPE_GENERIC_FUNCTION || t == TYPE_GENERIC_METHOD) {
        return true;
    }

    if (t < 100) { return false; }
    let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(t);
    if ((arr_info is !null)) {
        return arr_info.size == -1;
    }
    if ((c.fallible_base_map.lookup(t) is !null)) { return false; }
    if ((c.ptr_base_map.lookup(t) is !null)) { return true; }
    if ((c.vector_base_map.lookup(t) is !null)) { return true; }
    if ((c.func_ret_map.lookup(t) is !null)) { return true; }
    if ((c.method_ret_map.lookup(t) is !null)) { return true; }

    let s_info: Optional(StructInfo) = c.struct_id_map.lookup(t);
    return (s_info is !null) && (s_info.is_class || s_info.is_interface);
}

func get_ptr_type_id(ref c: Compiler, base_id: Int) -> Int {
    let key: String = "ptr_" + base_id;
    let cached: Optional(SymbolInfo) = c.ptr_cache.lookup(key);
    if ((cached is !null)) { return cached.type; }

    let new_id: Int = c.type_counter;
    c.type_counter += 1;

    c.ptr_cache.put(key, SymbolInfo(reg="", type=new_id, origin_type=0, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    c.ptr_base_map.put(new_id, SymbolInfo(reg="", type=base_id, origin_type=0, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));

    return new_id;
}

func get_fallible_type_id(ref c: Compiler, base_id: Int) -> Int {
    let key: String = "" + base_id;
    let existing: Optional(SymbolInfo) = c.fallible_cache.lookup(key);
    if ((existing is !null)) { return existing.type; }

    let new_id: Int = c.type_counter;
    c.type_counter += 1;

    let sym: SymbolInfo = SymbolInfo(reg="", type=new_id, origin_type=0, is_const=false, func_arg_types=[], is_const_access=false, is_ref_param=false, is_reference=false, arg_names=[], variadic_param=0);
    let base_sym: SymbolInfo = SymbolInfo(reg="", type=base_id, origin_type=0, is_const=false, func_arg_types=[], is_const_access=false, is_ref_param=false, is_reference=false, arg_names=[], variadic_param=0);

    c.fallible_cache.put(key, sym);
    c.fallible_base_map.put(new_id, base_sym);

    return new_id;
}

func get_func_type_id(ref c: Compiler, arg_types: Vector(Struct), ret_type_id: Int, variadic_param: Int, arg_names: Vector(String)) -> Int {
    let key: String = "func_" + ret_type_id + "_var_" + variadic_param;
    let i: Int = 0;
    while (i < arg_types.length()) {
        let arg_node: TypeListNode = arg_types[i];
        key += "_" + arg_node.pass_mode + "_" + arg_node.type;
        if (i < arg_names.length() && arg_names[i].length() > 0) {
            key += "_label_" + arg_names[i].length() + "_" + arg_names[i];
        }
        i += 1;
    }

    let cached: Optional(SymbolInfo) = c.ptr_cache.lookup(key);
    if ((cached is !null)) { return cached.type; }
    let new_id: Int = c.type_counter;
    c.type_counter += 1;

    c.func_ret_map.put(new_id, SymbolInfo(reg="", type=ret_type_id, origin_type=0, is_const=false, func_arg_types=arg_types, arg_names=arg_names, variadic_param=variadic_param, is_const_access=false, is_ref_param=false, is_reference=false));
    c.ptr_cache.put(key, SymbolInfo(reg="", type=new_id, origin_type=0, is_const=false, func_arg_types=arg_types, arg_names=arg_names, variadic_param=variadic_param, is_const_access=false, is_ref_param=false, is_reference=false));
    return new_id;
}

func get_method_type_id(ref c: Compiler, arg_types: Vector(Struct), ret_type_id: Int, variadic_param: Int, arg_names: Vector(String)) -> Int {
    let key: String = "meth_" + ret_type_id + "_var_" + variadic_param;
    let i: Int = 0;
    while (i < arg_types.length()) {
        let arg_node: TypeListNode = arg_types[i];
        key += "_" + arg_node.pass_mode + "_" + arg_node.type;
        if (i < arg_names.length() && arg_names[i].length() > 0) {
            key += "_label_" + arg_names[i].length() + "_" + arg_names[i];
        }
        i += 1;
    }

    let cached: Optional(SymbolInfo) = c.ptr_cache.lookup(key);
    if ((cached is !null)) { return cached.type; }
    let new_id: Int = c.type_counter;
    c.type_counter += 1;

    c.method_ret_map.put(new_id, SymbolInfo(reg="", type=ret_type_id, origin_type=0, is_const=false, func_arg_types=arg_types, arg_names=arg_names, variadic_param=variadic_param, is_const_access=false, is_ref_param=false, is_reference=false));
    c.ptr_cache.put(key, SymbolInfo(reg="", type=new_id, origin_type=0, is_const=false, func_arg_types=arg_types, arg_names=arg_names, variadic_param=variadic_param, is_const_access=false, is_ref_param=false, is_reference=false));
    return new_id;
}

func get_vector_type_id(ref c: Compiler, base_id: Int) -> Int {
    let key: String = "vec_" + base_id;
    let cached: Optional(SymbolInfo) = c.vector_cache.lookup(key);
    if ((cached is !null)) { return cached.type; }

    let new_id: Int = c.type_counter;
    c.type_drop_list.append(TypeListNode(type=new_id, pass_mode=0));
    c.type_counter += 1;

    c.vector_cache.put(key, SymbolInfo(reg="", type=new_id, origin_type=0, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    c.vector_base_map.put(new_id, SymbolInfo(reg="", type=base_id, origin_type=0, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));

    return new_id;
}

func get_slice_type_id(ref c: Compiler, base_id: Int) -> Int {
    let key: String = "slice_" + base_id;
    let cached: Optional(SymbolInfo) = c.array_type_cache.lookup(key);
    if ((cached is !null)) { return cached.type; }

    let new_id: Int = c.type_counter;
    c.type_counter += 1;

    let elem_ty: String = get_llvm_type_str(ref c, base_id);
    let size_ty: String = get_size_llvm_type();
    let slice_ty: String = "{ " + size_ty + ", " + size_ty + ", i8*, " + elem_ty + "**, " + size_ty + "* }";
    c.array_type_cache.put(key, SymbolInfo(reg="", type=new_id, origin_type=0, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    c.array_info_map.put(new_id, ArrayInfo(base_type=base_id, size=-1, llvm_name=slice_ty));
    return new_id;
}

func callable_param_type(ref c: Compiler, param: ParamNode) -> Int {
    let type_id: Int = resolve_type(ref c, param.type_tok);
    if (param.is_variadic && type_id != TYPE_POISON) {
        return get_slice_type_id(ref c, type_id);
    }
    return type_id;
}

func callable_param(ref c: Compiler, param: ParamNode) -> TypeListNode {
    return TypeListNode(type=callable_param_type(ref c, param), pass_mode=param.pass_mode);
}

func param_llvm_type(ref c: Compiler, param: TypeListNode) -> String {
    let llvm_type: String = get_llvm_type_str(ref c, param.type);
    if (param.pass_mode == PARAM_REF) {
        return llvm_type + "*";
    }
    return llvm_type;
}

func variadic_param_index(params: Vector(ParamNode)) -> Int {
    let i: Int = 0;
    while (i < params.length()) {
        let param: ParamNode = params[i];
        if (param.is_variadic) {
            return i + 1;
        }
        i += 1;
    }
    return 0;
}

func param_defaults(params: Vector(ParamNode)) -> Vector(NodeID) {
    let defaults: Vector(NodeID) = [];
    let i: Int = 0;
    while (i < params.length()) {
        let param: ParamNode = params[i];
        defaults.append(param.default_val);
        i += 1;
    }
    return defaults;
}

func callable_param_names(params: Vector(ParamNode)) -> Vector(String) {
    let names: Vector(String) = [];
    let variadic: Int = variadic_param_index(params);
    let i: Int = 0;
    while (i < params.length()) {
        let name: String = "";
        if (variadic > 0 && i + 1 > variadic) {
            let param: ParamNode = params[i];
            name = param.name_tok.value;
        }
        names.append(name);
        i += 1;
    }
    return names;
}

func callable_arg_names(info: FuncInfo, skip: Int) -> Vector(String) {
    let names: Vector(String) = [];
    let count: Int = info.arg_types.length() - skip;
    let i: Int = 0;
    while (i < count) {
        let name: String = "";
        if (info.variadic_param > 0 && i + 1 > info.variadic_param &&
            i + skip < info.arg_names.length()) {
            name = info.arg_names[i + skip];
        }
        names.append(name);
        i += 1;
    }
    return names;
}

func get_builtin_cast_target(name: String) -> Int {
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

func find_named_decl(ref c: Compiler, name: String) -> Optional(NamedTypeInfo) {
    let info: Optional(NamedTypeInfo) = c.named_types.lookup(c.current_package_prefix + name);
    if (!(info is !null)) { info = c.named_types.lookup(name); }
    if (!(info is !null)) {
        let mapped: Optional(String) = c.current_file_type_aliases.lookup(name);
        if (mapped is !null) { info = c.named_types.lookup(mapped); }
    }
    if (!(info is !null)) {
        let mapped: Optional(String) = c.global_type_aliases.lookup(name);
        if (mapped is !null) { info = c.named_types.lookup(mapped); }
    }
    return info;
}

func get_cast_target(ref c: Compiler, name: String) -> Int {
    let builtin: Int = get_builtin_cast_target(name);
    if (builtin != 0) { return builtin; }

    let info: Optional(NamedTypeInfo) = find_named_decl(ref c, name);
    if (!(info is !null)) { return 0; }
    let type_id: Int = resolve_named_type(ref c, info);
    if (info.is_alias && (c.struct_id_map.lookup(type_id) is !null)) { return 0; }
    return type_id;
}

func is_conversion_target(ref c: Compiler, type_id: Int) -> Bool {
    if ((get_named_type(ref c, type_id) is !null)) { return true; }
    return is_numeric_type(type_id) || type_id == TYPE_BOOL ||
           type_id == TYPE_CHAR || type_id == TYPE_STRING;
}

func conversion_method_name(target_type: Int) -> String {
    return "$type$" + target_type;
}

func method_base_name(ref c: Compiler, node: MethodDefNode) -> String {
    if (node.name_tok.value != "$type") { return node.name_tok.value; }

    let target_type: Int = resolve_type(ref c, node.return_type);
    if (is_fallible_type(ref c, target_type)) {
        target_type = get_inner_fallible_type(ref c, target_type);
    }
    return conversion_method_name(target_type);
}

func find_method(methods: Vector(Struct), name: String) -> Optional(FuncInfo) {
    let i: Int = 0;
    while (i < methods.length()) {
        let entry: FuncInfo = methods[i];
        if (entry.base_name == name) { return entry; }
        i += 1;
    }
    return null;
}

func find_class_conversion(info: Optional(StructInfo), target_type: Int) -> Optional(FuncInfo) {
    if (info is null || !info.is_class) {
        return null;
    }
    let record: StructInfo = info;

    let wanted: String = conversion_method_name(target_type);
    let i: Int = 0;
    while (i < record.vtable.length()) {
        let func_info: FuncInfo = record.vtable[i];
        if (func_info.base_name == wanted) { return func_info; }
        i += 1;
    }
    return null;
}

func needs_explicit_cast(ref c: Compiler, source_type: Int, target_type: Int) -> Bool {
    if (source_type == target_type) { return false; }
    source_type = get_repr_type(ref c, source_type);
    target_type = get_repr_type(ref c, target_type);
    if (source_type == TYPE_ANY_ERROR) { source_type = TYPE_INT; }
    let source_info: Optional(StructInfo) = c.struct_id_map.lookup(source_type);
    if ((source_info is !null) && source_info.is_enum) { source_type = TYPE_INT; }
    if (target_type == TYPE_BOOL) {
        return source_type != TYPE_BOOL;
    }
    if (target_type == TYPE_CHAR) {
        return source_type != TYPE_CHAR && source_type != TYPE_BOOL;
    }
    if (source_type == TYPE_BOOL) { return false; }

    let source_float: Bool = source_type == TYPE_FLOAT || source_type == TYPE_FLOAT32;
    if (source_float && is_integer_type(target_type)) { return true; }
    if (!is_integer_type(source_type) || !is_integer_type(target_type)) { return false; }

    let source_bits: Int = get_type_bitwidth(source_type);
    let target_bits: Int = get_type_bitwidth(target_type);
    let source_unsigned: Bool = is_unsigned_integer(source_type);
    let target_unsigned: Bool = is_unsigned_integer(target_type);

    if (source_unsigned == target_unsigned) {
        return source_bits > target_bits;
    }
    if source_unsigned {
        return source_bits >= target_bits;
    }
    return true;
}

func flow_type(ref c: Compiler, node: NodeID) -> Int {
// facts describe reads, the symbol's declared type still owns its storage and drop glue
    if (node == c.flow_skip || !has_node(node)) { return 0; }
    let kind: Int = node_tag(node);
    if (kind != NODE_VAR_ACCESS && kind != NODE_FIELD_ACCESS) { return 0; }
    let path: String = format_ast_path(ref c, node);
    let i: Int = c.flow_types.length();
    while (i > 0) {
        i--;
        if (c.flow_types[i].path == path) { return c.flow_types[i].type; }
    }
    return 0;
}

func get_expr_type(ref c: Compiler, node: NodeID) -> Int {
// each node handler keeps its own temporaries, recursive inference also runs in O0 builds
    if (!has_node(node)) { return 0; }
    let base: Int = node_tag(node);
    let narrowed: Int = flow_type(ref c, node);
    if (narrowed != 0) { return narrowed; }

    if (base == NODE_INT) {
        let n: IntNode = get_int_node(ref c.arena, node);
        let raw_val: String = n.tok.value;
        if (raw_val.ends_with("ULL") || raw_val.ends_with("ull")) { return TYPE_UINT128; }
        if (raw_val.ends_with("LL") || raw_val.ends_with("ll")) { return TYPE_INT128; }
        if (raw_val.ends_with("UL") || raw_val.ends_with("ul")) { return TYPE_UINT64; }
        if (raw_val.ends_with("U") || raw_val.ends_with("u")) { return TYPE_UINT32; }
        if (exceeds_64bit_range(raw_val)) { return TYPE_INT128; }

        let parsed_val: Long = string_to_long(raw_val, n.pos);
        if (raw_val.ends_with("L") || raw_val.ends_with("l")) { return TYPE_LONG; }
        if (parsed_val < -2147483648L || parsed_val > 2147483647L) { return TYPE_LONG; }
        return TYPE_INT;
    }
    if (base == NODE_STRING) { return TYPE_STRING; }
    if (base == NODE_CHAR) { return TYPE_CHAR; }
    if (base == NODE_FLOAT) {
        let fn: FloatNode = get_float_node(ref c.arena, node);
        let val_str: String = fn.tok.value;
        if (val_str.ends_with("f") || val_str.ends_with("F")) { return TYPE_FLOAT32; }
        return TYPE_FLOAT;
    }
    if (base == NODE_BOOL) { return TYPE_BOOL; }
    if (base == NODE_IS || base == NODE_IS_NOT) { return TYPE_BOOL; }
    if (base == NODE_TYPE_LAYOUT) { return TYPE_UINTSIZE; }
    if (base == NODE_GENERIC_TYPE) {
        return expr_type_generic_type(ref c, node);
    }

    if (base == NODE_VAR_ACCESS) {
        return expr_type_var_access(ref c, node);
    }

    if (base == NODE_FIELD_ACCESS) {
        return expr_type_field_access(ref c, node);
    }

    if (base == NODE_INDEX_ACCESS) {
        return expr_type_index_access(ref c, node);
    }

    if (base == NODE_REF) {
        return expr_type_ref(ref c, node);
    }

    if (base == NODE_DEREF) {
        let deref_node: DerefNode = get_deref_node(ref c.arena, node);
        let ptr_type: Int = get_expr_type(ref c, deref_node.node);
        if (is_pointer_type(ref c, ptr_type)) {
            let base_info: Optional(SymbolInfo) = c.ptr_base_map.lookup(ptr_type);
            if ((base_info is !null)) { return base_info.type; }
        }
        return 0;
    }

    if (base == NODE_SLICE_ACCESS) {
        return expr_type_slice_access(ref c, node);
    }

    if (base == NODE_TRY_UNWRAP) {
        return expr_type_try_unwrap(ref c, node);
    }

    if (base == NODE_CALL) {
        return expr_type_call(ref c, node);
    }

    if (base == NODE_VECTOR_LIT) {
        let vec_node: VectorLitNode = get_vector_lit_node(ref c.arena, node);
        if (vec_node.count > 0) {
            let arg: ArgNode = vec_node.elements[0];
            let elem_type: Int = get_expr_type(ref c, arg.val);
            if (elem_type != 0) {
                let v_id: Int = get_vector_type_id(ref c, elem_type);
                return v_id;
            }
        }
        return 0;
    }

    if (base == NODE_MAP_LIT) {
        let s_info: Optional(StructInfo) = c.struct_table.lookup("Dict");
        if (s_info is null) { s_info = c.struct_table.lookup("dict.Dict"); }
        if ((s_info is !null)) { return s_info.type_id; }
        return 0;
    }

    if (base == NODE_BINOP) {
        return expr_type_binop(ref c, node);
    }

    if (base == NODE_POSTFIX) {
        let postfix = get_postfix_node(ref c.arena, node);
        return get_expr_type(ref c, postfix.node);
    }

    if (base == NODE_UNARYOP) {
        let u: UnaryOpNode = get_unary_node(ref c.arena, node);
        let op: Int = u.op_tok.type;
        if (op == WhitelangTokens.TOK_NOT) {
            let operand = get_expr_type(ref c, u.node);
            if (get_repr_type(ref c, operand) == TYPE_BOOL) { return operand; }
            return TYPE_BOOL;
        }

        return get_expr_type(ref c, u.node);
    }

    return 0;
}

func expr_type_generic_type(ref c: Compiler, node: NodeID) -> Int {
    let generic: GenericTypeNode = get_generic_type_node(ref c.arena, node);
    let generic_base: Int = node_tag(generic.base_type);
    if (generic_base == NODE_FIELD_ACCESS) {
        let field: FieldAccessNode = get_field_access_node(ref c.arena, generic.base_type);

        let owner_type: Int = get_expr_type(ref c, field.obj);
        let owner: Optional(StructInfo) = c.struct_id_map.lookup(owner_type);
        if (!(owner is !null) || !owner.is_class) { return TYPE_POISON; }
        let meta_owner: StructInfo = owner;

        let method_template: Optional(GenericTemplate) = c.generic_methods.lookup(meta_owner.name + "_" + field.field_name);
        if (!(method_template is !null)) { return TYPE_POISON; }

        let method_types: Optional(Vector(Struct)) = resolve_generic_method_args(ref c, method_template, generic.type_args, [], generic.pos);
        if (method_types is null) { return TYPE_POISON; }

        let method_info: Optional(FuncInfo) = register_generic_method(ref c, method_template, meta_owner, method_types, generic.pos);
        if (!(method_info is !null)) { return TYPE_POISON; }
        let signature: FuncInfo = method_info;

        let args: Vector(Struct) = [];
        let i: Int = 1;
        while (i < signature.arg_types.length()) {
            args.append(signature.arg_types[i]);
            i++;
        }
        return get_method_type_id(ref c, args, signature.ret_type, signature.variadic_param, callable_arg_names(signature, 1));
    }

    let name: String = generic_symbol_name(ref c, generic.base_type, true);
    let template: Optional(GenericTemplate) = c.generic_funcs.lookup(name);
    if (!(template is !null)) { return TYPE_POISON; }
    let meta_template: GenericTemplate = template;

    let types: Optional(Vector(Struct)) = resolve_generic_args(ref c, meta_template, generic.type_args, [], generic.pos);
    if (types is null) { return TYPE_POISON; }
    let instance: Optional(FuncInfo) = register_generic_func(ref c, meta_template, types, generic.pos);
    if (!(instance is !null)) { return TYPE_POISON; }

    return get_func_type_id(ref c, instance.arg_types, instance.ret_type, instance.variadic_param, callable_arg_names(instance, 0));
}

func expr_type_var_access(ref c: Compiler, node: NodeID) -> Int {
    let v: VarAccessNode = get_var_access_node(ref c.arena, node);
    let info: Optional(SymbolInfo) = find_symbol(ref c, v.name_tok.value);
    if ((info is !null)) { return info.type; }

    let h_curr: Scope = c.hoist_scope;
    while (h_curr.table is !null) {
        let h_info: Optional(SymbolInfo) = scope_lookup(h_curr, v.name_tok.value);
        if ((h_info is !null)) { return h_info.type; }
        if (h_curr.parent < 0 || h_curr.parent >= c.hoist_scope_stack.length()) { break; }
        h_curr = c.hoist_scope_stack[h_curr.parent];
    }

    let f_info: Optional(FuncInfo) = c.func_table.lookup(v.name_tok.value);
    if (!(f_info is !null) && c.current_package_prefix != "") {
        f_info = c.func_table.lookup(c.current_package_prefix + v.name_tok.value);
    }
    if (f_info is null) {
        let mapped = c.current_file_func_aliases.lookup(v.name_tok.value);
        if (mapped is null) { mapped = c.global_func_aliases.lookup(v.name_tok.value); }
        if (mapped is !null) { f_info = c.func_table.lookup(mapped); }
    }
    if ((f_info is !null)) {
        if ((f_info.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
            throw_type_error(v.pos, "Compiler intrinsic '" + f_info.base_name + "' cannot be used as a function value.");
            return TYPE_POISON;
        }
        return get_func_type_id(ref c, f_info.arg_types, f_info.ret_type, f_info.variadic_param, callable_arg_names(f_info, 0));
    }

    return 0;
}

func module_function(ref c: Compiler, field: FieldAccessNode) -> Optional(FuncInfo) {
// module paths share alias resolution with direct calls, local values still shadow them
    let root = field.obj;
    while (node_tag(root) == NODE_FIELD_ACCESS) {
        root = get_field_access_node(ref c.arena, root).obj;
    }
    if (node_tag(root) != NODE_VAR_ACCESS || field.field_name.starts_with("__")) {
        return null;
    }
    let root_name = get_var_access_node(ref c.arena, root).name_tok.value;
    if (find_symbol(ref c, root_name) is !null) {
        return null;
    }

    let parts: Vector(String) = [];
    let current = field.obj;
    while (node_tag(current) == NODE_FIELD_ACCESS) {
        let part = get_field_access_node(ref c.arena, current);
        parts.append(part.field_name);
        current = part.obj;
    }
    let name: String = "";
    let prefix = c.current_file_visible_prefixes.lookup(root_name);
    if (prefix is !null) {
        name = module_member_name(prefix, parts, field.field_name);
    } else {
        let mapped = c.current_file_func_aliases.lookup(module_member_name(root_name + ".", parts, field.field_name));
        if (mapped is !null) { name = mapped; }
    }
    if (name.length() == 0) { return null; }
    let alias = c.global_func_aliases.lookup(name);
    if (alias is !null) { name = alias; }

    return c.func_table.lookup(name);
}

func expr_type_field_access(ref c: Compiler, node: NodeID) -> Int {
    let f: FieldAccessNode = get_field_access_node(ref c.arena, node);
    let function = module_function(ref c, f);
    if (function is !null) {
        if ((function.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
            throw_type_error(f.pos, "Compiler intrinsic '" + function.base_name + "' cannot be used as a function value.");
            return TYPE_POISON;
        }
        return get_func_type_id(ref c, function.arg_types, function.ret_type, function.variadic_param, callable_arg_names(function, 0));
    }
    let obj_type: Int = get_expr_type(ref c, f.obj);
    obj_type = get_repr_type(ref c, obj_type);
    if (is_pointer_type(ref c, obj_type)) {
        let base_info: Optional(SymbolInfo) = c.ptr_base_map.lookup(obj_type);
        if ((base_info is !null)) { obj_type = base_info.type; }
    }
    if (obj_type >= 100) {
        let s_info: Optional(StructInfo) = c.struct_id_map.lookup(obj_type);
        if ((s_info is !null)) {
            let meta_s_info: StructInfo = s_info;
            let field: Optional(FieldInfo) = find_field(meta_s_info, f.field_name);
            if ((field is !null)) { return field.type; }
            if (meta_s_info.is_class) {
                let vtable: Vector(Struct) = meta_s_info.vtable;
                let v_len: Int = vtable.length();
                let m_idx: Int = 0;
                while (m_idx < v_len) {
                    let m_info: FuncInfo = vtable[m_idx];
                    if (m_info.base_name == f.field_name) {
                        let bound_args: Vector(Struct) = [];
                        let a_idx: Int = 1;
                        while (a_idx < m_info.arg_types.length()) {
                            bound_args.append(m_info.arg_types[a_idx]);
                            a_idx += 1;
                        }
                        return get_method_type_id(ref c, bound_args, m_info.ret_type, m_info.variadic_param, callable_arg_names(m_info, 1));
                    }
                    m_idx += 1;
                }
            }
        }
    }

    let obj_base: Int = node_tag(f.obj);
    if (obj_base == NODE_VAR_ACCESS) {
        let v_node: VarAccessNode = get_var_access_node(ref c.arena, f.obj);
        let target_name: String = v_node.name_tok.value;
        if (c.current_package_prefix != "") {
            if ((c.struct_table.lookup(c.current_package_prefix + target_name) is !null)) {
                target_name = c.current_package_prefix + target_name;
            }
        }
        let s_info: Optional(StructInfo) = c.struct_table.lookup(target_name);
        if (s_info is null) {
            let alias = c.current_file_type_aliases.lookup(v_node.name_tok.value);
            if (alias is !null) { s_info = c.struct_table.lookup(alias); }
        }
        if (s_info is null) {
            let alias = c.global_type_aliases.lookup(target_name);
            if (alias is !null) { s_info = c.struct_table.lookup(alias); }
        }
        if ((s_info is !null) && s_info.is_enum) { return s_info.type_id; }
    }
    if (obj_type == 0) {
        let name = generic_symbol_name(ref c, f.obj, false);
        let owner = c.struct_table.lookup(name);
        if (owner is null) {
            let alias = c.global_type_aliases.lookup(name);
            if (alias is !null) { owner = c.struct_table.lookup(alias); }
        }
        if (owner is !null && owner.is_enum) { return owner.type_id; }
    }
    return 0;
}

func expr_type_index_access(ref c: Compiler, node: NodeID) -> Int {
    let idx_node: IndexAccessNode = get_index_access_node(ref c.arena, node);
    let target_type: Int = get_expr_type(ref c, idx_node.target);
    target_type = get_repr_type(ref c, target_type);
    if (is_pointer_type(ref c, target_type) == true) {
        let base_info: Optional(SymbolInfo) = c.ptr_base_map.lookup(target_type);
        if ((base_info is !null)) { return base_info.type; }
    }
    if (target_type >= 100) {
        let v_info: Optional(SymbolInfo) = c.vector_base_map.lookup(target_type);
        if ((v_info is !null)) { return v_info.type; }
        let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(target_type);
        if ((arr_info is !null)) { return arr_info.base_type; }
        let s_info: Optional(StructInfo) = c.struct_id_map.lookup(target_type);
        if ((s_info is !null) && s_info.is_class) {
            let meta_s_info: StructInfo = s_info;
            let method_index: Int = 0;
            while (method_index < meta_s_info.vtable.length()) {
                let method_info: FuncInfo = meta_s_info.vtable[method_index];
                if (method_info.base_name == "get") { return method_info.ret_type; }
                method_index++;
            }
        }
    }
    if (target_type == TYPE_STRING) { return TYPE_BYTE; }
    return 0;
}

func expr_type_ref(ref c: Compiler, node: NodeID) -> Int {
    let ref_node: RefNode = get_ref_node(ref c.arena, node);
    let ref_base: Int = node_tag(ref_node.node);
    if (ref_base == NODE_SLICE_ACCESS) {
        let slice_node: SliceAccessNode = get_slice_access_node(ref c.arena, ref_node.node);
        let target_type: Int = get_expr_type(ref c, slice_node.target);
        if (target_type == TYPE_STRING) { return TYPE_STRING; }

        let elem_type: Int = 0;
        if (target_type >= 100) {
            let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(target_type);
            if ((arr_info is !null)) { elem_type = arr_info.base_type; }
            else {
                let vec_info: Optional(SymbolInfo) = c.vector_base_map.lookup(target_type);
                if ((vec_info is !null)) { elem_type = vec_info.type; }
            }
        }
        if (elem_type != 0) { return get_slice_type_id(ref c, elem_type); }
        return 0;
    }
    let base_type: Int = get_expr_type(ref c, ref_node.node);
    if (base_type != 0) {
        return get_ptr_type_id(ref c, base_type);
    }
    return 0;
}

func expr_type_slice_access(ref c: Compiler, node: NodeID) -> Int {
    let slice_node: SliceAccessNode = get_slice_access_node(ref c.arena, node);
    let target_type: Int = get_expr_type(ref c, slice_node.target);
    target_type = get_repr_type(ref c, target_type);
    if (target_type == TYPE_STRING) { return TYPE_STRING; }

    let elem_type: Int = 0;
    if (target_type >= 100) {
        let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(target_type);
        if ((arr_info is !null)) { elem_type = arr_info.base_type; }
        else {
            let v_info: Optional(SymbolInfo) = c.vector_base_map.lookup(target_type);
            if ((v_info is !null)) { elem_type = v_info.type; }
        }
    }

    if (elem_type != 0) {
        return get_slice_type_id(ref c, elem_type);
    }
    return 0;
}

func expr_type_try_unwrap(ref c: Compiler, node: NodeID) -> Int {
    let t_node: TryUnwrapNode = get_try_unwrap_node(ref c.arena, node);
    let base_type: Int = get_expr_type(ref c, t_node.expr);
    // the entry-slot walk can reach this before a guard resolves the receiver.
    if (base_type == 0 || base_type == TYPE_POISON) { return base_type; }
    if (is_fallible_type(ref c, base_type)) {
        return get_inner_fallible_type(ref c, base_type);
    }
    let expr_base: Int = node_tag(t_node.expr);
    if (expr_base == NODE_CALL) {
        let call: CallNode = get_call_node(ref c.arena, t_node.expr);
        let callee_base: Int = node_tag(call.callee);
        if (callee_base == NODE_VAR_ACCESS) {
            let callee: VarAccessNode = get_var_access_node(ref c.arena, call.callee);
            let target_type: Int = get_cast_target(ref c, callee.name_tok.value);
            if (target_type != 0) {
                throw_invalid_syntax(t_node.pos, "conversion to " + get_type_name(ref c, target_type) + " cannot fail; remove '?'");
                return 0;
            }
        }
    }
    throw_invalid_syntax(t_node.pos, "Cannot use '?' on a non-fallible type.");
    return 0;
}

func expr_type_call(ref c: Compiler, node: NodeID) -> Int {
    let call_node: CallNode = get_call_node(ref c.arena, node);
    let callee_node: NodeID = call_node.callee;
    let callee: Int = node_tag(callee_node);
    if (callee == NODE_GENERIC_TYPE) {
        let generic: GenericTypeNode = get_generic_type_node(ref c.arena, callee_node);
        callee_node = generic.base_type;
        callee = node_tag(callee_node);
    }
    if (callee == NODE_VAR_ACCESS) {
        let name = get_var_access_node(ref c.arena, callee_node).name_tok.value;
        let binding = find_symbol(ref c, name);
        if (binding is !null) {
            let signature = c.func_ret_map.lookup(binding.type);
            if (signature is null) { signature = c.method_ret_map.lookup(binding.type); }
            if (signature is !null) { return signature.type; }
            return 0;
        }
    }

    let generic_type_name: String = generic_symbol_name(ref c, callee_node, false);
    let generic_type_template: Optional(GenericTemplate) = c.generic_structs.lookup(generic_type_name);
    if (generic_type_template is !null && use_generic_constructor(ref c, generic_type_name, generic_type_template, call_node.type_args, call_node.args, c.expected_type)) {
        let types: Optional(Vector(Struct)) = resolve_generic_constructor_args(ref c, generic_type_template, call_node.type_args, call_node.args, c.expected_type, call_node.pos);
        if (types is null) { return TYPE_POISON; }

        let template_base: Int = node_tag(generic_type_template.node);
        if (template_base == NODE_CLASS_DEF) {
            return register_generic_class(ref c, generic_type_template, types, call_node.pos);
        }
        return register_generic_struct(ref c, generic_type_template, types, call_node.pos);
    }

    let generic_name: String = generic_symbol_name(ref c, callee_node, true);
    let generic_template: Optional(GenericTemplate) = c.generic_funcs.lookup(generic_name);
    if ((generic_template is !null)) {
        let types: Optional(Vector(Struct)) = resolve_generic_args(ref c, generic_template, call_node.type_args, call_node.args, call_node.pos);
        if (types is null) { return TYPE_POISON; }

        let instance: Optional(FuncInfo) = register_generic_func(ref c, generic_template, types, call_node.pos);
        if (!(instance is !null)) { return TYPE_POISON; }

        if (call_node.preserve_fallible) { return instance.ret_type; }
        if (is_fallible_type(ref c, instance.ret_type)) {
            return get_inner_fallible_type(ref c, instance.ret_type);
        }

        return instance.ret_type;
    }

    if (callee == NODE_VAR_ACCESS) {
        let v: VarAccessNode = get_var_access_node(ref c.arena, callee_node);
        let callee_name: String = v.name_tok.value;

        let cast_target: Int = get_cast_target(ref c, callee_name);
        if (cast_target != 0) {
            let args: Vector(ArgNode) = call_node.args;
            if (args.length() == 1) {
                let arg: ArgNode = args[0];
                let source_type: Int = get_expr_type(ref c, arg.val);
                let source_info: Optional(StructInfo) = c.struct_id_map.lookup(source_type);
                let conversion: Optional(FuncInfo) = find_class_conversion(source_info, cast_target);
                if ((conversion is !null)) {
                    if (call_node.preserve_fallible) { return conversion.ret_type; }
                    if (is_fallible_type(ref c, conversion.ret_type)) {
                        return get_inner_fallible_type(ref c, conversion.ret_type);
                    }
                    return conversion.ret_type;
                }
                if (call_node.preserve_fallible && needs_explicit_cast(ref c, source_type, cast_target)) {
                    return get_fallible_type_id(ref c, cast_target);
                }
            }
            return cast_target;
        }

        let f_info: Optional(FuncInfo) = c.func_table.lookup(callee_name);
        if (!(f_info is !null) && c.current_package_prefix != "") {
            f_info = c.func_table.lookup(c.current_package_prefix + callee_name);
        }
        if (!(f_info is !null)) {
            let mapped: Optional(String) = c.current_file_func_aliases.lookup(callee_name);
            if (mapped is !null) { f_info = c.func_table.lookup(mapped); }
        }
        if (!(f_info is !null)) {
            let mapped: Optional(String) = c.global_func_aliases.lookup(callee_name);
            if (mapped is !null) { f_info = c.func_table.lookup(mapped); }
        }
        if ((f_info is !null)) { return f_info.ret_type; }

        let s_info: Optional(StructInfo) = c.struct_table.lookup(callee_name);
        if (!(s_info is !null) && c.current_package_prefix != "") {
            s_info = c.struct_table.lookup(c.current_package_prefix + callee_name);
        }
        if (s_info is null && generic_type_name.length() != 0) {
            s_info = c.struct_table.lookup(generic_type_name);
        }
        if (!(s_info is !null)) {
            let alias_info: Optional(NamedTypeInfo) = find_named_decl(ref c, callee_name);
            if ((alias_info is !null) && alias_info.is_alias) {
                s_info = c.struct_id_map.lookup(resolve_named_type(ref c, alias_info));
            }
        }
        if ((s_info is !null)) { return s_info.type_id; }

        let var_info: Optional(SymbolInfo) = find_symbol(ref c, callee_name);
        if ((var_info is !null)) {
            let p_type: Int = var_info.type;
            let f_ret_info: Optional(SymbolInfo) = c.func_ret_map.lookup(p_type);
            if ((f_ret_info is !null)) { return f_ret_info.type; }
            let m_ret_info: Optional(SymbolInfo) = c.method_ret_map.lookup(p_type);
            if ((m_ret_info is !null)) { return m_ret_info.type; }
        }
    }
    else if (callee == NODE_FIELD_ACCESS) {
        let f: FieldAccessNode = get_field_access_node(ref c.arena, callee_node);
        let obj_type: Int = get_expr_type(ref c, f.obj);
        if (obj_type == 0) {
            let path_parts: Vector(String) = [];
            let curr_obj: NodeID = f.obj;
            let curr_base: Int = node_tag(curr_obj);
            while (curr_base == NODE_FIELD_ACCESS) {
                let inner_f: FieldAccessNode = get_field_access_node(ref c.arena, curr_obj);
                path_parts.append(inner_f.field_name);
                curr_obj = inner_f.obj;
                curr_base = node_tag(curr_obj);
            }
            if (curr_base == NODE_VAR_ACCESS) {
                let inner_v: VarAccessNode = get_var_access_node(ref c.arena, curr_obj);
                let root_name: String = inner_v.name_tok.value;
                if (!(find_symbol(ref c, root_name) is !null)) {
                    let full_name: String = "";
                    let module_prefix: Optional(String) = c.current_file_visible_prefixes.lookup(root_name);
                    if (module_prefix is !null) {
                        full_name = module_member_name(module_prefix, path_parts, f.field_name);
                    } else {
                        let source_name: String = module_member_name(root_name + ".", path_parts, f.field_name);
                        let mapped_func: Optional(String) = c.current_file_func_aliases.lookup(source_name);
                        if (mapped_func is !null) { full_name = mapped_func; }
                    }
                    let g_alias_f: Optional(String) = c.global_func_aliases.lookup(full_name);
                    if (g_alias_f is !null) { full_name = g_alias_f; }

                    let f_info: Optional(FuncInfo) = c.func_table.lookup(full_name);
                    if ((f_info is !null)) { return f_info.ret_type; }
                    let constructor: Optional(StructInfo) = c.struct_table.lookup(generic_type_name);
                    if (constructor is null) {
                        let alias = c.global_type_aliases.lookup(generic_type_name);
                        if (alias is !null) { constructor = c.struct_table.lookup(alias); }
                    }
                    if (constructor is !null) { return constructor.type_id; }
                }
            }
        }

        if (is_pointer_type(ref c, obj_type)) {
            let base_info: Optional(SymbolInfo) = c.ptr_base_map.lookup(obj_type);
            if ((base_info is !null)) { obj_type = base_info.type; }
        }

        if (obj_type == TYPE_STRING) {
            if (f.field_name == "length") { return TYPE_INT; }
            let str_link: Optional(String) = c.compiler_link.lookup("string_" + f.field_name);
            if (str_link is !null) {
                let f_info: Optional(FuncInfo) = c.func_table.lookup(str_link);
                if ((f_info is !null)) { return f_info.ret_type; }
            }
        }

        // intrinsic names belong to container receivers, classes may use the same names
        if (obj_type >= 100) {
            let vector = c.vector_base_map.lookup(obj_type);
            if (vector is !null) {
                if (f.field_name == "length") { return TYPE_INT; }
                if (f.field_name == "append") { return TYPE_VOID; }
                if (f.field_name == "drop") { return vector.type; }
            }
            if (f.field_name == "length" && c.array_info_map.contains_key(obj_type)) {
                return TYPE_INT;
            }
        }

        if (obj_type >= 100) {
            let s_info: Optional(StructInfo) = c.struct_id_map.lookup(obj_type);
            if ((s_info is !null) && s_info.is_class) {
                let meta_s_info: StructInfo = s_info;
                let method_template: Optional(GenericTemplate) = c.generic_methods.lookup(meta_s_info.name + "_" + f.field_name);
                if ((method_template is !null)) {
                    let types: Optional(Vector(Struct)) = resolve_generic_method_args(ref c, method_template, call_node.type_args, call_node.args, call_node.pos);
                    if (types is null) { return TYPE_POISON; }
                    let instance: Optional(FuncInfo) = register_generic_method(ref c, method_template, meta_s_info, types, call_node.pos);
                    if (!(instance is !null)) { return TYPE_POISON; }
                    let meta_instance: FuncInfo = instance;
                    if (!call_node.preserve_fallible && is_fallible_type(ref c, meta_instance.ret_type)) {
                        return get_inner_fallible_type(ref c, meta_instance.ret_type);
                    }
                    return meta_instance.ret_type;
                }
                let vtable: Vector(Struct) = meta_s_info.vtable;
                let v_len: Int = vtable.length();
                let m_idx: Int = 0;
                while (m_idx < v_len) {
                    let m_info: FuncInfo = vtable[m_idx];
                    if (m_info.base_name == f.field_name) { return m_info.ret_type; }
                    m_idx += 1;
                }
            } else if ((s_info is !null) && s_info.is_interface) {
                let protocol: StructInfo = s_info;
                let vtable: Vector(Struct) = protocol.vtable;
                let v_len: Int = vtable.length();
                let m_idx: Int = 0;
                while (m_idx < v_len) {
                    let m_node: MethodDefNode = vtable[m_idx];
                    if (m_node.name_tok.value == f.field_name) {
                        return interface_method_type(ref c, protocol, m_node.return_type);
                    }
                    m_idx += 1;
                }
            }
        }
    }
    let ptr_type: Int = get_expr_type(ref c, callee_node);
    if (ptr_type != 0) {
        let f_ret_info: Optional(SymbolInfo) = c.func_ret_map.lookup(ptr_type);
        if ((f_ret_info is !null)) { return f_ret_info.type; }
        let m_ret_info: Optional(SymbolInfo) = c.method_ret_map.lookup(ptr_type);
        if ((m_ret_info is !null)) { return m_ret_info.type; }
    }

    return 0;
}

func expr_type_binop(ref c: Compiler, node: NodeID) -> Int {
    let b: BinOpNode = get_binop_node(ref c.arena, node);
    let op: Int = b.op_tok.type;

    if (op == WhitelangTokens.TOK_EE || op == WhitelangTokens.TOK_NE || op == WhitelangTokens.TOK_LT ||
        op == WhitelangTokens.TOK_GT || op == WhitelangTokens.TOK_LTE || op == WhitelangTokens.TOK_GTE ||
        op == WhitelangTokens.TOK_IS) {
        return TYPE_BOOL;
    }

    let left_ty: Int = get_expr_type(ref c, b.left);
    let right_ty: Int = get_expr_type(ref c, b.right);

    if (op == WhitelangTokens.TOK_AND || op == WhitelangTokens.TOK_OR) {
        if (get_repr_type(ref c, left_ty) == TYPE_BOOL) { return left_ty; }
        return TYPE_BOOL;
    }

    if (left_ty == TYPE_STRING || right_ty == TYPE_STRING) { return TYPE_STRING; }
    if (left_ty == TYPE_CHAR && right_ty == TYPE_CHAR && op == WhitelangTokens.TOK_PLUS) { return TYPE_STRING; }

    if (left_ty == TYPE_FLOAT || right_ty == TYPE_FLOAT) { return TYPE_FLOAT; }
    if (left_ty == TYPE_FLOAT32 || right_ty == TYPE_FLOAT32) { return TYPE_FLOAT32; }
    if (is_integer_type(left_ty) && is_integer_type(right_ty)) {
        let left_bits: Int = get_type_bitwidth(left_ty);
        let right_bits: Int = get_type_bitwidth(right_ty);
        if (right_bits > left_bits) { return right_ty; }
        if (left_bits > right_bits) { return left_ty; }
        if (is_unsigned_integer(right_ty)) { return right_ty; }
    }

    return left_ty;
}


func get_type_bitwidth(t: Int) -> Int {
    if (t == TYPE_BOOL) { return 1; }
    if (t == TYPE_BYTE || t == TYPE_INT8) { return 8; }
    if (t == TYPE_INT16 || t == TYPE_UINT16) { return 16; }
    if (t == TYPE_INT || t == TYPE_UINT32 || t == TYPE_CHAR || t == TYPE_FLOAT32) { return 32; }
    if (t == TYPE_INTSIZE || t == TYPE_UINTSIZE) {
        return get_target_pointer_bits();
    }
    if (t == TYPE_LONG || t == TYPE_UINT64 || t == TYPE_FLOAT) { return 64; }
    if (t == TYPE_INT128 || t == TYPE_UINT128) { return 128; }
    return get_target_pointer_bits(); // fallback for pointer-backed values
}

func get_type_size_bytes(ref c: Compiler, type_id: Int) -> Int {
// return the in-memory size used by contiguous containers
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, type_id);
    if ((named is !null)) {
        return get_type_size_bytes(ref c, named.underlying_type);
    }
    let union: Bool = is_union_type(ref c, type_id);
    if (union) {
        return get_union_layout(ref c, type_id).size;
    }
    // String's member table is a frontend placeholder, storage is still a pointer.
    if (type_id == TYPE_STRING || type_id == TYPE_NULL || type_id == TYPE_ANYPTR || type_id == TYPE_NULLPTR) {
        return get_pointer_size_bytes();
    }
    if (type_id == TYPE_BOOL || type_id == TYPE_BYTE || type_id == TYPE_INT8) { return 1; }
    if (type_id == TYPE_INT16 || type_id == TYPE_UINT16) { return 2; }
    if (type_id == TYPE_INT || type_id == TYPE_UINT32 || type_id == TYPE_CHAR || type_id == TYPE_FLOAT32 || type_id == TYPE_GENERIC_ENUM) { return 4; }
    if (type_id == TYPE_INT128 || type_id == TYPE_UINT128) { return 16; }
    if (type_id == TYPE_INTSIZE || type_id == TYPE_UINTSIZE) {
        return get_pointer_size_bytes();
    }
    if (type_id == TYPE_LONG || type_id == TYPE_UINT64 || type_id == TYPE_FLOAT) { return 8; }
    if (type_id == TYPE_ANY_ERROR) {
        return any_error_size();
    }

    let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
    if ((arr_info is !null)) {
        if (arr_info.size < 0) {
            return get_pointer_size_bytes();
        }
        return arr_info.size * get_type_size_bytes(ref c, arr_info.base_type);
    }

    let struct_info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if ((struct_info is !null) && struct_info.is_interface) {
        return get_pointer_size_bytes() * 2;
    }
    if ((struct_info is !null)) {
        let meta_struct_info: StructInfo = struct_info;
        if (meta_struct_info.is_class) {
            return get_pointer_size_bytes();
        }
        let offset: Int = 0;
        let layout_align: Int = 1;
        let i: Int = 0;
        while (i < meta_struct_info.fields.length()) {
            let field: FieldInfo = meta_struct_info.fields[i];
            let field_align: Int = get_type_align_bytes(ref c, field.type);

            offset = align_to(offset, field_align);
            offset += get_type_size_bytes(ref c, field.type);

            if (field_align > layout_align) { layout_align = field_align; }
            i += 1;
        }
        let size: Int = align_to(offset, layout_align);
        if (size == 0) { return 1; }

        return size;
    }

    let fallible_info: Optional(SymbolInfo) = c.fallible_base_map.lookup(type_id);
    if ((fallible_info is !null)) {
        let error_align: Int = any_error_align();
        let offset: Int = align_to(1, error_align) + any_error_size();
        let layout_align: Int = error_align;
        if (fallible_info.type != TYPE_VOID) {
            let value_align: Int = get_type_align_bytes(ref c, fallible_info.type);
            offset = align_to(offset, value_align);
            offset += get_type_size_bytes(ref c, fallible_info.type);
            if (value_align > layout_align) { layout_align = value_align; }
        }
        return align_to(offset, layout_align);
    }

    return get_pointer_size_bytes();
}

func value_layout_contains(ref c: Compiler, type_id: Int, target: Int, seen: Vector(Int)) -> Bool {
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, type_id);
    if ((named is !null)) {
        return value_layout_contains(ref c, named.underlying_type, target, seen);
    }

    if (type_id == target) { return true; }

    let found_union: Optional(UnionInfo) = get_union_type(ref c, type_id);
    if (found_union is !null) {
        let union: UnionInfo = found_union;
        let i: Int = 0;
        while (i < union.members.length()) {
            if (value_layout_contains(ref c, union.members[i], target, seen)) { return true; }
            i++;
        }
        return false;
    }

    let array_info: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
    if ((array_info is !null)) {
        if (array_info.size < 0) { return false; }
        return value_layout_contains(ref c, array_info.base_type, target, seen);
    }

    let info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if (!(info is !null) || info.is_class || info.is_interface || info.is_enum) { return false; }
    let meta_info: StructInfo = info;

    let i: Int = 0;
    while (i < seen.length()) {
        if (seen[i] == type_id) { return false; }
        i += 1;
    }
    seen.append(type_id);

    i = 0;
    while (i < meta_info.fields.length()) {
        let field: FieldInfo = meta_info.fields[i];
        if (value_layout_contains(ref c, field.type, target, seen)) { return true; }

        i += 1;
    }
    return false;
}

func get_type_align_bytes(ref c: Compiler, type_id: Int) -> Int {
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, type_id);
    if ((named is !null)) {
        return get_type_align_bytes(ref c, named.underlying_type);
    }
    let union: Bool = is_union_type(ref c, type_id);
    if (union) {
        return get_union_layout(ref c, type_id).alignment;
    }
    if (type_id == TYPE_STRING || type_id == TYPE_NULL || type_id == TYPE_ANYPTR || type_id == TYPE_NULLPTR) {
        return get_pointer_size_bytes();
    }
    if (type_id == TYPE_BOOL || type_id == TYPE_BYTE || type_id == TYPE_INT8) { return 1; }
    if (type_id == TYPE_INT16 || type_id == TYPE_UINT16) { return 2; }
    if (type_id == TYPE_INT || type_id == TYPE_UINT32 || type_id == TYPE_CHAR || type_id == TYPE_FLOAT32 || type_id == TYPE_GENERIC_ENUM) { return 4; }
    if (type_id == TYPE_INT128 || type_id == TYPE_UINT128) { return target_i128_align(); }
    if (type_id == TYPE_INTSIZE || type_id == TYPE_UINTSIZE) {
        return get_pointer_size_bytes();
    }
    if (type_id == TYPE_LONG || type_id == TYPE_UINT64 || type_id == TYPE_FLOAT || type_id == TYPE_ANY_ERROR) { return target_i64_align(); }

    let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
    if ((arr_info is !null)) {
        if (arr_info.size < 0) {
            return get_pointer_size_bytes();
        }
        return get_type_align_bytes(ref c, arr_info.base_type);
    }

    let struct_info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if ((struct_info is !null)) {
        let meta_struct_info: StructInfo = struct_info;
        if (meta_struct_info.is_class || meta_struct_info.is_interface) {
            return get_pointer_size_bytes();
        }

        let result: Int = 1;
        let i: Int = 0;
        while (i < meta_struct_info.fields.length()) {
            let field: FieldInfo = meta_struct_info.fields[i];
            let field_align: Int = get_type_align_bytes(ref c, field.type);
            if (field_align > result) { result = field_align; }

            i += 1;
        }
        return result;
    }

    let fallible_info: Optional(SymbolInfo) = c.fallible_base_map.lookup(type_id);
    if ((fallible_info is !null)) {
        let result: Int = any_error_align();
        if (fallible_info.type != TYPE_VOID) {
            let value_align: Int = get_type_align_bytes(ref c, fallible_info.type);
            if (value_align > result) { result = value_align; }
        }
        return result;
    }
    return get_pointer_size_bytes();
}

func get_signed_min_literal(type_id: Int) -> String {
    if (type_id == TYPE_INT8) {
        return "-128";
    }
    if (type_id == TYPE_INT16) {
        return "-32768";
    }
    if (type_id == TYPE_INT) {
        return "-2147483648";
    }
    if (type_id == TYPE_INTSIZE && get_target_pointer_bits() == 32) {
        return "-2147483648";
    }
    if (type_id == TYPE_LONG || type_id == TYPE_INTSIZE) {
        return "-9223372036854775808";
    }
    if (type_id == TYPE_INT128) {
        return "-170141183460469231731687303715884105728";
    }
    return "";
}

func generic_instance_name(template_name: String, types: Vector(Struct), ref c: Compiler) -> String {
    let name: String = template_name;
    let i: Int = 0;
    while (i < types.length()) {
        let item: TypeListNode = types[i];
        name += "$" + mangle_type(ref c, item.type);
        i += 1;
    }
    return name;
}

func generic_type_name(template_name: String, types: Vector(Struct), ref c: Compiler) -> String {
    let name: String = template_name + "(";
    let i: Int = 0;
    while (i < types.length()) {
        let item: TypeListNode = types[i];
        if (i > 0) { name += ", "; }
        name += get_type_name(ref c, item.type);
        i += 1;
    }
    return name + ")";
}

func generic_llvm_name(prefix: String, type_id: Int) -> String {
    return prefix + type_id;
}

func generic_bindings(params: Vector(GenericParamNode), types: Vector(Struct)) -> Dict(String, SymbolInfo) {
    let bindings: Dict(String, SymbolInfo) = Dict();
    let i: Int = 0;
    while (i < params.length() && i < types.length()) {
        let param: GenericParamNode = params[i];
        let value: TypeListNode = types[i];
        bindings.put(param.name_tok.value, SymbolInfo(reg="", type=value.type, origin_type=value.type, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
        i += 1;
    }
    return bindings;
}

func extend_generic_bindings(found: Optional(Dict(String, SymbolInfo)), params: Vector(GenericParamNode), types: Vector(Struct)) -> Dict(String, SymbolInfo) {
    let bindings: Dict(String, SymbolInfo) = Dict();
    let i: Int = 0;
    if (found is !null) {
        let base: Dict(String, SymbolInfo) = found;
        while (i < base.capacity) {
            if (base.hashes[i] >= 2) {
                bindings.put(base.keys[i], base.values[i]);
            }
            i++;
        }
    }

    i = 0;
    while (i < params.length() && i < types.length()) {
        let param: GenericParamNode = params[i];
        let value: TypeListNode = types[i];
        bindings.put(param.name_tok.value, SymbolInfo(reg="", type=value.type, origin_type=value.type, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
        i++;
    }
    return bindings;
}

func capture_type_context(ref c: Compiler) -> GenericTemplate {
// defaults keep the declaring module's names when construction happens in another file
    return GenericTemplate(
        name=c.current_package_prefix,
        node=NO_NODE,
        type_params=[],
        prefix=c.current_package_prefix,
        dir=c.current_dir,
        visible=c.current_file_visible_prefixes,
        namespaces=c.current_file_namespaces,
        types=c.current_file_type_aliases,
        funcs=c.current_file_func_aliases,
        globals=c.current_file_global_aliases
    );
}

func use_generic_context(ref c: Compiler, template: GenericTemplate, bindings: Dict(String, SymbolInfo)) -> GenericTemplate {
    let previous = capture_type_context(ref c);
    c.current_package_prefix = template.prefix;
    c.current_dir = template.dir;
    c.current_file_visible_prefixes = template.visible;
    c.current_file_namespaces = template.namespaces;
    c.current_file_type_aliases = template.types;
    c.current_file_func_aliases = template.funcs;
    c.current_file_global_aliases = template.globals;
    c.generic_bindings = bindings;
    return previous;
}

func restore_generic_context(ref c: Compiler, previous: GenericTemplate, bindings: Dict(String, SymbolInfo)) -> Void {
    c.current_package_prefix = previous.prefix;
    c.current_dir = previous.dir;
    c.current_file_visible_prefixes = previous.visible;
    c.current_file_namespaces = previous.namespaces;
    c.current_file_type_aliases = previous.types;
    c.current_file_func_aliases = previous.funcs;
    c.current_file_global_aliases = previous.globals;
    c.generic_bindings = bindings;
}

func generic_symbol_name(ref c: Compiler, node: NodeID, is_function: Bool) -> String {
    if (!has_node(node)) {
        return "";
    }

    let base: Int = node_tag(node);
    if (base == NODE_VAR_ACCESS) {
        let named: VarAccessNode = get_var_access_node(ref c.arena, node);
        let name: String = named.name_tok.value;
        let alias: Optional(String) = null;
        if is_function {
            alias = c.current_file_func_aliases.lookup(name);
        } else {
            alias = c.current_file_type_aliases.lookup(name);
        }

        if (alias is !null &&
            ((is_function && (c.generic_funcs.lookup(alias) is !null)) ||
             (!is_function && (c.generic_structs.lookup(alias) is !null)))) {
            return alias;
        }
        if (c.current_package_prefix != "") {
            let local: String = c.current_package_prefix + name;
            if ((is_function && (c.generic_funcs.lookup(local) is !null)) ||
                (!is_function && (c.generic_structs.lookup(local) is !null))) {
                return local;
            }
        }

        if (alias is !null) { return alias; }

        return name;
    }

    if (base == NODE_FIELD_ACCESS) {
        let field: FieldAccessNode = get_field_access_node(ref c.arena, node);
        let path_parts: Vector(String) = [];
        let current: NodeID = field.obj;
        let current_base: Int = node_tag(current);
        while (current_base == NODE_FIELD_ACCESS) {
            let inner: FieldAccessNode = get_field_access_node(ref c.arena, current);
            path_parts.append(inner.field_name);
            current = inner.obj;
            current_base = node_tag(current);
        }

        if (current_base != NODE_VAR_ACCESS) {
            return "";
        }

        let root: VarAccessNode = get_var_access_node(ref c.arena, current);
        let prefix: Optional(String) = c.current_file_visible_prefixes.lookup(root.name_tok.value);
        if (prefix is !null) {
            return module_member_name(prefix, path_parts, field.field_name);
        }

        let source: String = module_member_name(root.name_tok.value + ".", path_parts, field.field_name);
        let alias: Optional(String) = null;
        if is_function {
            alias = c.current_file_func_aliases.lookup(source);
        } else {
            alias = c.current_file_type_aliases.lookup(source);
        }

        if (alias is !null) { return alias; }
    }
    return "";
}

func register_generic_struct(ref c: Compiler, template: GenericTemplate, types: Vector(Struct), pos: Position) -> Int {
    let key: String = generic_instance_name(template.name, types, ref c);
    let cached: Optional(SymbolInfo) = c.generic_instances.lookup(key);
    if ((cached is !null)) { return cached.type; }

    if (c.generic_depth >= 64) {
        throw_type_error(pos, "Generic instantiation depth exceeds 64.");
        return TYPE_POISON;
    }
    if (c.generic_instance_count >= 4096) {
        throw_type_error(pos, "Generic instantiation limit exceeded.");
        return TYPE_POISON;
    }

    c.generic_instance_count += 1;

    let node: StructDefNode = get_struct_def_node(ref c.arena, template.node);
    let bindings: Dict(String, SymbolInfo) = generic_bindings(template.type_params, types);
    if (!check_generic_constraints(ref c, template, bindings, types, pos)) { return TYPE_POISON; }
    let previous_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
    let previous: GenericTemplate = use_generic_context(ref c, template, bindings);
    c.generic_depth += 1;

    let new_id: Int = c.type_counter;
    c.type_counter += 1;
    let llvm_name: String = "%struct.__generic." + new_id;
    let info: StructInfo = StructInfo(
        name=key,
        type_id=new_id,
        fields=[],
        llvm_name=llvm_name,
        init_body=node.body,
        is_class=false,
        vtable_name="",
        parent_id=0,
        vtable=[],
        ann_flags=0,
        compiler_link_name="",
        is_enum=false,
        is_error=false,
        is_interface=false,
        interfaces=[],
        layout_ready=false
    );
    c.generic_instances.put(key, SymbolInfo(reg="", type=new_id, origin_type=new_id, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    c.generic_type_names.put("" + new_id, StringConstant(id=0, value=generic_type_name(template.name, types, ref c)));
    c.generic_instance_bindings.put("" + new_id, bindings);
    c.generic_instance_templates.put("" + new_id, template);
    c.struct_table.put(key, info);
    c.struct_id_map.put(new_id, info);
    c.type_revision++;
    c.type_drop_list.append(TypeListNode(type=new_id, pass_mode=0));

    let body: String = "";
    let fields: Vector(Struct) = [];
    let i: Int = 0;
    while (i < node.fields.length()) {
        let field: ParamNode = node.fields[i];
        let field_type: Int = resolve_type(ref c, field.type_tok);
        if (value_layout_contains(ref c, field_type, new_id, [])) {
            throw_type_error(field.pos, "Struct '" + generic_type_name(template.name, types, ref c) + "' contains itself by value through field '" + field.name_tok.value + "'. Use a pointer for recursive storage.");
            c.generic_depth -= 1;
            restore_generic_context(ref c, previous, previous_bindings);
            return TYPE_POISON;
        }
        let field_llvm: String = get_llvm_type_str(ref c, field_type);
        if (i > 0) { body += ", "; }
        body += field_llvm;
        fields.append(FieldInfo(name=field.name_tok.value, type=field_type, llvm_type=field_llvm, offset=i, is_const=false, default_val=field.default_val));
        i += 1;
    }
    info.fields = fields;
    c.struct_contexts.put(new_id, template);
    store_struct(ref c, info);
    if (fields.length() == 0) { body = "i8"; }

    c.generic_type_defs += llvm_name + " = type { " + body + " }\n\n";

    c.generic_depth -= 1;
    restore_generic_context(ref c, previous, previous_bindings);
    return new_id;
}

func append_type_once(list: Vector(Struct), type_id: Int) -> Void {
    let i: Int = 0;
    while (i < list.length()) {
        let item: TypeListNode = list[i];
        if (item.type == type_id) { return; }
        i += 1;
    }
    list.append(TypeListNode(type=type_id, pass_mode=0));
}

func register_generic_interface(ref c: Compiler, template: GenericTemplate, types: Vector(Struct), pos: Position) -> Int {
    let key: String = generic_instance_name(template.name, types, ref c);
    let cached: Optional(SymbolInfo) = c.generic_instances.lookup(key);
    if ((cached is !null)) {
        if (cached.type == TYPE_POISON) {
            throw_type_error(pos, "Generic interface inheritance cycle involving '" + generic_type_name(template.name, types, ref c) + "'.");
        }
        return cached.type;
    }

    if (c.generic_depth >= 64) {
        throw_type_error(pos, "Generic instantiation depth exceeds 64.");
        return TYPE_POISON;
    }
    if (c.generic_instance_count >= 4096) {
        throw_type_error(pos, "Generic instantiation limit exceeded.");
        return TYPE_POISON;
    }
    c.generic_instance_count++;

    let node: InterfaceDefNode = get_interface_def_node(ref c.arena, template.node);
    let bindings: Dict(String, SymbolInfo) = generic_bindings(template.type_params, types);
    c.generic_instances.put(key, SymbolInfo(reg="", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    c.generic_depth++;
    if (!check_generic_constraints(ref c, template, bindings, types, pos)) {
        c.generic_instances.remove(key);
        c.generic_depth--;
        return TYPE_POISON;
    }

    let previous_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
    let previous: GenericTemplate = use_generic_context(ref c, template, bindings);
    let new_id: Int = c.type_counter;
    c.type_counter++;

    let method_names: Dict(String, StringConstant) = Dict();
    let i: Int = 0;
    while (i < node.methods.length()) {
        let method_node: MethodDefNode = get_method_def_node(ref c.arena, node.methods[i]);
        if (method_node.type_params.length() > 0) {
            throw_type_error(method_node.pos, "Interface methods cannot declare type parameters.");
            c.generic_instances.remove(key);
            restore_generic_context(ref c, previous, previous_bindings);
            c.generic_depth--;
            return TYPE_POISON;
        }
        if (method_names.contains_key(method_node.name_tok.value)) {
            throw_name_error(method_node.pos, "Method '" + method_node.name_tok.value + "' is already declared in interface '" + key + "'.");
            c.generic_instances.remove(key);
            restore_generic_context(ref c, previous, previous_bindings);
            c.generic_depth--;
            return TYPE_POISON;
        }
        method_names.put(method_node.name_tok.value, StringConstant(id=0, value=method_node.name_tok.value));
        i++;
    }

    let interfaces: Vector(Struct) = [];
    let methods: Vector(Struct) = [];
    i = 0;
    while (i < node.interfaces.length()) {
        let parent_id: Int = resolve_type(ref c, node.interfaces[i]);
        if (parent_id == TYPE_POISON) {
            if (GLOBAL_ERROR_COUNT == 0) {
                throw_type_error(pos, "Generic interface inheritance cycle involving '" + generic_type_name(template.name, types, ref c) + "'.");
            }
            c.generic_instances.remove(key);
            restore_generic_context(ref c, previous, previous_bindings);
            c.generic_depth--;
            return TYPE_POISON;
        }

        let parent: Optional(StructInfo) = c.struct_id_map.lookup(parent_id);
        if (!(parent is !null) || !parent.is_interface) {
            throw_type_error(pos, "Generic interface '" + key + "' can only inherit from another interface.");
            c.generic_instances.remove(key);
            restore_generic_context(ref c, previous, previous_bindings);
            c.generic_depth--;
            return TYPE_POISON;
        }
        let meta_parent: StructInfo = parent;

        let inherited_index: Int = 0;
        while (inherited_index < meta_parent.interfaces.length()) {
            let inherited_type: TypeListNode = meta_parent.interfaces[inherited_index];
            append_type_once(interfaces, inherited_type.type);
            inherited_index += 1;
        }
        append_type_once(interfaces, parent_id);

        let method_index: Int = 0;
        while (method_index < meta_parent.vtable.length()) {
            let inherited_method: MethodDefNode = meta_parent.vtable[method_index];
            if (method_names.contains_key(inherited_method.name_tok.value)) {
                let repeated: Bool = false;
                let existing_index: Int = 0;
                while (existing_index < methods.length()) {
                    let existing: MethodDefNode = methods[existing_index];
                    if (existing.name_tok.value == inherited_method.name_tok.value &&
                        existing.pos.fn == inherited_method.pos.fn &&
                        existing.pos.ln == inherited_method.pos.ln &&
                        existing.pos.col == inherited_method.pos.col) {
                        repeated = true;
                        break;
                    }
                    existing_index++;
                }
                if (!repeated) {
                    throw_name_error(inherited_method.pos, "Method '" + inherited_method.name_tok.value + "' is inherited more than once by interface '" + key + "'.");
                    c.generic_instances.remove(key);
                    restore_generic_context(ref c, previous, previous_bindings);
                    c.generic_depth--;
                    return TYPE_POISON;
                }
                method_index++;
                continue;
            }
            method_names.put(inherited_method.name_tok.value, StringConstant(id=0, value=inherited_method.name_tok.value));
            methods.append(inherited_method);
            method_index++;
        }
        i++;
    }

    i = 0;
    while (i < node.methods.length()) {
        methods.append(get_method_def_node(ref c.arena, node.methods[i]));
        i += 1;
    }

    let info: StructInfo = StructInfo(
        name=key,
        type_id=new_id,
        fields=[],
        llvm_name="{ i8*, i8* }",
        init_body=template.node,
        is_class=false,
        vtable_name="",
        parent_id=0,
        vtable=methods,
        ann_flags=0,
        compiler_link_name="",
        is_enum=false,
        is_error=false,
        is_interface=true,
        interfaces=interfaces,
        layout_ready=true
    );
    c.generic_instances.put(key, SymbolInfo(reg="", type=new_id, origin_type=new_id, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    c.generic_type_names.put("" + new_id, StringConstant(id=0, value=generic_type_name(template.name, types, ref c)));
    c.generic_instance_bindings.put("" + new_id, bindings);
    c.generic_instance_templates.put("" + new_id, template);
    c.struct_table.put(key, info);
    c.struct_id_map.put(new_id, info);
    c.type_revision++;
    c.type_drop_list.append(TypeListNode(type=new_id, pass_mode=0));
    restore_generic_context(ref c, previous, previous_bindings);
    c.generic_depth--;
    return new_id;
}

func type_node_contains_self(arena: AstArena, node: NodeID) -> Bool {
    if (!has_node(node)) { return false; }

    let base: Int = node_tag(node);
    if (base == NODE_VAR_ACCESS) {
        let named: VarAccessNode = get_var_access_node(ref arena, node);
        return named.name_tok.value == "Self";
    }

    if (base == NODE_UNION_TYPE) {
        let union: UnionTypeNode = get_union_type_node(ref arena, node);
        let i: Int = 0;
        while (i < union.members.length()) {
            if (type_node_contains_self(arena, union.members[i])) { return true; }
            i++;
        }
        return false;
    }

    if (base == NODE_GENERIC_TYPE) {
        let generic: GenericTypeNode = get_generic_type_node(ref arena, node);
        if (type_node_contains_self(arena, generic.base_type)) { return true; }
        let i: Int = 0;
        while (i < generic.type_args.length()) {
            if (type_node_contains_self(arena, generic.type_args[i])) { return true; }
            i += 1;
        }
        return false;
    }

    if (base == NODE_PTR_TYPE) {
        let pointer: PointerTypeNode = get_pointer_type_node(ref arena, node);
        return type_node_contains_self(arena, pointer.base_type);
    }

    if (base == NODE_ARRAY_TYPE) {
        let array: ArrayTypeNode = get_array_type_node(ref arena, node);
        return type_node_contains_self(arena, array.base_type);
    }

    if (base == NODE_VECTOR_TYPE) {
        let vector: VectorTypeNode = get_vector_type_node(ref arena, node);
        return type_node_contains_self(arena, vector.element_type);
    }

    if (base == NODE_SLICE_TYPE) {
        let slice: SliceTypeNode = get_slice_type_node(ref arena, node);
        return type_node_contains_self(arena, slice.element_type);
    }

    if (base == NODE_FALLIBLE_TYPE) {
        let fallible: FallibleTypeNode = get_fallible_type_node(ref arena, node);
        return type_node_contains_self(arena, fallible.base_type);
    }

    if (base == NODE_FUNCTION_TYPE) {
        let function_type: FunctionTypeNode = get_function_type_node(ref arena, node);
        if (type_node_contains_self(arena, function_type.return_type)) { return true; }

        let i: Int = 0;
        while (i < function_type.arg_types.length()) {
            if (type_node_contains_self(arena, function_type.arg_types[i])) { return true; }
            i += 1;
        }
        return false;
    }

    if (base == NODE_METHOD_TYPE) {
        let method_type: MethodTypeNode = get_method_type_node(ref arena, node);
        if (type_node_contains_self(arena, method_type.return_type)) { return true; }

        let i: Int = 0;
        while (i < method_type.arg_types.length()) {
            if (type_node_contains_self(arena, method_type.arg_types[i])) { return true; }
            i += 1;
        }
        return false;
    }
    return false;
}

func interface_uses_self(ref c: Compiler, info: StructInfo) -> Bool {
    let i: Int = 0;
    while (has_struct(info) && i < info.vtable.length()) {
        let method_node: MethodDefNode = info.vtable[i];
        if (type_node_contains_self(c.arena, method_node.return_type)) { return true; }

        let param_index: Int = 0;
        while (param_index < method_node.params.length()) {
            let param: ParamNode = method_node.params[param_index];
            if (type_node_contains_self(c.arena, param.type_tok)) { return true; }
            param_index += 1;
        }
        i += 1;
    }
    return false;
}

func interface_type_bindings(ref c: Compiler, info: StructInfo, self_type: Int) -> Dict(String, SymbolInfo) {
    let bindings: Optional(Dict(String, SymbolInfo)) = c.generic_instance_bindings.lookup("" + info.type_id);
    let result: Dict(String, SymbolInfo) = extend_generic_bindings(bindings, [], []);
    if (self_type != 0) {
        result.put("Self", SymbolInfo(reg="", type=self_type, origin_type=self_type, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    }

    return result;
}

func interface_method_type_for(ref c: Compiler, info: StructInfo, node: NodeID, self_type: Int) -> Int {
    let template: Optional(GenericTemplate) = c.generic_instance_templates.lookup("" + info.type_id);
    let bindings: Dict(String, SymbolInfo) = interface_type_bindings(ref c, info, self_type);

    let previous_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
    let previous: Optional(GenericTemplate) = null;
    if ((template is !null)) {
        previous = use_generic_context(ref c, template, bindings);
    } else {
        c.generic_bindings = bindings;
    }

    let result: Int = resolve_type(ref c, node);
    if (previous is !null) {
        restore_generic_context(ref c, previous, previous_bindings);
    } else {
        c.generic_bindings = previous_bindings;
    }

    return result;
}

func interface_method_type(ref c: Compiler, info: StructInfo, node: NodeID) -> Int {
    return interface_method_type_for(ref c, info, node, 0);
}

func interface_method_sig(ref c: Compiler, info: StructInfo, node: MethodDefNode) -> String {
    if (type_node_contains_self(c.arena, node.return_type)) {
        throw_type_error(node.pos, "Method '" + node.name_tok.value + "' uses Self and cannot be called through an interface value.");
        return "void (i8*)*";
    }

    let param_index: Int = 0;
    while (param_index < node.params.length()) {
        let param: ParamNode = node.params[param_index];
        if (type_node_contains_self(c.arena, param.type_tok)) {
            throw_type_error(node.pos, "Method '" + node.name_tok.value + "' uses Self and cannot be called through an interface value.");
            return "void (i8*)*";
        }
        param_index += 1;
    }

    let template: Optional(GenericTemplate) = c.generic_instance_templates.lookup("" + info.type_id);
    if (!(template is !null)) {
        return get_method_def_sig_str(ref c, node);
    }

    let instance: GenericTemplate = template;
    let bindings: Dict(String, SymbolInfo) = c.generic_instance_bindings.get("" + info.type_id)?;
    catch(err) {
        throw_internal_compiler_error(node.pos, "Missing generic interface bindings.");
        return "void ()*";
    }
    let previous_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
    let previous: GenericTemplate = use_generic_context(ref c, instance, bindings);
    let result: String = get_method_def_sig_str(ref c, node);
    restore_generic_context(ref c, previous, previous_bindings);
    return result;
}

func is_hash_interface(ref c: Compiler, type_id: Int) -> Bool {
    let info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    return (info is !null) && info.is_interface && (info.name == "hash.Hash" || info.name == "hashing.Hash");
}

func is_eq_interface(ref c: Compiler, type_id: Int) -> Bool {
    let info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if (!(info is !null) || !info.is_interface) { return false; }
    if (info.name == "comparison.Equal") { return true; }
    let template: Optional(GenericTemplate) = c.generic_instance_templates.lookup("" + type_id);
    return (template is !null) && template.name == "hash.Eq";
}

func has_builtin_hash(ref c: Compiler, type_id: Int) -> Bool {
    type_id = get_repr_type(ref c, type_id);
    if (type_id == TYPE_STRING || type_id == TYPE_BOOL || type_id == TYPE_CHAR ||
        type_id == TYPE_BYTE || type_id == TYPE_INT8 || type_id == TYPE_INT16 ||
        type_id == TYPE_INT || type_id == TYPE_LONG || type_id == TYPE_INT128 ||
        type_id == TYPE_UINT16 || type_id == TYPE_UINT32 || type_id == TYPE_UINT64 ||
        type_id == TYPE_UINT128 || type_id == TYPE_INTSIZE || type_id == TYPE_UINTSIZE ||
        type_id == TYPE_ANYPTR || type_id == TYPE_NULLPTR) {
        return true;
    }
    if (is_pointer_type(ref c, type_id) || (c.func_ret_map.lookup(type_id) is !null) ||
        (c.method_ret_map.lookup(type_id) is !null)) {
        return true;
    }
    let info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    return (info is !null) && info.is_enum;
}

func has_builtin_equal(ref c: Compiler, type_id: Int) -> Bool {
    type_id = get_repr_type(ref c, type_id);
    if (type_id == TYPE_FLOAT || type_id == TYPE_FLOAT32) { return true; }
    return has_builtin_hash(ref c, type_id);
}

func is_comparable_interface(ref c: Compiler, type_id: Int) -> Bool {
    let info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    return (info is !null) && info.is_interface && info.name == "comparison.Comparable";
}

func is_display_interface(ref c: Compiler, type_id: Int) -> Bool {
    let info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    return (info is !null) && info.is_interface && info.name == "formatting.Display";
}

func interface_diagnostic_name(ref c: Compiler, type_id: Int) -> String {
    let info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if (!(info is !null) || !info.is_interface) {
        return get_type_name(ref c, type_id);
    }
    if (info.name == "comparison.Equal") { return "protocol.Equal"; }
    if (info.name == "comparison.Comparable") {
        return "protocol.Comparable";
    }
    if (info.name == "hashing.Hash") {
        return "protocol.Hash";
    }
    if (info.name == "formatting.Display") { return "protocol.Display"; }
    if (info.name == "formatting.Debug") {
        return "protocol.Debug";
    }
    if (info.name == "clone.Clone") {
        return "protocol.Clone";
    }
    return get_type_name(ref c, type_id);
}

func has_builtin_order(ref c: Compiler, type_id: Int) -> Bool {
    type_id = get_repr_type(ref c, type_id);
    if (type_id == TYPE_STRING || type_id == TYPE_CHAR) { return true; }
    return is_integer_type(type_id);
}

func has_builtin_display(ref c: Compiler, type_id: Int) -> Bool {
    type_id = get_repr_type(ref c, type_id);
    if (type_id == TYPE_STRING || type_id == TYPE_CHAR || type_id == TYPE_BOOL || type_id == TYPE_FLOAT || type_id == TYPE_FLOAT32) { return true; }
    if (is_integer_type(type_id)) { return true; }
    let info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    return (info is !null) && info.is_enum;
}

func implements_interface(ref c: Compiler, type_id: Int, interface_id: Int) -> Bool {
    if (type_id == interface_id) { return true; }
    if (is_hash_interface(ref c, interface_id) && has_builtin_hash(ref c, type_id)) { return true; }
    if (is_eq_interface(ref c, interface_id) && has_builtin_equal(ref c, type_id)) { return true; }
    if (is_comparable_interface(ref c, interface_id) && has_builtin_order(ref c, type_id)) {
        return true;
    }
    if (is_display_interface(ref c, interface_id) && has_builtin_display(ref c, type_id)) {
        return true;
    }
    let current: Optional(StructInfo) = c.struct_id_map.lookup(get_repr_type(ref c, type_id));
    while (current is !null) {
        let info: StructInfo = current;
        let i: Int = 0;
        while (i < info.interfaces.length()) {
            let item: TypeListNode = info.interfaces[i];
            if (item.type == interface_id) { return true; }
            i++;
        }
        if (info.parent_id == 0) {
            break;
        }
        current = c.struct_id_map.lookup(info.parent_id);
    }
    return false;
}

func check_generic_constraints(ref c: Compiler, template: GenericTemplate, bindings: Dict(String, SymbolInfo), types: Vector(Struct), pos: Position) -> Bool {
    let previous_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
    let previous: GenericTemplate = use_generic_context(ref c, template, bindings);
    let i: Int = 0;
    while (i < template.type_params.length()) {
        let param: GenericParamNode = template.type_params[i];
        let actual: TypeListNode = types[i];
        let constraint_index: Int = 0;
        while (constraint_index < param.constraints.length()) {
            let constraint_type: Int = resolve_type(ref c, param.constraints[constraint_index]);
            let constraint_info: Optional(StructInfo) = c.struct_id_map.lookup(constraint_type);
            if (!(constraint_info is !null) || !constraint_info.is_interface) {
                throw_type_error(param.pos, "Generic constraint " + interface_diagnostic_name(ref c, constraint_type) + " is not an interface.");
                restore_generic_context(ref c, previous, previous_bindings);
                return false;
            }
            if (!implements_interface(ref c, actual.type, constraint_type)) {
                throw_type_error(pos, "Type " + get_type_name(ref c, actual.type) + " does not satisfy " + interface_diagnostic_name(ref c, constraint_type) + " for '" + param.name_tok.value + "'.");
                restore_generic_context(ref c, previous, previous_bindings);
                return false;
            }
            constraint_index++;
        }
        i++;
    }
    restore_generic_context(ref c, previous, previous_bindings);
    return true;
}

func register_generic_class(ref c: Compiler, template: GenericTemplate, types: Vector(Struct), pos: Position) -> Int {
// the instance key is canonical, every use of the same binding shares one type id
    let key: String = generic_instance_name(template.name, types, ref c);
    let cached: Optional(SymbolInfo) = c.generic_instances.lookup(key);
    if ((cached is !null)) { return cached.type; }

    if (c.generic_depth >= 64) {
        throw_type_error(pos, "Generic instantiation depth exceeds 64.");
        return TYPE_POISON;
    }
    if (c.generic_instance_count >= 4096) {
        throw_type_error(pos, "Generic instantiation limit exceeded.");
        return TYPE_POISON;
    }
    c.generic_instance_count += 1;

    let node: ClassDefNode = get_class_def_node(ref c.arena, template.node);
    let bindings: Dict(String, SymbolInfo) = generic_bindings(template.type_params, types);
    if (!check_generic_constraints(ref c, template, bindings, types, pos)) { return TYPE_POISON; }
    let new_id: Int = c.type_counter;
    c.type_counter += 1;

    let info: StructInfo = StructInfo(
        name=key,
        type_id=new_id,
        fields=[],
        llvm_name="%class.__generic." + new_id,
        init_body=template.node,
        is_class=true,
        vtable_name="@vtable.__generic." + new_id,
        parent_id=0,
        vtable=[],
        ann_flags=0,
        compiler_link_name="",
        is_enum=false,
        is_error=false,
        is_interface=false,
        interfaces=[],
        layout_ready=false
    );
    // publish the shell before resolving fields so recursive types find this instance
    c.generic_instances.put(key, SymbolInfo(reg="", type=new_id, origin_type=new_id, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    c.generic_type_names.put("" + new_id, StringConstant(id=0, value=generic_type_name(template.name, types, ref c)));
    c.generic_instance_bindings.put("" + new_id, bindings);
    c.generic_instance_templates.put("" + new_id, template);
    c.struct_table.put(key, info);
    c.struct_id_map.put(new_id, info);
    c.type_revision++;
    c.type_drop_list.append(TypeListNode(type=new_id, pass_mode=0));

    let previous_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
    let previous: GenericTemplate = use_generic_context(ref c, template, bindings);

    let parent_info: Optional(StructInfo) = null;
    if (has_node(node.parent_tok)) {
        let parent_type: Int = resolve_type(ref c, node.parent_tok);

        parent_info = c.struct_id_map.lookup(parent_type);
        if (!(parent_info is !null) || !parent_info.is_class) {
            throw_type_error(pos, "Type " + get_type_name(ref c, parent_type) + " is not a class.");
            restore_generic_context(ref c, previous, previous_bindings);
            return TYPE_POISON;
        }
        info.parent_id = parent_type;
    }

    let interfaces: Vector(Struct) = [];
    let inherited_interface_index: Int = 0;
    while ((parent_info is !null) && inherited_interface_index < parent_info.interfaces.length()) {
        interfaces.append(parent_info.interfaces[inherited_interface_index]);
        inherited_interface_index++;
    }

    let interface_index: Int = 0;
    while (interface_index < node.interfaces.length()) {
        let interface_type: Int = resolve_type(ref c, node.interfaces[interface_index]);
        let interface_info: Optional(StructInfo) = c.struct_id_map.lookup(interface_type);
        if (!(interface_info is !null) || !interface_info.is_interface) {
            throw_type_error(pos, "Type " + get_type_name(ref c, interface_type) + " is not an interface.");
            restore_generic_context(ref c, previous, previous_bindings);
            return TYPE_POISON;
        }
        interfaces.append(TypeListNode(type=interface_type, pass_mode=0));
        interface_index++;
    }
    info.interfaces = interfaces;

    let fields: Vector(Struct) = [];
    let field_names: Dict(String, StringConstant) = Dict();
    if ((parent_info is !null)) {
        let meta_parent_info: StructInfo = parent_info;
        let inherited_field_index: Int = 0;
        while (inherited_field_index < meta_parent_info.fields.length()) {
            let inherited_field: FieldInfo = meta_parent_info.fields[inherited_field_index];
            fields.append(inherited_field);
            field_names.put(inherited_field.name, StringConstant(id=0, value=inherited_field.name));
            inherited_field_index++;
        }
    } else {
        fields.append(FieldInfo(name="_vptr", type=TYPE_VOID, llvm_type="i8*", offset=0, is_const=true, default_val=NodeID(0U)));
        field_names.put("_vptr", StringConstant(id=0, value="_vptr"));
    }

    let field_index: Int = 0;
    while (field_index < node.fields.length()) {
        let field: VarDeclareNode = get_var_decl_node(ref c.arena, node.fields[field_index]);
        let field_name: String = field.name_tok.value;
        if (field_names.contains_key(field_name)) {
            throw_name_error(field.pos, "Field '" + field_name + "' is already defined in class '" + generic_type_name(template.name, types, ref c) + "'.");
            restore_generic_context(ref c, previous, previous_bindings);
            return TYPE_POISON;
        }
        if ((parent_info is !null) && (find_method(parent_info.vtable, field_name) is !null)) {
            throw_name_error(field.pos, "Class '" + generic_type_name(template.name, types, ref c) + "' cannot use '" + field_name + "' as both a field and a method.");
            restore_generic_context(ref c, previous, previous_bindings);
            return TYPE_POISON;
        }

        let field_type: Int = resolve_type(ref c, field.type_node);
        if (field_type == TYPE_AUTO) {
            if (!has_node(field.value)) {
                throw_type_error(field.pos, "Field '" + field_name + "' needs an explicit type when it has no initializer.");
                restore_generic_context(ref c, previous, previous_bindings);
                return TYPE_POISON;
            }
            field_type = get_expr_type(ref c, field.value);
        }

        if (field_type == TYPE_AUTO || field_type == TYPE_POISON) {
            restore_generic_context(ref c, previous, previous_bindings);
            return TYPE_POISON;
        }

        field_names.put(field_name, StringConstant(id=0, value=field_name));
        fields.append(FieldInfo(name=field_name, type=field_type, llvm_type=get_llvm_type_str(ref c, field_type), offset=fields.length(), is_const=field.is_const, default_val=NodeID(0U)));
        field_index += 1;
    }
    info.fields = fields;

    let methods: Vector(Struct) = [];
    let inherited_method_index: Int = 0;
    while ((parent_info is !null) && inherited_method_index < parent_info.vtable.length()) {
        methods.append(parent_info.vtable[inherited_method_index]);
        inherited_method_index++;
    }

    let method_index: Int = 0;
    while (method_index < node.methods.length()) {
        let method_node: MethodDefNode = get_method_def_node(ref c.arena, node.methods[method_index]);
        let method_name: String = method_base_name(ref c, method_node);

        if (!method_name.starts_with("$") && field_names.contains_key(method_name)) {
            throw_name_error(method_node.pos, "Class '" + generic_type_name(template.name, types, ref c) + "' cannot use '" + method_name + "' as both a field and a method.");
            restore_generic_context(ref c, previous, previous_bindings);
            return TYPE_POISON;
        }

        if (method_node.type_params.length() > 0) {
            let method_key: String = key + "_" + method_name;
            if ((c.generic_methods.lookup(method_key) is !null) || (c.func_table.lookup(method_key) is !null)) {
                throw_name_error(method_node.pos, "Method '" + method_key + "' is already defined.");
                restore_generic_context(ref c, previous, previous_bindings);
                return TYPE_POISON;
            }

            let generic_method: GenericTemplate = GenericTemplate(
                name=method_key, node=node.methods[method_index],
                type_params=method_node.type_params, prefix=template.prefix,
                dir=template.dir, visible=template.visible,
                namespaces=template.namespaces, types=template.types,
                funcs=template.funcs, globals=template.globals
            );
            c.generic_methods.put(method_key, generic_method);
            method_index++;
            continue;
        }

        let return_type: Int = resolve_type(ref c, method_node.return_type);
        if (return_type == TYPE_AUTO || return_type == TYPE_POISON) {
            throw_type_error(method_node.pos, "Auto return type deduction is not supported in methods.");
            restore_generic_context(ref c, previous, previous_bindings);
            return TYPE_POISON;
        }

        let arg_types: Vector(Struct) = [TypeListNode(type=new_id, pass_mode=0)];
        let arg_names: Vector(String) = ["self"];
        let param_names: Dict(String, StringConstant) = Dict();
        let param_index: Int = 0;
        while (param_index < method_node.params.length()) {
            let param: ParamNode = method_node.params[param_index];
            if (param_names.contains_key(param.name_tok.value)) {
                throw_name_error(param.pos, "Parameter '" + param.name_tok.value + "' is already defined in method '" + method_name + "'.");
                restore_generic_context(ref c, previous, previous_bindings);
                return TYPE_POISON;
            }

            let param_type: Int = callable_param_type(ref c, param);
            if (param_type == TYPE_AUTO || param_type == TYPE_POISON) {
                throw_type_error(param.pos, "Auto cannot be used in method parameters.");
                restore_generic_context(ref c, previous, previous_bindings);
                return TYPE_POISON;
            }

            param_names.put(param.name_tok.value, StringConstant(id=0, value=param.name_tok.value));
            arg_types.append(TypeListNode(type=param_type, pass_mode=param.pass_mode));
            arg_names.append(param.name_tok.value);
            param_index += 1;
        }

        let method_key: String = key + "_" + method_name;
        if ((c.func_table.lookup(method_key) is !null) || (c.generic_methods.lookup(method_key) is !null)) {
            throw_name_error(method_node.pos, "Method '" + method_key + "' is already defined.");
            restore_generic_context(ref c, previous, previous_bindings);
            return TYPE_POISON;
        }

        let symbol: String = mangle_wl_name(ref c, key + ".", method_name, arg_types);
        let method_anns: SystemAnnResult = consume_annotations(ref c, method_node.annotations, method_name);
        let link_name: String = method_anns.compiler_link_name;

        let func_info: FuncInfo = FuncInfo(
            name=symbol,
            base_name=method_name,
            ret_type=return_type,
            arg_types=arg_types,
            arg_names=arg_names,
            is_varargs=false,
            compiler_link_name=link_name,
            mutates_self=true,
            variadic_param=variadic_param_index(method_node.params),
            default_args=param_defaults(method_node.params),
            ref_body=method_node.body,
            ref_context=template,
            ref_bindings=bindings,
            ann_flags=0,
            abi_name=""
        );
        c.func_table.put(method_key, func_info);
        let class_method: GenericTemplate = GenericTemplate(
            name=method_key, node=node.methods[method_index], type_params=[],
            prefix=template.prefix, dir=template.dir, visible=template.visible,
            namespaces=template.namespaces, types=template.types,
            funcs=template.funcs, globals=template.globals
        );
        c.generic_class_methods.put(method_key, class_method);
        if (method_name == "$init" || method_name == "$deinit") {
            queue_generic_class_method(ref c, info, method_name);
        }
        if (method_name != "$init" && method_name != "$field_init" && link_name.length() == 0) {
            let replaced: Bool = false;
            let inherited_index: Int = 0;
            while (inherited_index < methods.length()) {
                let inherited_method: FuncInfo = methods[inherited_index];
                if (inherited_method.base_name == method_name) {
                    if (inherited_method.ret_type != func_info.ret_type || inherited_method.arg_types.length() != func_info.arg_types.length()) {
                        throw_type_error(method_node.pos, "Override of '" + method_name + "' does not match the parent method signature.");
                        restore_generic_context(ref c, previous, previous_bindings);
                        return TYPE_POISON;
                    }

                    methods[inherited_index] = func_info;
                    replaced = true;
                    break;
                }
                inherited_index++;
            }

            if (!replaced) {
                methods.append(func_info);
            }
        }
        method_index += 1;
    }
    info.vtable = methods;
    store_struct(ref c, info);
    restore_generic_context(ref c, previous, previous_bindings);
    c.generic_class_worklist.append(GenericClassInstance(template=template, bindings=bindings, type_id=new_id, depth=c.generic_depth));
    return new_id;
}

func queue_generic_class_method(ref c: Compiler, owner: StructInfo, name: String) -> Void {
    if (!has_struct(owner) || !(c.generic_instance_templates.lookup("" + owner.type_id) is !null)) {
        return;
    }

    let key: String = owner.name + "_" + name;
    if (c.generic_methods_queued.contains_key(key)) {
        return;
    }

    let template: Optional(GenericTemplate) = c.generic_class_methods.lookup(key);
    if (!(template is !null)) {
        return;
    }

    let bindings: Optional(Dict(String, SymbolInfo)) = c.generic_instance_bindings.lookup("" + owner.type_id);
    if (bindings is null) {
        throw_internal_compiler_error(Position(idx=0, ln=0, col=0, text="", fn=""), "Missing generic class bindings.");
        return;
    }
    c.generic_methods_queued.put(key, true);
    c.generic_method_worklist.append(GenericMethodInstance(template=template, bindings=bindings, func_key=key, owner_name=owner.name, depth=c.generic_depth));
}

func is_type_parameter(template: GenericTemplate, name: String) -> Bool {
    let i: Int = 0;
    while (i < template.type_params.length()) {
        let param: GenericParamNode = template.type_params[i];
        if (param.name_tok.value == name) { return true; }
        i += 1;
    }
    return false;
}

func bind_inferred_type(inferred: Dict(String, SymbolInfo), name: String, actual: Int, pos: Position) -> Bool {
    if (actual == 0 || actual == TYPE_AUTO || actual == TYPE_POISON) { return true; }

    let previous: Optional(SymbolInfo) = inferred.lookup(name);
    if ((previous is !null) && previous.type != actual) {
        throw_type_error(pos, "Conflicting types inferred for '" + name + "'.");
        return false;
    }
    inferred.put(name, SymbolInfo(reg="", type=actual, origin_type=actual, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));
    return true;
}

func infer_type_args(ref c: Compiler, template: GenericTemplate, pattern: NodeID, actual: Int, inferred: Dict(String, SymbolInfo), pos: Position) -> Bool {
// walk the declared type shape and bind parameters from the concrete argument
    if (!has_node(pattern) || actual == 0 || actual == TYPE_AUTO || actual == TYPE_POISON) {
        return true;
    }
    let base: Int = node_tag(pattern);

    if (base == NODE_VAR_ACCESS) {
        let named: VarAccessNode = get_var_access_node(ref c.arena, pattern);
        if (is_type_parameter(template, named.name_tok.value)) {
            return bind_inferred_type(inferred, named.name_tok.value, actual, pos);
        }
        return true;
    }

    if (base == NODE_VECTOR_TYPE) {
        let vector: Optional(SymbolInfo) = c.vector_base_map.lookup(actual);
        if (!(vector is !null)) { return true; }
        let pattern_vector: VectorTypeNode = get_vector_type_node(ref c.arena, pattern);
        return infer_type_args(ref c, template, pattern_vector.element_type, vector.type, inferred, pos);
    }

    if (base == NODE_SLICE_TYPE) {
        let slice: Optional(ArrayInfo) = c.array_info_map.lookup(actual);
        if (!(slice is !null) || slice.size != -1) { return true; }
        let pattern_slice: SliceTypeNode = get_slice_type_node(ref c.arena, pattern);
        return infer_type_args(ref c, template, pattern_slice.element_type, slice.base_type, inferred, pos);
    }

    if (base == NODE_ARRAY_TYPE) {
        let array: Optional(ArrayInfo) = c.array_info_map.lookup(actual);
        if (!(array is !null) || array.size < 0) { return true; }
        let meta_array: ArrayInfo = array;
        let pattern_array: ArrayTypeNode = get_array_type_node(ref c.arena, pattern);
        return infer_type_args(ref c, template, pattern_array.base_type, meta_array.base_type, inferred, pos);
    }

    if (base == NODE_PTR_TYPE) {
        let pointer: PointerTypeNode = get_pointer_type_node(ref c.arena, pattern);
        let current: Int = actual;
        let level: Int = 0;
        while (level < pointer.level) {
            let ptr_info: Optional(SymbolInfo) = c.ptr_base_map.lookup(current);
            if (!(ptr_info is !null)) { return true; }
            let meta_ptr_info: SymbolInfo = ptr_info;

            current = meta_ptr_info.type;
            level += 1;
        }
        return infer_type_args(ref c, template, pointer.base_type, current, inferred, pos);
    }

    if (base == NODE_FALLIBLE_TYPE) {
        let fallible: Optional(SymbolInfo) = c.fallible_base_map.lookup(actual);
        if (!(fallible is !null)) { return true; }
        let meta_fallible: SymbolInfo = fallible;
        let pattern_fallible: FallibleTypeNode = get_fallible_type_node(ref c.arena, pattern);
        return infer_type_args(ref c, template, pattern_fallible.base_type, meta_fallible.type, inferred, pos);
    }

    if (base == NODE_GENERIC_TYPE) {
        let generic: GenericTypeNode = get_generic_type_node(ref c.arena, pattern);
        let generic_base: Int = node_tag(generic.base_type);
        if (generic_base == NODE_VAR_ACCESS) {
            let named: VarAccessNode = get_var_access_node(ref c.arena, generic.base_type);
            if (named.name_tok.value == "Vector") {
                let vector: Optional(SymbolInfo) = c.vector_base_map.lookup(actual);
                if ((vector is !null) && generic.type_args.length() == 1) {
                    return infer_type_args(ref c, template, generic.type_args[0], vector.type, inferred, pos);
                }
                return true;
            }
            if (named.name_tok.value == "Array") {
                let slice: Optional(ArrayInfo) = c.array_info_map.lookup(actual);
                if ((slice is !null) && slice.size == -1 && generic.type_args.length() == 1) {
                    return infer_type_args(ref c, template, generic.type_args[0], slice.base_type, inferred, pos);
                }
                return true;
            }

            let actual_bindings: Optional(Dict(String, SymbolInfo)) = c.generic_instance_bindings.lookup("" + actual);
            let actual_info: Optional(StructInfo) = c.struct_id_map.lookup(actual);
            if (actual_bindings is null || !(actual_info is !null)) { return true; }
            let meta_actual_bindings: Dict(String, SymbolInfo) = actual_bindings;

            let generic_name: String = named.name_tok.value;
            if (c.current_package_prefix != "" && (c.generic_structs.lookup(c.current_package_prefix + generic_name) is !null)) {
                generic_name = c.current_package_prefix + generic_name;
            }

            let alias: Optional(String) = c.current_file_type_aliases.lookup(generic_name);
            if (alias is !null) { generic_name = alias; }

            let nested_template: Optional(GenericTemplate) = c.generic_structs.lookup(generic_name);
            if (!(nested_template is !null) || !actual_info.name.starts_with(generic_name + "$")) {
                return true;
            }
            let meta_nested_template: GenericTemplate = nested_template;

            let i: Int = 0;
            while (i < generic.type_args.length() && i < meta_nested_template.type_params.length()) {
                let nested_param: GenericParamNode = meta_nested_template.type_params[i];
                let nested_actual: Optional(SymbolInfo) = meta_actual_bindings.lookup(nested_param.name_tok.value);
                if ((nested_actual is !null) &&
                    !infer_type_args(ref c, template, generic.type_args[i], nested_actual.type, inferred, pos)) {
                    return false;
                }
                i += 1;
            }
        }
    }

    return true;
}

func generic_constructor_context(ref c: Compiler, template: GenericTemplate, expected: Int) -> Int {
// only a unique matching arm supplies type arguments, other union members give no context
    expected = get_repr_type(ref c, expected);
    let found_union: Optional(UnionInfo) = get_union_type(ref c, expected);
    if (found_union is null) { return expected; }
    let union: UnionInfo = found_union;

    let match = 0;
    let i = 0;
    while (i < union.members.length()) {
        let member = get_repr_type(ref c, union.members[i]);
        let instance = c.generic_instance_templates.lookup("" + member);
        if ((instance is !null) && instance.name == template.name) {
            if (match != 0) { return 0; }
            match = member;
        }
        i++;
    }

    return match;
}

func infer_generic_instance(ref c: Compiler, template: GenericTemplate, actual: Int, inferred: Dict(String, SymbolInfo), pos: Position) -> Bool {
    if (actual == 0 || actual == TYPE_AUTO || actual == TYPE_POISON) { return true; }
    actual = generic_constructor_context(ref c, template, actual);
    if (actual == 0) { return true; }

    let actual_template: Optional(GenericTemplate) = c.generic_instance_templates.lookup("" + actual);
    if (!(actual_template is !null) || actual_template.name != template.name) { return true; }

    let actual_bindings: Optional(Dict(String, SymbolInfo)) = c.generic_instance_bindings.lookup("" + actual);
    if (actual_bindings is null) { return true; }
    let meta_actual_bindings: Dict(String, SymbolInfo) = actual_bindings;

    let i: Int = 0;
    while (i < template.type_params.length()) {
        let param: GenericParamNode = template.type_params[i];
        let binding: Optional(SymbolInfo) = meta_actual_bindings.lookup(param.name_tok.value);
        if ((binding is !null) && !bind_inferred_type(inferred, param.name_tok.value, binding.type, pos)) {
            return false;
        }
        i += 1;
    }
    return true;
}

func concrete_constructor_accepts(ref c: Compiler, name: String, args: Vector(ArgNode)) -> Bool {
    let info: Optional(StructInfo) = c.struct_table.lookup(name);
    if (!(info is !null)) { return false; }

    let count: Int = args.length();
    if (!info.is_class) {
        let fields: Int = info.fields.length();
        return count == fields;
    }
    let init: Optional(FuncInfo) = c.func_table.lookup(info.name + "_$init");
    if (!(init is !null)) {
        return count == 0;
    }
    let params: Int = init.arg_types.length() - 1;
    return count == params;
}

func use_generic_constructor(ref c: Compiler, name: String, template: GenericTemplate, explicit: Vector(NodeID), args: Vector(ArgNode), expected: Int) -> Bool {
    if (!has_template(template)) { return false; }
    if (explicit.length() != 0) { return true; }

    expected = generic_constructor_context(ref c, template, expected);
    let expected_template: Optional(GenericTemplate) = c.generic_instance_templates.lookup("" + expected);
    if ((expected_template is !null) && expected_template.name == template.name) { return true; }
    return !concrete_constructor_accepts(ref c, name, args);
}

func generic_constructor_params(ref c: Compiler, template: GenericTemplate) -> Vector(ParamNode) {
    let base: Int = node_tag(template.node);
    if (base == NODE_STRUCT_DEF) {
        let node: StructDefNode = get_struct_def_node(ref c.arena, template.node);
        return node.fields;
    }
    if (base == NODE_CLASS_DEF) {
        let node: ClassDefNode = get_class_def_node(ref c.arena, template.node);
        let i: Int = 0;
        while (i < node.methods.length()) {
            let member: MethodDefNode = get_method_def_node(ref c.arena, node.methods[i]);
            if (member.name_tok.value == "$init") { return member.params; }
            i += 1;
        }
    }
    return [];
}

func generic_call_param(params: Vector(ParamNode), arg: ArgNode, index: Int) -> Int {
    if (arg.name.length() == 0) {
        let variadic: Int = variadic_param_index(params);
        if (variadic > 0 && index >= variadic - 1) {
            return variadic - 1;
        }
        if (index < params.length()) { return index; }
        return -1;
    }

    let i: Int = 0;
    while (i < params.length()) {
        let param: ParamNode = params[i];
        if (param.name_tok.value == arg.name) { return i; }
        i += 1;
    }
    return -1;
}

func generic_arg_type(ref c: Compiler, arg: ArgNode, params: Vector(ParamNode), param_index: Int) -> Int {
    let previous_expected: Int = c.expected_type;
    c.expected_type = 0;
    let actual_type: Int = get_expr_type(ref c, arg.val);
    c.expected_type = previous_expected;

    if (param_index >= 0 && params[param_index].pass_mode == PARAM_REF) {
        let pointer: Optional(SymbolInfo) = c.ptr_base_map.lookup(actual_type);
        if ((pointer is !null)) { return pointer.type; }
    }

    if (!arg.is_spread || param_index < 0 || !params[param_index].is_variadic) { return actual_type; }

    let array_info: Optional(ArrayInfo) = c.array_info_map.lookup(actual_type);
    if ((array_info is !null)) { return array_info.base_type; }
    let vector_info: Optional(SymbolInfo) = c.vector_base_map.lookup(actual_type);
    if ((vector_info is !null)) { return vector_info.type; }
    return actual_type;
}

func resolve_generic_constructor_args(ref c: Compiler, template: GenericTemplate, explicit: Vector(NodeID), args: Vector(ArgNode), expected: Int, pos: Position) -> Optional(Vector(Struct)) {
    let result: Vector(Struct) = [];
    let count: Int = template.type_params.length();
    let i: Int = 0;
    if (explicit.length() != 0) {
        if (explicit.length() != count) {
            throw_type_error(pos, "Type '" + template.name + "' expects " + count + " type arguments, got " + explicit.length() + ".");
            return null;
        }
        while (i < explicit.length()) {
            let type_id: Int = resolve_type(ref c, explicit[i]);
            if (type_id == TYPE_POISON) { return null; }
            result.append(TypeListNode(type=type_id, pass_mode=0));
            i += 1;
        }
        return result;
    }

    let inferred: Dict(String, SymbolInfo) = Dict();
    if (!infer_generic_instance(ref c, template, expected, inferred, pos)) { return null; }

    let params: Vector(ParamNode) = generic_constructor_params(ref c, template);
    i = 0;
    while (i < args.length()) {
        let arg: ArgNode = args[i];
        let param_index: Int = generic_call_param(params, arg, i);
        if (param_index < 0) {
            i += 1;
            continue;
        }
        let param: ParamNode = params[param_index];
        let actual_type: Int = generic_arg_type(ref c, arg, params, param_index);
        if (actual_type == TYPE_POISON) { return null; }
        if (!infer_type_args(ref c, template, param.type_tok, actual_type, inferred, pos)) {
            return null;
        }
        i += 1;
    }
    i = 0;
    while (i < count) {
        let type_param: GenericParamNode = template.type_params[i];
        let inferred_type: Optional(SymbolInfo) = inferred.lookup(type_param.name_tok.value);
        if (!(inferred_type is !null)) {
            throw_type_error(pos, "Cannot infer type argument '" + type_param.name_tok.value + "' for type '" + template.name + "'.");
            return null;
        }
        result.append(TypeListNode(type=inferred_type.type, pass_mode=0));
        i += 1;
    }
    return result;
}

func resolve_generic_args(ref c: Compiler, template: GenericTemplate, explicit: Vector(NodeID), args: Vector(ArgNode), pos: Position) -> Optional(Vector(Struct)) {
    let result: Vector(Struct) = [];
    let count: Int = template.type_params.length();
    let i: Int = 0;
    if (explicit.length() != 0) {
        if (explicit.length() != count) {
            throw_type_error(pos, "Function '" + template.name + "' expects " + count + " type arguments, got " + explicit.length() + ".");
            return null;
        }
        while (i < explicit.length()) {
            let type_id: Int = resolve_type(ref c, explicit[i]);
            if (type_id == TYPE_POISON) { return null; }
            result.append(TypeListNode(type=type_id, pass_mode=0));
            i += 1;
        }
        return result;
    }

    let node: FunctionDefNode = get_func_def_node(ref c.arena, template.node);
    let inferred: Dict(String, SymbolInfo) = Dict();
    if (!infer_type_args(ref c, template, node.ret_type_tok, c.expected_type, inferred, pos)) {
        return null;
    }

    i = 0;
    while (i < args.length()) {
        let arg: ArgNode = args[i];
        let param_index: Int = generic_call_param(node.params, arg, i);
        if (param_index < 0) {
            i += 1;
            continue;
        }

        let param: ParamNode = node.params[param_index];
        let actual_type: Int = generic_arg_type(ref c, arg, node.params, param_index);

        if (actual_type == TYPE_POISON) { return null; }
        if (!infer_type_args(ref c, template, param.type_tok, actual_type, inferred, pos)) { return null; }
        i += 1;
    }

    i = 0;
    while (i < count) {
        let type_param: GenericParamNode = template.type_params[i];
        let inferred_type: Optional(SymbolInfo) = inferred.lookup(type_param.name_tok.value);
        if (!(inferred_type is !null)) {
            throw_type_error(pos, "Cannot infer type argument '" + type_param.name_tok.value + "' for function '" + template.name + "'.");
            return null;
        }

        result.append(TypeListNode(type=inferred_type.type, pass_mode=0));
        i += 1;
    }
    return result;
}

func resolve_generic_method_args(ref c: Compiler, template: GenericTemplate, explicit: Vector(NodeID), args: Vector(ArgNode), pos: Position) -> Optional(Vector(Struct)) {
    let result: Vector(Struct) = [];
    let count: Int = template.type_params.length();
    let i: Int = 0;
    if (explicit.length() != 0) {
        if (explicit.length() != count) {
            let method_node: MethodDefNode = get_method_def_node(ref c.arena, template.node);
            throw_type_error(pos, "Method '" + method_node.name_tok.value + "' expects " + count + " type arguments, got " + explicit.length() + ".");
            return null;
        }
        while (i < explicit.length()) {
            let type_id: Int = resolve_type(ref c, explicit[i]);
            if (type_id == TYPE_POISON) { return null; }
            result.append(TypeListNode(type=type_id, pass_mode=0));
            i++;
        }
        return result;
    }

    let node: MethodDefNode = get_method_def_node(ref c.arena, template.node);
    let inferred: Dict(String, SymbolInfo) = Dict();
    if (!infer_type_args(ref c, template, node.return_type, c.expected_type, inferred, pos)) { return null; }

    i = 0;
    while (i < args.length()) {
        let arg: ArgNode = args[i];
        let param_index: Int = generic_call_param(node.params, arg, i);
        if (param_index >= 0) {
            let param: ParamNode = node.params[param_index];
            let actual_type: Int = generic_arg_type(ref c, arg, node.params, param_index);
            if (actual_type == TYPE_POISON) { return null; }
            if (!infer_type_args(ref c, template, param.type_tok, actual_type, inferred, pos)) {
                return null;
            }
        }
        i++;
    }

    i = 0;
    while (i < count) {
        let type_param: GenericParamNode = template.type_params[i];
        let inferred_type: Optional(SymbolInfo) = inferred.lookup(type_param.name_tok.value);
        if (!(inferred_type is !null)) {
            throw_type_error(pos, "Cannot infer type argument '" + type_param.name_tok.value + "' for method '" + node.name_tok.value + "'.");
            return null;
        }
        result.append(TypeListNode(type=inferred_type.type, pass_mode=0));
        i++;
    }
    return result;
}

func register_generic_method(ref c: Compiler, template: GenericTemplate, owner: StructInfo, types: Vector(Struct), pos: Position) -> Optional(FuncInfo) {
    let key: String = generic_instance_name(template.name, types, ref c);
    let cached: Optional(FuncInfo) = c.func_table.lookup(key);
    if ((cached is !null)) { return cached; }
    if (c.generic_depth >= 64) {
        throw_type_error(pos, "Generic instantiation depth exceeds 64.");
        return null;
    }
    if (c.generic_instance_count >= 4096) {
        throw_type_error(pos, "Generic instantiation limit exceeded.");
        return null;
    }
    c.generic_instance_count++;

    let node: MethodDefNode = get_method_def_node(ref c.arena, template.node);
    let owner_bindings: Optional(Dict(String, SymbolInfo)) = c.generic_instance_bindings.lookup("" + owner.type_id);
    let bindings: Dict(String, SymbolInfo) = extend_generic_bindings(owner_bindings, template.type_params, types);
    if (!check_generic_constraints(ref c, template, bindings, types, pos)) {
        return null;
    }
    let previous_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
    let previous: GenericTemplate = use_generic_context(ref c, template, bindings);
    c.generic_depth++;

    let return_type: Int = resolve_type(ref c, node.return_type);
    let arg_types: Vector(Struct) = [TypeListNode(type=owner.type_id, pass_mode=0)];
    let arg_names: Vector(String) = ["self"];
    let i: Int = 0;
    while (i < node.params.length()) {
        let param: ParamNode = node.params[i];
        arg_types.append(callable_param(ref c, param));
        arg_names.append(param.name_tok.value);
        i++;
    }

    let symbol: String = mangle_wl_name(ref c, owner.name + ".", key, arg_types);
    let info: FuncInfo = FuncInfo(
        name=symbol,
        base_name=node.name_tok.value,
        ret_type=return_type,
        arg_types=arg_types,
        arg_names=arg_names,
        is_varargs=false,
        ann_flags=0,
        compiler_link_name="",
        abi_name="",
        mutates_self=false,
        variadic_param=variadic_param_index(node.params),
        default_args=param_defaults(node.params),
        ref_body=node.body,
        ref_context=template,
        ref_bindings=bindings
    );
    c.func_table.put(key, info);
    c.generic_method_worklist.append(GenericMethodInstance(template=template, bindings=bindings, func_key=key, owner_name=owner.name, depth=c.generic_depth));

    c.generic_depth--;
    restore_generic_context(ref c, previous, previous_bindings);
    return info;
}

func register_generic_func(ref c: Compiler, template: GenericTemplate, types: Vector(Struct), pos: Position) -> Optional(FuncInfo) {
    let key: String = generic_instance_name(template.name, types, ref c);
    let cached: Optional(FuncInfo) = c.func_table.lookup(key);
    if ((cached is !null)) { return cached; }

    if (c.generic_depth >= 64) {
        throw_type_error(pos, "Generic instantiation depth exceeds 64.");
        return null;
    }

    if (c.generic_instance_count >= 4096) {
        throw_type_error(pos, "Generic instantiation limit exceeded.");
        return null;
    }

    c.generic_instance_count += 1;

    let node: FunctionDefNode = get_func_def_node(ref c.arena, template.node);
    let bindings: Dict(String, SymbolInfo) = generic_bindings(template.type_params, types);
    if (!check_generic_constraints(ref c, template, bindings, types, pos)) {
        return null;
    }
    let previous_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
    let previous: GenericTemplate = use_generic_context(ref c, template, bindings);
    c.generic_depth += 1;

    let ret_type: Int = resolve_type(ref c, node.ret_type_tok);
    let arg_types: Vector(Struct) = [];
    let arg_names: Vector(String) = [];

    let i: Int = 0;
    while (i < node.params.length()) {
        let param: ParamNode = node.params[i];
        arg_types.append(callable_param(ref c, param));
        arg_names.append(param.name_tok.value);
        i += 1;
    }

    let symbol: String = mangle_wl_name(ref c, template.prefix, key, arg_types);
    let info: FuncInfo = FuncInfo(
        name=symbol,
        base_name=template.name,
        ret_type=ret_type,
        arg_types=arg_types,
        arg_names=arg_names,
        is_varargs=false,
        ann_flags=0,
        compiler_link_name="",
        abi_name="",
        mutates_self=false,
        variadic_param=variadic_param_index(node.params),
        default_args=param_defaults(node.params),
        ref_body=node.body,
        ref_context=template,
        ref_bindings=bindings
    );
    c.func_table.put(key, info);
    c.generic_worklist.append(GenericFuncInstance(template=template, bindings=bindings, func_key=key, depth=c.generic_depth));

    c.generic_depth -= 1;
    restore_generic_context(ref c, previous, previous_bindings);
    return info;
}

func resolve_type(ref c: Compiler, node: NodeID) -> Int {
// compound and generic types are interned here, callers directly compare their ids
    if (!has_node(node)) { return TYPE_VOID; }
    let base: Int = node_tag(node);

    if (base == NODE_UNION_TYPE) {
        let union: UnionTypeNode = get_union_type_node(ref c.arena, node);
        let members: Vector(Int) = [];
        let i: Int = 0;
        while (i < union.members.length()) {
            let member: Int = resolve_type(ref c, union.members[i]);
            if (!add_union_member(ref c, members, member, union.pos)) {
                return TYPE_POISON;
            }
            i++;
        }
        return get_union_type_id(ref c, members, union.pos);
    }

    if (base == NODE_GENERIC_TYPE) {
        let generic: GenericTypeNode = get_generic_type_node(ref c.arena, node);
        let base_node: Int = node_tag(generic.base_type);
        if (base_node != NODE_VAR_ACCESS && base_node != NODE_FIELD_ACCESS) {
            throw_type_error(generic.pos, "Generic types must name a declared type.");
            return TYPE_POISON;
        }
        let args: Vector(NodeID) = generic.type_args;
        let simple_name: String = "";
        if (base_node == NODE_VAR_ACCESS) {
            let named: VarAccessNode = get_var_access_node(ref c.arena, generic.base_type);
            simple_name = named.name_tok.value;
        }
        if (simple_name == "Vector") {
            if (args.length() != 1) {
                throw_type_error(generic.pos, "Vector expects 1 type argument.");
                return TYPE_POISON;
            }
            return get_vector_type_id(ref c, resolve_type(ref c, args[0]));
        }
        if (simple_name == "Array") {
            if (args.length() != 1) {
                throw_type_error(generic.pos, "Array expects 1 type argument.");
                return TYPE_POISON;
            }
            return get_slice_type_id(ref c, resolve_type(ref c, args[0]));
        }
        let key: String = generic_symbol_name(ref c, generic.base_type, false);
        let template: Optional(GenericTemplate) = c.generic_structs.lookup(key);
        if (!(template is !null)) {
            let exported_key: Optional(String) = c.global_type_aliases.lookup(key);
            if (exported_key is !null) {
                template = c.generic_structs.lookup(exported_key);
                key = exported_key;
            }
        }
        if (!(template is !null) && base_node == NODE_VAR_ACCESS) {
            let named: VarAccessNode = get_var_access_node(ref c.arena, generic.base_type);
            let import_key: Optional(String) = c.current_file_type_aliases.lookup(named.name_tok.value);
            if (import_key is !null) {
                template = c.generic_structs.lookup(import_key);
                key = import_key;
            }
        }
        if (!(template is !null)) {
            throw_type_error(generic.pos, "Type '" + key + "' is not generic.");
            return TYPE_POISON;
        }
        let meta_template: GenericTemplate = template;
        if (args.length() != meta_template.type_params.length()) {
            let got: Int = args.length();
            throw_type_error(generic.pos, "Type '" + key + "' expects " + meta_template.type_params.length() + " type arguments, got " + got + ".");
            return TYPE_POISON;
        }
        let instance_key: String = key;
        let concrete: Vector(Struct) = [];
        let i: Int = 0;
        while (i < args.length()) {
            let arg_type: Int = resolve_type(ref c, args[i]);
            if (arg_type == TYPE_POISON) { return TYPE_POISON; }
            concrete.append(TypeListNode(type=arg_type, pass_mode=0));
            instance_key += "$" + mangle_type(ref c, arg_type);
            i += 1;
        }

        let cached: Optional(SymbolInfo) = c.generic_instances.lookup(instance_key);
        if ((cached is !null)) {
            if (cached.type == TYPE_POISON && node_tag(meta_template.node) == NODE_TYPE_DECL) {
                throw_type_error(generic.pos, "Type alias '" + key + "' is recursive.");
            }
            return cached.type;
        }

        let template_base: Int = node_tag(meta_template.node);
        if (template_base == NODE_TYPE_DECL) {
            return instantiate_alias(ref c, meta_template, concrete, instance_key, generic.pos);
        }
        if (template_base == NODE_CLASS_DEF) {
            return register_generic_class(ref c, meta_template, concrete, generic.pos);
        }
        if (template_base == NODE_INTERFACE_DEF) {
            return register_generic_interface(ref c, meta_template, concrete, generic.pos);
        }

        return register_generic_struct(ref c, meta_template, concrete, generic.pos);
    }

    if (base == NODE_FUNCTION_TYPE) {
        let f_node: FunctionTypeNode = get_function_type_node(ref c.arena, node);
        let ret_id: Int = resolve_type(ref c, f_node.return_type);
        let arg_types: Vector(Struct) = [];
        let i: Int = 0;
        let p_len: Int = f_node.arg_types.length();
        while (i < p_len) {
            let arg_type: Int = resolve_type(ref c, f_node.arg_types[i]);
            if (f_node.variadic_param == i + 1 && arg_type != TYPE_POISON) {
                arg_type = get_slice_type_id(ref c, arg_type);
            }

            let pass_mode: Int = PARAM_VALUE;
            if (f_node.arg_modes is !null && i < f_node.arg_modes.length()) {
                pass_mode = f_node.arg_modes[i];
            }
            arg_types.append(TypeListNode(type=arg_type, pass_mode=pass_mode));
            i += 1;
        }
        return get_func_type_id(ref c, arg_types, ret_id, f_node.variadic_param, f_node.arg_names);
    }
    if (base == NODE_METHOD_TYPE) {
        let m_node: MethodTypeNode = get_method_type_node(ref c.arena, node);
        let ret_id: Int = resolve_type(ref c, m_node.return_type);
        let arg_types: Vector(Struct) = [];
        let i: Int = 0;
        let p_len: Int = m_node.arg_types.length();
        while (i < p_len) {
            let arg_type: Int = resolve_type(ref c, m_node.arg_types[i]);
            if (m_node.variadic_param == i + 1 && arg_type != TYPE_POISON) {
                arg_type = get_slice_type_id(ref c, arg_type);
            }

            let pass_mode: Int = PARAM_VALUE;
            if (m_node.arg_modes is !null && i < m_node.arg_modes.length()) {
                pass_mode = m_node.arg_modes[i];
            }
            arg_types.append(TypeListNode(type=arg_type, pass_mode=pass_mode));
            i += 1;
        }
        return get_method_type_id(ref c, arg_types, ret_id, m_node.variadic_param, m_node.arg_names);
    }
    if (base == NODE_FALLIBLE_TYPE) {
        let fll_node: FallibleTypeNode = get_fallible_type_node(ref c.arena, node);
        let base_id: Int = resolve_type(ref c, fll_node.base_type);
        if (is_fallible_type(ref c, base_id)) {
            throw_type_error(fll_node.pos, "Cannot create a nested fallible type (e.g. T??).");
        }
        return get_fallible_type_id(ref c, base_id);
    }

    // pointer type (ptr*N Type)
    if (base == NODE_PTR_TYPE) {
        let p_node: PointerTypeNode = get_pointer_type_node(ref c.arena, node);
        let base_id: Int = resolve_type(ref c, p_node.base_type);
        if (base_id == TYPE_POISON) { return TYPE_POISON; }

        if (base_id == TYPE_VOID) {
            throw_type_error(p_node.pos, "Cannot create a pointer to 'Void' (it has no size and no value), use 'AnyPtr' instead.");
            return TYPE_ANYPTR;
        }

        let current_id: Int = base_id;
        let i: Int = 0;
        while (i < p_node.level) {
            current_id = get_ptr_type_id(ref c, current_id);
            i += 1;
        }
        return current_id;
    }

    // vector
    if (base == NODE_VECTOR_TYPE) {
        let v_node: VectorTypeNode = get_vector_type_node(ref c.arena, node);
        let elem_id: Int = resolve_type(ref c, v_node.element_type);
        if (elem_id == TYPE_POISON) { return TYPE_POISON; }
        return get_vector_type_id(ref c, elem_id);
    }

    if (base == NODE_ARRAY_TYPE) {
        let arr_node: ArrayTypeNode = get_array_type_node(ref c.arena, node);
        let base_id: Int = resolve_type(ref c, arr_node.base_type);
        if (base_id == TYPE_POISON) { return TYPE_POISON; }

        let parsed_size: Long = string_to_long(arr_node.size_tok.value, arr_node.pos);
        if (parsed_size < 0L || parsed_size > 2147483647L) {
            throw_overflow_error(arr_node.pos, "Array size overflows maximum allowed 32-bit limit.");
            return 0;
        }

        let size: Int = string_to_int(arr_node.size_tok.value, arr_node.pos);

        let cache_key: String = "arr_" + base_id + "_" + size;
        let cached: Optional(SymbolInfo) = c.array_type_cache.lookup(cache_key);

        if ((cached is !null)) { return cached.type; }

        let new_id: Int = c.type_counter;
        c.type_counter += 1;

        c.array_type_cache.put(cache_key, SymbolInfo(reg="", type=new_id, origin_type=0, is_const=false, is_const_access=false, is_ref_param=false, is_reference=false, func_arg_types=[], arg_names=[], variadic_param=0));

        let llvm_name: String = "[" + size + " x " + get_llvm_type_str(ref c, base_id) + "]";
        c.array_info_map.put(new_id, ArrayInfo(base_type=base_id, size=size, llvm_name=llvm_name));

        return new_id;
    }

    if (base == NODE_SLICE_TYPE) {
        let s_node: SliceTypeNode = get_slice_type_node(ref c.arena, node);
        let elem_id: Int = resolve_type(ref c, s_node.element_type);
        if (elem_id == TYPE_POISON) { return TYPE_POISON; }
        return get_slice_type_id(ref c, elem_id);
    }

    // named type (Int, Float, StructName)
    if (base == NODE_VAR_ACCESS) {
        let v: VarAccessNode = get_var_access_node(ref c.arena, node);
        let name: String = v.name_tok.value;

        let generic_type: Optional(SymbolInfo) = c.generic_bindings.lookup(name);
        if ((generic_type is !null)) { return generic_type.type; }
        if (name == "Self") {
            throw_type_error(v.pos, "Self is only available in an interface method declaration.");
            return TYPE_POISON;
        }

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
        if (name == "Null") { return TYPE_NULL; }
        if (name == "Struct") { return TYPE_GENERIC_STRUCT; }
        if (name == "Function") { return TYPE_GENERIC_FUNCTION; }
        if (name == "Class") { return TYPE_GENERIC_CLASS; }
        if (name == "Method") { return TYPE_GENERIC_METHOD; }
        if (name == "Enum") { return TYPE_GENERIC_ENUM; }
        if (name == "Auto") { return TYPE_AUTO; }
        if (name == "AnyPtr") { return TYPE_ANYPTR; }

        let named_info: Optional(NamedTypeInfo) = c.named_types.lookup(c.current_package_prefix + name);
        if ((named_info is !null)) {
            return resolve_named_type(ref c, named_info);
        }

        let internal_info: Optional(StructInfo) = c.struct_table.lookup(c.current_package_prefix + name);
        if ((internal_info is !null)) { return internal_info.type_id; }

        let full_name: Optional(String) = c.current_file_type_aliases.lookup(name);
        if (full_name is !null) {
            named_info = c.named_types.lookup(full_name);
            if ((named_info is !null)) {
                return resolve_named_type(ref c, named_info);
            }
            let s_info: Optional(StructInfo) = c.struct_table.lookup(full_name);
            if ((s_info is !null)) { return s_info.type_id; }
        }

        let s_info: Optional(StructInfo) = c.struct_table.lookup(name);
        if ((s_info is !null)) { return s_info.type_id; }

        let local_alias: Optional(String) = c.current_file_type_aliases.lookup(name);
        if (local_alias is !null) {
            named_info = c.named_types.lookup(local_alias);
            if ((named_info is !null)) {
                return resolve_named_type(ref c, named_info);
            }
            let s_info: Optional(StructInfo) = c.struct_table.lookup(local_alias);
            if ((s_info is !null)) { return s_info.type_id; }
        }

        let g_alias: Optional(String) = c.global_type_aliases.lookup(name);
        if (g_alias is !null) {
            named_info = c.named_types.lookup(g_alias);
            if ((named_info is !null)) {
                return resolve_named_type(ref c, named_info);
            }
            let s_info: Optional(StructInfo) = c.struct_table.lookup(g_alias);
            if ((s_info is !null)) { return s_info.type_id; }
        }

        throw_type_error(v.pos, "Unknown type: " + name);
    }

    if (base == NODE_FIELD_ACCESS) {
        let f_acc: FieldAccessNode = get_field_access_node(ref c.arena, node);
        let path_parts: Vector(String) = [];
        let curr_obj: NodeID = f_acc.obj;
        let curr_base: Int = node_tag(curr_obj);
        while (curr_base == NODE_FIELD_ACCESS) {
            let inner_f: FieldAccessNode = get_field_access_node(ref c.arena, curr_obj);
            path_parts.append(inner_f.field_name);
            curr_obj = inner_f.obj;
            curr_base = node_tag(curr_obj);
        }
        if (curr_base == NODE_VAR_ACCESS) {
            let pkg_node: VarAccessNode = get_var_access_node(ref c.arena, curr_obj);
            let pkg_name: String = pkg_node.name_tok.value;
            let type_name: String = f_acc.field_name;
            if (type_name.starts_with("__")) {
                if (!c.is_precompile_phase) {
                    throw_type_error(f_acc.pos, "Unknown module type: " + pkg_name + "." + type_name);
                }
                return TYPE_POISON;
            }

            let full_name: String = "";
            let module_prefix: Optional(String) = c.current_file_visible_prefixes.lookup(pkg_name);
            if (module_prefix is !null) {
                full_name = module_member_name(module_prefix, path_parts, type_name);
            } else {
                let source_name: String = module_member_name(pkg_name + ".", path_parts, type_name);
                let mapped_type: Optional(String) = c.current_file_type_aliases.lookup(source_name);
                if (mapped_type is !null) { full_name = mapped_type; }
            }

            let s_info: Optional(StructInfo) = c.struct_table.lookup(full_name);
            if ((s_info is !null)) { return s_info.type_id; }

            let named_info: Optional(NamedTypeInfo) = c.named_types.lookup(full_name);
            if ((named_info is !null)) {
                return resolve_named_type(ref c, named_info);
            }

            let g_alias: Optional(String) = c.global_type_aliases.lookup(full_name);
            if (g_alias is !null) {
                named_info = c.named_types.lookup(g_alias);
                if ((named_info is !null)) {
                    return resolve_named_type(ref c, named_info);
                }
                let type_s_info: Optional(StructInfo) = c.struct_table.lookup(g_alias);
                if ((type_s_info is !null)) { return type_s_info.type_id; }
            }

            throw_type_error(f_acc.pos, "Unknown module type: " + full_name);
        }
    }

    return TYPE_POISON;
}

func get_func_sig_str(ref c: Compiler, info: FuncInfo) -> String {
    let ret_str: String = get_llvm_type_str(ref c, info.ret_type);
    let args_str: String = "";
    let arg_types: Vector(Struct) = info.arg_types;
    let len: Int = arg_types.length();
    let i: Int = 0;

    while (i < len) {
        let curr: TypeListNode = arg_types[i];
        if (i > 0) { args_str = args_str + ", "; }
        args_str += param_llvm_type(ref c, curr);
        i += 1;
    }

    if (info.is_varargs) {
        if (len > 0) { args_str = args_str + ", ..."; }
        else { args_str = "..."; }
    }

    return ret_str + " (" + args_str + ")*";
}

func get_method_def_sig_str(ref c: Compiler, m_node: MethodDefNode) -> String {
    let ret_type: Int = resolve_type(ref c, m_node.return_type);
    let ret_str: String = get_llvm_type_str(ref c, ret_type);
    let args_str: String = "i8*"; // Self pointer is always i8* for interfaces

    let params: Vector(ParamNode) = m_node.params;
    let len: Int = params.length();
    let i: Int = 0;

    while (i < len) {
        let p_node: ParamNode = params[i];
        let p_type: Int = callable_param_type(ref c, p_node);
        args_str = args_str + ", " + param_llvm_type(ref c, TypeListNode(type=p_type, pass_mode=p_node.pass_mode));
        i += 1;
    }

    return ret_str + " (" + args_str + ")*";
}

func runtime_type_name(ref c: Compiler, type_id: Int) -> String {
    let callable: Bool = c.func_ret_map.contains_key(type_id);
    if (!callable) {
        callable = (c.method_ret_map.lookup(type_id) is !null);
    }
    if callable {
        // callable labels belong to source binding, not runtime type identity
        return mangle_type(ref c, type_id);
    }
    return get_type_name(ref c, type_id);
}

func type_fingerprint(ref c: Compiler, type_id: Int) -> UInt64 {
/*
    fnv-1a over the canonical type name:

        hash := offset_basis
        for each byte:
            hash := hash xor byte
            hash := hash * prime
        return hash

    using the type name keeps erased tags independent of addresses and table order
    */
    let name: String = "whitelang:" + runtime_type_name(ref c, type_id);
    let hash: UInt64 = 14695981039346656037UL;
    let i: Int = 0;
    while (i < name.length()) {
        hash ^= UInt64(name[i]);
        hash *= 1099511628211UL;
        i++;
    }
    if (hash == UInt64(0)) {
        return UInt64(1);
    }
    return hash;
}

func variant_tag(ref c: Compiler, type_id: Int) -> UInt64 {
// zero belongs to the Null value, nullptr keeps its own pointer tag
    if (type_id == TYPE_NULL) {
        return UInt64(0);
    }
    return type_fingerprint(ref c, type_id);
}

func mangle_type(ref c: Compiler, type_id: Int) -> String {
    let named: Optional(NamedTypeInfo) = get_named_type(ref c, type_id);
    if ((named is !null)) {
        return "N" + named.name.length() + named.name;
    }
    let found_union: Optional(UnionInfo) = get_union_type(ref c, type_id);
    if (found_union is !null) {
        return found_union.key;
    }
    if (type_id == TYPE_NULL) { return "Dn"; }
    if (type_id == TYPE_VOID) { return "v"; }
    if (type_id == TYPE_BOOL) {
        return "b";
    }
    if (type_id == TYPE_INT8) {
        return "a";
    }
    if (type_id == TYPE_INT16) { return "s"; }
    if (type_id == TYPE_INT) {
        return "i";
    }
    if (type_id == TYPE_LONG) {
        return "x";
    }
    if (type_id == TYPE_INT128) { return "n"; }
    if (type_id == TYPE_BYTE) {
        return "h";
    }
    if (type_id == TYPE_UINT16) {
        return "t";
    }
    if (type_id == TYPE_UINT32) {
        return "j";
    }
    if (type_id == TYPE_UINT64) {
        return "y";
    }
    if (type_id == TYPE_UINT128) {
        return "o";
    }
    if (type_id == TYPE_FLOAT32) {
        return "f";
    }
    if (type_id == TYPE_FLOAT) {
        return "d";
    }
    if (type_id == TYPE_CHAR) {
        return "w";
    }
    if (type_id == TYPE_INTSIZE) {
        return "l";
    }
    if (type_id == TYPE_UINTSIZE) {
        return "m";
    }
    if (type_id == TYPE_STRING) { return "S"; }
    if (type_id == TYPE_ANYPTR) {
        return "Pv";
    }
    if (type_id == TYPE_ANY_ERROR) {
        return "E";
    }
    if (type_id == TYPE_GENERIC_STRUCT) { return "Gs"; }
    if (type_id == TYPE_GENERIC_CLASS) {
        return "Gc";
    }
    if (type_id == TYPE_GENERIC_FUNCTION) {
        return "Gf";
    }
    if (type_id == TYPE_GENERIC_METHOD) { return "Gm"; }
    if (type_id == TYPE_GENERIC_ENUM) {
        return "Ge";
    }

    let ptr_info: Optional(SymbolInfo) = c.ptr_base_map.lookup(type_id);
    if ((ptr_info is !null)) {
        return "P" + mangle_type(ref c, ptr_info.type);
    }

    let arr_info: Optional(ArrayInfo) = c.array_info_map.lookup(type_id);
    if ((arr_info is !null)) {
        if (arr_info.size == -1) {
            return "Q" + mangle_type(ref c, arr_info.base_type);
        }
        return "A" + arr_info.size + "_" + mangle_type(ref c, arr_info.base_type);
    }

    let vec_info: Optional(SymbolInfo) = c.vector_base_map.lookup(type_id);
    if ((vec_info is !null)) {
        return "V" + mangle_type(ref c, vec_info.type);
    }

    let fallible_info: Optional(SymbolInfo) = c.fallible_base_map.lookup(type_id);
    if ((fallible_info is !null)) {
        return "R" + mangle_type(ref c, fallible_info.type);
    }

    let func_info: Optional(SymbolInfo) = c.func_ret_map.lookup(type_id);
    if ((func_info is !null)) {
        let meta_func_info: SymbolInfo = func_info;
        let encoded: String = "F";
        let args: Vector(Struct) = meta_func_info.func_arg_types;
        let len: Int = args.length();
        let i: Int = 0;
        while (i < len) {
            let arg: TypeListNode = args[i];
            if (meta_func_info.variadic_param == i + 1) { encoded += "Z"; }
            if (arg.pass_mode == PARAM_REF) { encoded += "L"; }
            encoded += mangle_type(ref c, arg.type);
            i += 1;
        }
        return encoded + "E" + mangle_type(ref c, meta_func_info.type);
    }

    let method_info: Optional(SymbolInfo) = c.method_ret_map.lookup(type_id);
    if ((method_info is !null)) {
        let meta_method_info: SymbolInfo = method_info;
        let encoded: String = "M";
        let args: Vector(Struct) = meta_method_info.func_arg_types;
        let len: Int = args.length();
        let i: Int = 0;
        while (i < len) {
            let arg: TypeListNode = args[i];
            if (meta_method_info.variadic_param == i + 1) { encoded += "Z"; }
            if (arg.pass_mode == PARAM_REF) { encoded += "L"; }
            encoded += mangle_type(ref c, arg.type);
            i += 1;
        }
        return encoded + "E" + mangle_type(ref c, meta_method_info.type);
    }

    let struct_info: Optional(StructInfo) = c.struct_id_map.lookup(type_id);
    if ((struct_info is !null)) {
        return "N" + struct_info.name.length() + struct_info.name + "E";
    }

    throw_internal_compiler_error(no_position(), "Cannot mangle unknown type id " + type_id + ".");
    return "v";
}

func mangle_wl_name(ref c: Compiler, prefix: String, base_name: String, arg_types: Vector(Struct)) -> String {
    if (base_name == "main" && prefix == "") { return "main"; }

    let mangled: String = "_WL";

    if (prefix != "") {
        let clean_prefix: String = prefix.slice(0, prefix.length() - 1);
        mangled += "" + clean_prefix.length() + clean_prefix;
    }

    mangled += "" + base_name.length() + base_name;

    let len: Int = arg_types.length();
    if (len == 0) {
        return mangled + "v";
    }

    let i: Int = 0;
    while (i < len) {
        let t_node: TypeListNode = arg_types[i];
        if (t_node.type == TYPE_POISON) {
            throw_internal_compiler_error(no_position(), "Cannot mangle '" + prefix + base_name + "': parameter " + i + " has no resolved type.");
            return mangled + "v";
        }
        if (t_node.pass_mode == PARAM_REF) { mangled += "L"; }
        mangled += mangle_type(ref c, t_node.type);
        i += 1;
    }
    return mangled;
}

func get_mangled_symbol(ref c: Compiler, link_name: String, pos: Position) -> String {
    let func_key: Optional(String) = c.compiler_link.lookup(link_name);
    let name: Optional(String) = null;

    if (func_key is !null) {
        let f_info: Optional(FuncInfo) = c.func_table.lookup(func_key);
        if ((f_info is !null)) { name = f_info.name; }
    }

    if (name is null) {
        if (has_position(pos)) {
            throw_type_error(pos, "Missing CompilerLink hook '" + link_name + "'. Did you import 'builtin'?");
        }
        return "__wl_missing_hook";
    }

    return name;
}

func consume_annotations(ref c: Compiler, anns: Vector(AnnotationNode), default_name: String) -> SystemAnnResult {
    let res: SystemAnnResult = SystemAnnResult(ann_flags=0, compiler_link_name="", intrinsic_name="");
    let len: Int = anns.length();
    let i: Int = 0;
    while (i < len) {
        let ann_node: AnnotationNode = anns[i];
        let name: String = ann_node.name;

        if (name == "ExportLib") {
            if (ann_node.args.length() > 0) {
                throw_invalid_syntax(ann_node.pos, "@" + name + " annotation cannot have arguments.");
            }
            res.ann_flags = res.ann_flags | FLAG_ANN_EXPORT;
        } else if (name == "CompilerIntrinsic") {
            let arg_count: Int = ann_node.args.length();
            if (arg_count > 1) {
                throw_invalid_syntax(ann_node.pos, "@CompilerIntrinsic accepts at most one string literal argument.");
            } else if (arg_count == 1) {
                let a_node: ArgNode = ann_node.args[0];
                let base_val: Int = node_tag(a_node.val);
                if (base_val != NODE_STRING) {
                    throw_invalid_syntax(ann_node.pos, "@CompilerIntrinsic argument must be a string literal.");
                } else {
                    let str_node: StringNode = get_string_node(ref c.arena, a_node.val);
                    res.intrinsic_name = str_node.tok.value;
                }
            }
            res.ann_flags = res.ann_flags | FLAG_ANN_INTRINSIC;
        } else if (name == "CompilerLink") {
            let link_name: String = default_name;
            if (ann_node.args.length() > 0) {
                let a_node: ArgNode = ann_node.args[0];
                let base_val: Int = node_tag(a_node.val);
                if (base_val != NODE_STRING) {
                    throw_invalid_syntax(ann_node.pos, "@CompilerLink argument must be a string literal.");
                } else {
                    let str_node: StringNode = get_string_node(ref c.arena, a_node.val);
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

func string_to_int(val_str: String, pos: Position) -> Int {
    let len: Int = val_str.length();
    if (len == 0) { return 0; }
    let start: Int = 0;
    let is_neg: Bool = false;
    if (val_str[0] == '-') {
        start = 1;
        is_neg = true;
    }
    let end: Int = len;
    if (val_str.ends_with("ULL") || val_str.ends_with("ull")) {
        end = len - 3;
    } else if (val_str.ends_with("LL") || val_str.ends_with("ll") || val_str.ends_with("UL") || val_str.ends_with("ul")) {
        end = len - 2;
    } else {
        let last_char: Int = Int(val_str[len - 1]);
        if (last_char == 76 || last_char == 108 || last_char == 85 || last_char == 117) {
            end = len - 1;
        }
    }

    let base_val: Int = 10;
    if (end - start >= 2 && val_str[start] == '0') {
        let second_char: Int = Int(val_str[start + 1]);
        if (second_char == 120 || second_char == 88) {
            base_val = 16;
            start += 2;
        }
        else if (second_char == 98 || second_char == 66) {
            base_val = 2;
            start += 2;
        }
        else if (second_char == 111 || second_char == 79) {
            base_val = 8;
            start += 2;
        }
    }

    let val: Int = 0;
    let j: Int = start;
    while (j < end) {
        let code: Int = Int(val_str[j]);
        if (code == 95) {
            j += 1;
            continue;
        }
        let digit: Int = -1;
        if (code >= 48 && code <= 57) { digit = code - 48; }
        else if (code >= 97 && code <= 102) {
            digit = code - 87;
        }
        else if (code >= 65 && code <= 70) {
            digit = code - 55;
        }

        let is_valid: Bool = false;
        if (digit >= 0) {
            if (base_val == 10 && digit < 10) { is_valid = true; }
            else if (base_val == 16 && digit < 16) {
                is_valid = true;
            }
            else if (base_val == 2 && digit < 2) {
                is_valid = true;
            }
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
    if is_neg {
        return 0 - val;
    }
    return val;
}

func exceeds_64bit_range(val_str: String) -> Bool {
    let len: Int = val_str.length();
    if (len == 0) { return false; }
    let start: Int = 0;
    if (val_str[0] == '-') { // '-'
        start = 1;
    }
    let end: Int = len;
    if (val_str.ends_with("ULL") || val_str.ends_with("ull")) {
        end = len - 3;
    } else if (val_str.ends_with("LL") || val_str.ends_with("ll") || val_str.ends_with("UL") || val_str.ends_with("ul")) {
        end = len - 2;
    } else {
        let last_char: Int = Int(val_str[len - 1]);
        if (last_char == 76 || last_char == 108 || last_char == 85 || last_char == 117) {
            end = len - 1;
        }
    }

    // check hex/bin/octal
    if (end - start >= 2 && val_str[start] == '0') {
        let second_char: Char = val_str[start + 1];
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

    let digit_count: Int = 0;
    let i: Int = start;
    while (i < end) {
        if (val_str[i] != '_') { // ignore '_'
            digit_count += 1;
        }
        i += 1;
    }

    if (digit_count > 19) { return true; }
    if (digit_count < 19) { return false; }

    // exact 19 digits, compare string
    let max_str: String = "9223372036854775807"; // 19 digits
    if (val_str[0] == '-') { max_str = "9223372036854775808"; }

    let max_idx: Int = 0;
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

func string_to_long(val_str: String, pos: Position) -> Long {
    let len: Int = val_str.length();
    if (len == 0) { return 0L; }

    let start: Int = 0;
    let is_neg: Bool = false;

    if (val_str[0] == '-') {
        start = 1;
        is_neg = true;
    }

    let end: Int = len;
    if (val_str.ends_with("ULL") || val_str.ends_with("ull")) {
        end = len - 3;
    } else if (val_str.ends_with("LL") || val_str.ends_with("ll") || val_str.ends_with("UL") || val_str.ends_with("ul")) {
        end = len - 2;
    } else {
        let last_char: Char = val_str[len - 1];
        if (last_char == 'L' || last_char == 'l' || last_char == 'U' || last_char == 'u') {
            end = len - 1;
        }
    }

    let base_val: Long = 10L;
    if (end - start >= 2 && val_str[start] == '0') {
        let second_char: Char = val_str[start + 1];
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

    let val: Long = 0L;
    let j: Int = start;
    while (j < end) {
        let code: Char = val_str[j];
        if (code == '_') {
            j += 1;
            continue;
        }

        let digit: Long = -1L;
        if (code >= '0' && code <= '9') { digit = Int(code) - Int('0'); }
        else if (code >= 'a' && code <= 'f') {
            digit = Int(code) - Int('a') + 10;
        }
        else if (code >= 'A' && code <= 'F') {
            digit = Int(code) - Int('A') + 10;
        }

        let is_valid: Bool = false;
        if (digit >= 0L) {
            if (base_val == 10L && digit < 10L) { is_valid = true; }
            else if (base_val == 16L && digit < 16L) {
                is_valid = true;
            }
            else if (base_val == 2L && digit < 2L) {
                is_valid = true;
            }
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

    if is_neg {
        return 0L - val;
    }
    return val;
}

// file & text utils
func string_escape(s: String) -> String {
    let res: String = "";
    let i: Int = 0;
    let len: Int = s.length();

    while (i < len) {
        let code: Char = s[i];

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

func file_exists(path: String) -> Bool {
    return file.exists(path);
}

func get_dir_name(path: String) -> String {
    let len: Int = path.length();
    let i: Int = len - 1;
    while (i >= 0) {
        let c: Char = path[i];
        if (c == '/' || c == '\\') {
            return path.slice(0, i);
        }
        i -= 1;
    }
    return ".";
}

func to_normpath(path: String) -> String {
    let len: Int = path.length();
    let parts: Vector(String) = [];
    let i: Int = 0;
    let start_idx: Int = 0;

    while (i <= len) {
        let c: Char = ' ';
        if (i < len) { c = path[i]; }
        if (c == '/' || c == '\\' || i == len) {
            if (i > start_idx) {
                parts.append(path.slice(start_idx, i));
            }
            start_idx = i + 1;
        }
        i += 1;
    }

    let norm_parts: Vector(String) = [];
    let num_parts: Int = parts.length();
    let j: Int = 0;

    while (j < num_parts) {
        let p: String = parts[j];
        if (p == ".") {
            // ignore
        } else if (p == "..") {
            let cur_len: Int = norm_parts.length();
            if (cur_len > 0 && norm_parts[cur_len - 1] != "..") {
                let temp: Vector(String) = [];
                let k: Int = 0;
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

    let res: String = "";
    if (len > 0) {
        let first_char: Char = path[0];
        if (first_char == '/' || first_char == '\\') { res = "/"; }
    }

    let norm_len: Int = norm_parts.length();
    let k: Int = 0;
    while (k < norm_len) {
        res += norm_parts[k];
        if (k < norm_len - 1) { res += "/"; }
        k += 1;
    }

    if (res == "") {
        return ".";
    }
    return res;
}

func import_security_path(path: String) -> String {
    let result: String = "";
    let i: Int = 0;
    while (i < path.length()) {
        let ch: Char = path[i];
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

func resolve_import_path(ref c: Compiler, raw_path: String, pos: Position) -> String {
    if (raw_path.ends_with(".wl")) {
        let final_path: String = "";
        if (c.current_dir == ".") {
            final_path = to_normpath(raw_path);
        } else {
            final_path = to_normpath(c.current_dir + "/" + raw_path);
        }

        let active_wl_path: Optional(String) = sys.env.get_env("WL_PATH");
        if (active_wl_path is !null) {
            let std_root: String = import_security_path(to_normpath(active_wl_path + "/std"));
            let internal_root: String = std_root + "/internal";
            let importer: String = import_security_path(to_normpath(c.current_dir));
            let checked_final_path: String = import_security_path(final_path);
            let targets_internal: Bool = checked_final_path == internal_root || checked_final_path.starts_with(internal_root + "/");
            let importer_is_std: Bool = importer == std_root || importer.starts_with(std_root + "/");
            if (targets_internal && !importer_is_std) {
                throw_import_error(pos, "Module '" + raw_path + "' is internal to the standard library.");
                return "";
            }
        }
        return final_path;
    }

    let wl_path: Optional(String) = sys.env.get_env("WL_PATH");
    if (wl_path is null) {
        throw_environment_error("Missing 'WL_PATH' variable.");
        return "";
    }

    let std_root: String = import_security_path(to_normpath(wl_path + "/std"));
    let importer: String = import_security_path(to_normpath(c.current_dir));
    let importer_is_std: Bool = importer == std_root || importer.starts_with(std_root + "/");
    let checked_raw_path: String = import_security_path(raw_path);
    if ((checked_raw_path == "internal" || checked_raw_path.starts_with("internal/")) && !importer_is_std) {
        throw_import_error(pos, "Module '" + raw_path + "' is internal to the standard library.");
        return "";
    }

    let pkg_entry: String = wl_path + "/std/" + raw_path + "/_pkg.wl";
    if (file_exists(pkg_entry)) {
        return to_normpath(pkg_entry);
    }

    let file_entry: String = wl_path + "/std/" + raw_path + ".wl";
    if (file_exists(file_entry)) {
        return to_normpath(file_entry);
    }

    throw_import_error(pos, "Cannot find module '" + raw_path + "'. Searched:\n - " + pkg_entry + "\n - " + file_entry);
    return "";
}

// closure analysis utils
func record_capture(scope: CaptureScope, v_name: String) -> Void {
    if (!scope.local_vars.contains_key(v_name)) {
        if (!scope.captured_vars.contains_key(v_name)) {
            scope.captured_vars.put(v_name, true);
            scope.captured_list.append(v_name);
        }
    }
}

func analyze_captures(arena: AstArena, node: NodeID, scope: CaptureScope) -> Void {
    if (!has_node(node)) {
        return;
    }
    let base: Int = node_tag(node);
    let type: Int = base;

    if (type == NODE_BLOCK) {
        let b: BlockNode = get_block_node(ref arena, node);
        let stmts: Vector(NodeID) = b.stmts;
        let i: Int = 0;
        let len: Int = stmts.length();
        while (i < len) {
            analyze_captures(arena, stmts[i], scope);
            i += 1;
        }
    }
    else if (type == NODE_VAR_DECL) {
        let decl: VarDeclareNode = get_var_decl_node(ref arena, node);
        scope.local_vars.put(decl.name_tok.value, true);
        if (has_node(decl.value)) {
            analyze_captures(arena, decl.value, scope);
        }
    }
    else if (type == NODE_VAR_ACCESS) {
        let acc: VarAccessNode = get_var_access_node(ref arena, node);
        record_capture(scope, acc.name_tok.value);
    }
    else if (type == NODE_VAR_ASSIGN) {
        let assign: VarAssignNode = get_var_assign_node(ref arena, node);
        record_capture(scope, assign.name_tok.value);
        if (has_node(assign.value)) {
            analyze_captures(arena, assign.value, scope);
        }
    }
    else if (type == NODE_BINOP || type == NODE_IS || type == NODE_IS_NOT) {
        let binop: BinOpNode = get_binop_node(ref arena, node);
        analyze_captures(arena, binop.left, scope);
        analyze_captures(arena, binop.right, scope);
    }
    else if (type == NODE_UNARYOP) {
        let uop: UnaryOpNode = get_unary_node(ref arena, node);
        analyze_captures(arena, uop.node, scope);
    }
    else if (type == NODE_POSTFIX) {
        let pop: PostfixOpNode = get_postfix_node(ref arena, node);
        analyze_captures(arena, pop.node, scope);
    }
    else if (type == NODE_IF) {
        let if_n: IfNode = get_if_node(ref arena, node);
        analyze_captures(arena, if_n.condition, scope);
        analyze_captures(arena, if_n.body, scope);
        analyze_captures(arena, if_n.else_body, scope);
    }
    else if (type == NODE_WHILE) {
        let w_n: WhileNode = get_while_node(ref arena, node);
        analyze_captures(arena, w_n.condition, scope);
        analyze_captures(arena, w_n.body, scope);
    }
    else if (type == NODE_FOR) {
        let f_n: ForNode = get_for_node(ref arena, node);
        analyze_captures(arena, f_n.init, scope);
        analyze_captures(arena, f_n.cond, scope);
        analyze_captures(arena, f_n.step, scope);
        analyze_captures(arena, f_n.body, scope);
    }
    else if (type == NODE_CALL) {
        let call: CallNode = get_call_node(ref arena, node);
        analyze_captures(arena, call.callee, scope);
        let args: Vector(ArgNode) = call.args;
        let i: Int = 0;
        let len: Int = args.length();
        while (i < len) {
            let arg: ArgNode = args[i];
            analyze_captures(arena, arg.val, scope);
            i += 1;
        }
    }
    else if (type == NODE_RETURN) {
        let ret: ReturnNode = get_return_node(ref arena, node);
        analyze_captures(arena, ret.value, scope);
    }
    else if (type == NODE_FIELD_ACCESS) {
        let fa: FieldAccessNode = get_field_access_node(ref arena, node);
        analyze_captures(arena, fa.obj, scope);
    }
    else if (type == NODE_FIELD_ASSIGN) {
        let fass: FieldAssignNode = get_field_assign_node(ref arena, node);
        analyze_captures(arena, fass.obj, scope);
        analyze_captures(arena, fass.value, scope);
    }
    else if (type == NODE_INDEX_ACCESS) {
        let ia: IndexAccessNode = get_index_access_node(ref arena, node);
        analyze_captures(arena, ia.target, scope);
        analyze_captures(arena, ia.index_node, scope);
    }
    else if (type == NODE_INDEX_ASSIGN) {
        let iass: IndexAssignNode = get_index_assign_node(ref arena, node);
        analyze_captures(arena, iass.target, scope);
        analyze_captures(arena, iass.index_node, scope);
        analyze_captures(arena, iass.value, scope);
    }
    else if (type == NODE_VECTOR_LIT) {
        let vec: VectorLitNode = get_vector_lit_node(ref arena, node);
        let elems: Vector(ArgNode) = vec.elements;
        let i: Int = 0;
        let len: Int = elems.length();
        while (i < len) {
            let arg: ArgNode = elems[i];
            analyze_captures(arena, arg.val, scope);
            i += 1;
        }
    }
    else if (type == NODE_REF) {
        let ref_n: RefNode = get_ref_node(ref arena, node);
        analyze_captures(arena, ref_n.node, scope);
    }
    else if (type == NODE_DEREF) {
        let deref_n: DerefNode = get_deref_node(ref arena, node);
        analyze_captures(arena, deref_n.node, scope);
    }
    else if (type == NODE_PTR_ASSIGN) {
        let pass: PtrAssignNode = get_ptr_assign_node(ref arena, node);
        analyze_captures(arena, pass.pointer, scope);
        analyze_captures(arena, pass.value, scope);
    }
    else if (type == NODE_FUNC_DEF) {
        let func_def: FunctionDefNode = get_func_def_node(ref arena, node);
        scope.local_vars.put(func_def.name_tok.value, true);

        let child_scope: CaptureScope = CaptureScope(local_vars=Dict(), captured_vars=Dict(), captured_list=[]);

        let params: Vector(ParamNode) = func_def.params;
        let i: Int = 0;
        let len: Int = params.length();
        while (i < len) {
            let p_node: ParamNode = params[i];
            child_scope.local_vars.put(p_node.name_tok.value, true);
            i += 1;
        }

        analyze_captures(arena, func_def.body, child_scope);
        let k_i: Int = 0;
        let k_len: Int = child_scope.captured_list.length();
        while (k_i < k_len) {
            let k_str: String = child_scope.captured_list[k_i];
            record_capture(scope, k_str);
            k_i += 1;
        }
    }
}

// vector util
func check_out_index(ref c: Compiler, target_node: NodeID, index_node: NodeID, pos: Position) -> Void {
    let base_idx: Int = node_tag(index_node);
    if (base_idx == NODE_INT) {
        let i_node: IntNode = get_int_node(ref c.arena, index_node);
        let val_str: String = i_node.tok.value;
        let idx_val: Long = string_to_long(i_node.tok.value, i_node.pos);

        if (idx_val < 0) {
            throw_index_error(pos, "Negative index " + val_str + " is not supported yet.");
        }

        let base_target: Int = node_tag(target_node);
        if (base_target == NODE_VECTOR_LIT) {
            let vec_node: VectorLitNode = get_vector_lit_node(ref c.arena, target_node);
            let count: Int = vec_node.count;

            if (idx_val >= count) {
                throw_index_error(pos, "Index " + val_str + " is out of bounds for vector of size " + count + ".");
            }
        }

        if (base_target == NODE_STRING) {
            let str_node: StringNode = get_string_node(ref c.arena, target_node);
            let s_len: Int = str_node.tok.value.length();

            if (idx_val >= s_len) {
                throw_index_error(pos, "Index " + val_str + " is out of bounds for string of length " + s_len + ".");
            }
        }
    }
}

// oop
func is_subclass(ref c: Compiler, child_id: Int, parent_id: Int) -> Bool {
    if (child_id == parent_id) { return true; }
    let s_info: Optional(StructInfo) = c.struct_id_map.lookup(child_id);
    if (!(s_info is !null)) { return false; }
    let meta_s_info: StructInfo = s_info;
    if (parent_id == TYPE_GENERIC_ENUM && meta_s_info.is_enum) { return true; }
    let curr_parent: Int = meta_s_info.parent_id;
    while (curr_parent != 0) {
        if (curr_parent == parent_id) { return true; }
        let p_info: Optional(StructInfo) = c.struct_id_map.lookup(curr_parent);
        if (!(p_info is !null)) { return false; }
        curr_parent = p_info.parent_id;
    }
    return false;
}
