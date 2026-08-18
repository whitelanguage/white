// compiler/target_eval.wl
import "sys"
import * from "../frontend/ast.wl"
import * from "context.wl"
import * from "../frontend/tokens.wl"
import * from "target.wl"

func target_intrinsic(c: Compiler, node: Struct) -> String {
    if (node is null) { return ""; }
    let base: Int = node_kind(node);
    let info: SymbolInfo = null;
    if (base == NODE_FIELD_ACCESS) {
        let name: String = format_ast_path(node);
        let mapped: String = c.current_file_global_aliases.lookup(name);
        if (mapped is null) { mapped = c.global_var_aliases.lookup(name); }
        if (mapped is !null) { info = c.global_symbol_table.lookup(mapped); }
        if (info is null) { info = c.global_symbol_table.lookup(name); }
    } else if (base == NODE_VAR_ACCESS) {
        let access: VarAccessNode = node;
        info = find_symbol(c, access.name_tok.value);
    }
    if (info is null || !info.reg.starts_with("$intrinsic.")) { return ""; }
    return info.reg.slice(11, info.reg.length());
}

func target_value(name: String) -> Int {
    if (name == "target_os") { return Int(get_target_os()); }
    if (name == "target_arch") { return Int(get_target_arch()); }
    if (name == "target_abi") { return Int(get_target_abi()); }
    if (name == "target_binary_format") { return Int(get_target_binary_format()); }
    if (name == "target_pointer_bits") { return get_target_pointer_bits(); }
    return -1;
}

func target_member(name: String, member: String) -> Int {
    if (name == "target_os") {
        if (member == "Windows") { return Int(sys.Os.Windows); }
        if (member == "Linux") { return Int(sys.Os.Linux); }
        if (member == "MacOS") { return Int(sys.Os.MacOS); }
        if (member == "Unknown") { return Int(sys.Os.Unknown); }
    } else if (name == "target_arch") {
        if (member == "X86") { return Int(sys.Arch.X86); }
        if (member == "X86_64") { return Int(sys.Arch.X86_64); }
        if (member == "Arm") { return Int(sys.Arch.Arm); }
        if (member == "AArch64") { return Int(sys.Arch.AArch64); }
        if (member == "Unknown") { return Int(sys.Arch.Unknown); }
    } else if (name == "target_abi") {
        if (member == "Msvc") { return Int(sys.Abi.Msvc); }
        if (member == "Gnu") { return Int(sys.Abi.Gnu); }
        if (member == "None") { return Int(sys.Abi.None); }
        if (member == "Unknown") { return Int(sys.Abi.Unknown); }
    } else if (name == "target_binary_format") {
        if (member == "Coff") { return Int(sys.BinaryFormat.Coff); }
        if (member == "Elf") { return Int(sys.BinaryFormat.Elf); }
        if (member == "MachO") { return Int(sys.BinaryFormat.MachO); }
        if (member == "Unknown") { return Int(sys.BinaryFormat.Unknown); }
    }
    return -1;
}

func target_enum_name(name: String) -> String {
    if (name == "target_os") { return "Os"; }
    if (name == "target_arch") { return "Arch"; }
    if (name == "target_abi") { return "Abi"; }
    if (name == "target_binary_format") { return "BinaryFormat"; }
    return "";
}

func fold_target_cond(c: Compiler, node: Struct) -> Int {
// return 1 or 0 for a known target condition, and -1 when runtime code is still needed
    if (node is null) { return -1; }
    let base: Int = node_kind(node);

    if (base == NODE_UNARYOP) {
        let unary: UnaryOpNode = node;
        if (unary.op_tok.value == "!") {
            let value: Int = fold_target_cond(c, unary.node);
            if (value == 0) { return 1; }
            if (value == 1) { return 0; }
        }
        return -1;
    }

    if (base != NODE_BINOP) { return -1; }
    let binary: BinOpNode = node;
    let op: String = binary.op_tok.value;

    if (op == "&&" || op == "||") {
        let left_value: Int = fold_target_cond(c, binary.left);
        let right_value: Int = fold_target_cond(c, binary.right);
        if (left_value == -1 || right_value == -1) { return -1; }
        if (op == "&&") {
            if (left_value == 1 && right_value == 1) { return 1; }
            return 0;
        }
        if (left_value == 1 || right_value == 1) { return 1; }
        return 0;
    }

    if (op != "==" && op != "!=") { return -1; }

    let intrinsic_node: Struct = binary.left;
    let intrinsic: String = target_intrinsic(c, intrinsic_node);
    let literal_node: Struct = binary.right;
    if (intrinsic.length() == 0) {
        intrinsic_node = binary.right;
        intrinsic = target_intrinsic(c, intrinsic_node);
        literal_node = binary.left;
    }
    if (intrinsic.length() == 0) { return -1; }

    let literal_base: Int = node_kind(literal_node);
    let equal: Bool = false;
    if (intrinsic == "target_pointer_bits" && literal_base != 0 && literal_base == NODE_INT) {
        let literal: IntNode = literal_node;
        equal = get_target_pointer_bits() == string_to_int(literal.tok.value, literal.pos);
    } else if (literal_base != 0 && literal_base == NODE_FIELD_ACCESS) {
        let field: FieldAccessNode = literal_node;
        let enum_name: String = target_enum_name(intrinsic);
        let field_path: String = format_ast_path(literal_node);
        if (!field_path.ends_with(enum_name + "." + field.field_name)) { return -1; }
        let expected: Int = target_member(intrinsic, field.field_name);
        if (expected < 0) { return -1; }
        equal = target_value(intrinsic) == expected;
    } else {
        return -1;
    }

    if (op == "==") {
        if equal { return 1; }
        return 0;
    }
    if equal { return 0; }
    return 1;
}


func emit_target_intrinsic(c: Compiler, info: SymbolInfo) -> CompileResult {
    let name: String = info.reg.slice(11, info.reg.length());
    return CompileResult(reg="" + target_value(name), type=info.type, origin_type=info.type);
}

