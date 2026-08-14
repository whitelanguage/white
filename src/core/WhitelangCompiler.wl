// core/WhitelangCompiler.wl
import "sys"
import "file"
import "process"
import Dict from "dict"

import * from "WhitelangNodes.wl"
import * from "WhitelangUtils.wl"
import * from "WhitelangTokens.wl"
import * from "WhitelangExceptions.wl"
import * from "WhitelangTarget.wl"
import Lexer, new_lexer, get_next_token from "WhitelangLexer.wl"
import Parser, parse from "WhitelangParser.wl"


func type_fingerprint(c -> Compiler, type_id -> Int) -> UInt64 {
    let name -> String = "whitelang:" + get_type_name(c, type_id);
    let hash -> UInt64 = 14695981039346656037UL;
    let i -> Int = 0;
    while (i < name.length()) {
        hash ^= UInt64(name[i]);
        hash *= 1099511628211UL;
        i += 1;
    }
    if (hash == UInt64(0)) { return UInt64(1); }
    return hash;
}

func is_dict_key_type(c -> Compiler, type_id -> Int) -> Bool {
    if (type_id == TYPE_NULL || type_id == TYPE_NULLPTR || type_id == TYPE_ANYPTR || type_id == TYPE_STRING) { return true; }
    if (is_primitive_type(type_id)) { return type_id != TYPE_ANY_ERROR; }
    if (is_pointer_type(c, type_id)) { return true; }

    let info -> StructInfo = c.struct_id_map.get("" + type_id);
    if (info is !null) {
        if (info.is_enum || info.is_interface) { return true; }
        if (info.is_class) { return info.name != "dict.Dict" && info.name != "Dict" && !info.name.starts_with("dict.Dict$") && !info.name.starts_with("Dict$"); }
        return false;
    }
    if (c.func_ret_map.get("" + type_id) is !null || c.method_ret_map.get("" + type_id) is !null) { return true; }
    return false;
}

func is_dynamic_dict(info -> StructInfo) -> Bool {
    return info is !null && (info.name == "dict.Dict" || info.name == "Dict");
}

func is_typed_dict(c -> Compiler, info -> StructInfo) -> Bool {
    if (info is null) { return false; }

    let template -> GenericTemplate = c.generic_instance_templates.get("" + info.type_id);
    return template is !null && (template.name == "Dict" || template.name.ends_with(".Dict"));
}

func is_generic_class(c -> Compiler, info -> StructInfo) -> Bool {
    if (info is null) { return false; }

    let template -> GenericTemplate = c.generic_instance_templates.get("" + info.type_id);
    if (template is null || template.node is null) { return false; }

    let base -> BaseNode = template.node;
    return base.type == NODE_CLASS_DEF;
}

func is_dict_key_method(name -> String) -> Bool {
    return name == "put" || name == "get" || name == "remove" || name == "contains_key";
}

func append_dict_key_case(c -> Compiler, cases -> String, seen -> Dict, type_id -> Int, label -> String) -> String {
    let fingerprint -> UInt64 = type_fingerprint(c, type_id);
    let key -> String = "" + fingerprint;
    let previous -> StringConstant = seen.get(key);
    let type_name -> String = get_type_name(c, type_id);
    if (previous is !null && previous.value != type_name) {
        throw_internal_compiler_error(null, "Dict key fingerprint collision between " + previous.value + " and " + type_name);
        return cases;
    }
    if (previous is !null) { return cases; }
    seen.put(key, StringConstant(id=0, value=type_name));
    return cases + "    i64 " + fingerprint + ", label " + label + "\n";
}

func append_variant_ref_case(c -> Compiler, cases -> String, seen -> Dict, type_id -> Int) -> String {
    let fingerprint -> UInt64 = type_fingerprint(c, type_id);
    let key -> String = "" + fingerprint;
    let previous -> StringConstant = seen.get(key);
    let type_name -> String = get_type_name(c, type_id);
    if (previous is !null && previous.value != type_name) {
        throw_internal_compiler_error(null, "Variant fingerprint collision between " + previous.value + " and " + type_name);
        return cases;
    }
    if (previous is !null) { return cases; }
    seen.put(key, StringConstant(id=0, value=type_name));
    return cases + "    i64 " + fingerprint + ", label %release\n";
}

func emit_error_value(c -> Compiler, value -> CompileResult, pos -> Position) -> CompileResult {
    // attach a stable error-domain id to a concrete error enum value
    if (value.type == TYPE_ANY_ERROR) { return value; }

    let error_type -> Int = value.type;
    if (!is_error_type(c, error_type) && is_error_type(c, value.origin_type)) {
        error_type = value.origin_type;
    }
    if (!is_error_type(c, error_type)) {
        throw_type_error(pos, "Cannot use " + get_type_name(c, value.type) + " as an error");
        return void_result();
    }

    let with_domain -> String = next_reg(c);
    c.output_file.write(c.indent + with_domain + " = insertvalue { i64, i32 } undef, i64 " + type_fingerprint(c, error_type) + ", 0\n");
    let result -> String = next_reg(c);
    c.output_file.write(c.indent + result + " = insertvalue { i64, i32 } " + with_domain + ", i32 " + value.reg + ", 1\n");
    return CompileResult(reg=result, type=TYPE_ANY_ERROR);
}
func target_intrinsic(c -> Compiler, node -> Struct) -> String {
    if (node is null) { return ""; }
    let base -> BaseNode = node;
    let info -> SymbolInfo = null;
    if (base.type == NODE_FIELD_ACCESS) {
        let name -> String = format_ast_path(node);
        let mapped -> String = c.current_file_global_aliases.get(name);
        if (mapped is null) { mapped = c.global_var_aliases.get(name); }
        if (mapped is !null) { info = c.global_symbol_table.get(mapped); }
        if (info is null) { info = c.global_symbol_table.get(name); }
    } else if (base.type == NODE_VAR_ACCESS) {
        let access -> VarAccessNode = node;
        info = find_symbol(c, access.name_tok.value);
    }
    if (info is null || !info.reg.starts_with("$intrinsic.")) { return ""; }
    return info.reg.slice(11, info.reg.length());
}

func target_value(name -> String) -> Int {
    if (name == "target_os") { return Int(get_target_os()); }
    if (name == "target_arch") { return Int(get_target_arch()); }
    if (name == "target_abi") { return Int(get_target_abi()); }
    if (name == "target_binary_format") { return Int(get_target_binary_format()); }
    if (name == "target_pointer_bits") { return get_target_pointer_bits(); }
    return -1;
}

func target_member(name -> String, member -> String) -> Int {
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

func target_enum_name(name -> String) -> String {
    if (name == "target_os") { return "Os"; }
    if (name == "target_arch") { return "Arch"; }
    if (name == "target_abi") { return "Abi"; }
    if (name == "target_binary_format") { return "BinaryFormat"; }
    return "";
}

func fold_target_cond(c -> Compiler, node -> Struct) -> Int {
// return -1 when the condition cannot be folded for this target
    if (node is null) { return -1; }
    let base -> BaseNode = node;

    if (base.type == NODE_UNARYOP) {
        let unary -> UnaryOpNode = node;
        if (unary.op_tok.value == "!") {
            let value -> Int = fold_target_cond(c, unary.node);
            if (value == 0) { return 1; }
            if (value == 1) { return 0; }
        }
        return -1;
    }

    if (base.type != NODE_BINOP) { return -1; }
    let binary -> BinOpNode = node;
    let op -> String = binary.op_tok.value;

    if (op == "&&" || op == "||") {
        let left_value -> Int = fold_target_cond(c, binary.left);
        let right_value -> Int = fold_target_cond(c, binary.right);
        if (left_value == -1 || right_value == -1) { return -1; }
        if (op == "&&") {
            if (left_value == 1 && right_value == 1) { return 1; }
            return 0;
        }
        if (left_value == 1 || right_value == 1) { return 1; }
        return 0;
    }

    if (op != "==" && op != "!=") { return -1; }

    let intrinsic_node -> Struct = binary.left;
    let intrinsic -> String = target_intrinsic(c, intrinsic_node);
    let literal_node -> Struct = binary.right;
    if (intrinsic.length() == 0) {
        intrinsic_node = binary.right;
        intrinsic = target_intrinsic(c, intrinsic_node);
        literal_node = binary.left;
    }
    if (intrinsic.length() == 0) { return -1; }

    let literal_base -> BaseNode = literal_node;
    let equal -> Bool = false;
    if (intrinsic == "target_pointer_bits" && literal_base is !null && literal_base.type == NODE_INT) {
        let literal -> IntNode = literal_node;
        equal = get_target_pointer_bits() == string_to_int(literal.tok.value, literal.pos);
    } else if (literal_base is !null && literal_base.type == NODE_FIELD_ACCESS) {
        let field -> FieldAccessNode = literal_node;
        let enum_name -> String = target_enum_name(intrinsic);
        let field_path -> String = format_ast_path(literal_node);
        if (!field_path.ends_with(enum_name + "." + field.field_name)) { return -1; }
        let expected -> Int = target_member(intrinsic, field.field_name);
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


func promote_to_float(c -> Compiler, res -> CompileResult) -> CompileResult {
    if (res.type == TYPE_FLOAT) { return res; }
    let input_reg -> String = res.reg;

    if (res.type == TYPE_FLOAT32) {
        let fpext_reg -> String = next_reg(c);
        c.output_file.write(c.indent + fpext_reg + " = fpext float " + input_reg + " to double\n");
        return CompileResult(reg=fpext_reg, type=TYPE_FLOAT);
    }

    if (res.type == TYPE_BOOL) {
        let zext_reg -> String = next_reg(c);
        c.output_file.write(c.indent + zext_reg + " = zext i1 " + input_reg + " to i32\n");
        let uitofp_reg -> String = next_reg(c);
        c.output_file.write(c.indent + uitofp_reg + " = uitofp i32 " + zext_reg + " to double\n");
        return CompileResult(reg=uitofp_reg, type=TYPE_FLOAT);
    }

    let ty_str -> String = get_llvm_type_str(c, res.type);
    let fp_reg -> String = next_reg(c);

    if (is_signed_integer(res.type)) {
        c.output_file.write(c.indent + fp_reg + " = sitofp " + ty_str + " " + input_reg + " to double\n");
        return CompileResult(reg=fp_reg, type=TYPE_FLOAT);
    }

    if (is_unsigned_integer(res.type)) {
        c.output_file.write(c.indent + fp_reg + " = uitofp " + ty_str + " " + input_reg + " to double\n");
        return CompileResult(reg=fp_reg, type=TYPE_FLOAT);
    }

    return res;
}
func promote_to_long(c -> Compiler, res -> CompileResult) -> CompileResult {
    let ty_str -> String = get_llvm_type_str(c, res.type);
    
    if (ty_str == "i64" || ty_str == "i128" || ty_str == "double" || ty_str == "float" || res.type >= 100) { 
        return res; 
    }
    
    let input_reg -> String = res.reg;
    let ext_reg -> String = next_reg(c);

    if (res.type == TYPE_BOOL) {
        c.output_file.write(c.indent + ext_reg + " = zext i1 " + input_reg + " to i64\n");
        return CompileResult(reg=ext_reg, type=TYPE_LONG);
    }

    if (is_signed_integer(res.type)) {
        c.output_file.write(c.indent + ext_reg + " = sext " + ty_str + " " + input_reg + " to i64\n");
        return CompileResult(reg=ext_reg, type=TYPE_LONG);
    }
    
    if (is_unsigned_integer(res.type)) {
        c.output_file.write(c.indent + ext_reg + " = zext " + ty_str + " " + input_reg + " to i64\n");
        return CompileResult(reg=ext_reg, type=TYPE_LONG);
    }
    
    return res;
}
func promote_to_int(c -> Compiler, res -> CompileResult) -> CompileResult {
    let ty_str -> String = get_llvm_type_str(c, res.type);

    if (ty_str == "i32" || ty_str == "i64" || ty_str == "i128" || ty_str == "double" || ty_str == "float" || res.type == TYPE_BOOL || res.type >= 100) { 
        return res; 
    }
    
    let input_reg -> String = res.reg;
    let ext_reg -> String = next_reg(c);

    if (is_signed_integer(res.type)) {
        c.output_file.write(c.indent + ext_reg + " = sext " + ty_str + " " + input_reg + " to i32\n");
    } else {
        c.output_file.write(c.indent + ext_reg + " = zext " + ty_str + " " + input_reg + " to i32\n");
    }
    
    return CompileResult(reg=ext_reg, type=TYPE_INT);
}

func widen_int(c -> Compiler, value -> CompileResult, target -> Int) -> CompileResult {
    if (!is_integer_type(value.type) || !is_integer_type(target)) { return value; }
    let source_bits -> Int = get_type_bitwidth(value.type);
    let target_bits -> Int = get_type_bitwidth(target);
    if (source_bits >= target_bits) { return value; }
    if (is_signed_integer(value.type) && is_unsigned_integer(target)) { return value; }
    let source_type -> String = get_llvm_type_str(c, value.type);
    let target_type -> String = get_llvm_type_str(c, target);
    let result -> String = next_reg(c);
    let op -> String = "zext";
    if (is_signed_integer(value.type)) { op = "sext"; }
    c.output_file.write(c.indent + result + " = " + op + " " + source_type + " " + value.reg + " to " + target_type + "\n");
    return CompileResult(reg=result, type=target, origin_type=value.type, owns_ref=value.owns_ref);
}

func combine_i128_words(c -> Compiler, low -> String, high -> String) -> String {
    let low_i128 -> String = next_reg(c);
    c.output_file.write(c.indent + low_i128 + " = zext i64 " + low + " to i128\n");
    let high_i128 -> String = next_reg(c);
    c.output_file.write(c.indent + high_i128 + " = zext i64 " + high + " to i128\n");
    let shifted_high -> String = next_reg(c);
    c.output_file.write(c.indent + shifted_high + " = shl i128 " + high_i128 + ", 64\n");
    let result -> String = next_reg(c);
    c.output_file.write(c.indent + result + " = or i128 " + low_i128 + ", " + shifted_high + "\n");
    return result;
}

func check_layout_type(c -> Compiler, type_id -> Int, is_align -> Bool, pos -> Position) -> Bool {
    let property -> String = "size";
    if is_align { property = "alignment"; }
    if (type_id == TYPE_POISON) { return false; }
    if (type_id == TYPE_VOID) {
        throw_type_error(pos, "Type 'Void' has no " + property + ".");
        return false;
    }
    if (type_id == TYPE_AUTO) {
        throw_type_error(pos, "Type 'Auto' must be resolved before its " + property + " can be determined.");
        return false;
    }
    if (type_id == TYPE_GENERIC_STRUCT || type_id == TYPE_GENERIC_FUNCTION || type_id == TYPE_GENERIC_CLASS || type_id == TYPE_GENERIC_METHOD || type_id == TYPE_GENERIC_ENUM) {
        throw_type_error(pos, "Type-erased '" + get_type_name(c, type_id) + "' has no defined " + property + ".");
        return false;
    }
    return true;
}

func eval_const_long(c -> Compiler, node -> Struct, pos -> Position) -> Long {
    if (node is null) { return 0L; }
    let base -> BaseNode = node;
    
    if (base.type == NODE_INT) {
        let n -> IntNode = node;
        return string_to_long(n.tok.value, n.pos);
    }
    if (base.type == NODE_VAR_ACCESS) { return get_const_integer(c, node, pos); }
    if (base.type == NODE_TYPE_LAYOUT) {
        let layout -> TypeLayoutNode = node;
        let type_id -> Int = resolve_type(c, layout.type_node);
        if (!check_layout_type(c, type_id, layout.is_align, layout.pos)) { return 0L; }
        if (layout.is_align) { return Long(get_type_align_bytes(c, type_id)); }
        return Long(get_type_size_bytes(c, type_id));
    }
    if (base.type == NODE_UNARYOP) {
        let u -> UnaryOpNode = node;
        let op_str -> String = u.op_tok.value;
        let val -> Long = eval_const_long(c, u.node, pos);
        if (op_str == "-") { return 0L - val; }
        if (op_str == "~") { return val ^ -1L; }
        throw_type_error(pos, "Invalid unary operator for const integer.");
        return 0L;
    }
    if (base.type == NODE_BINOP) {
        let b -> BinOpNode = node;
        let op_str -> String = b.op_tok.value;
        let left -> Long = eval_const_long(c, b.left, pos);
        let right -> Long = eval_const_long(c, b.right, pos);
        
        if (op_str == "+") { return left + right; }
        if (op_str == "-") { return left - right; }
        if (op_str == "*") { return left * right; }
        if (op_str == "/") { 
            if (right == 0L) { throw_zero_division_error(pos, "Compile-time division by zero."); return 0L; }
            return left / right; 
        }
        if (op_str == "%") { 
            if (right == 0L) { throw_zero_division_error(pos, "Compile-time modulo by zero."); return 0L; }
            return left % right; 
        }
        if (op_str == "<<") { return left << right; }
        if (op_str == ">>") { return left >> right; }
        if (op_str == "&") { return left & right; }
        if (op_str == "|") { return left | right; }
        if (op_str == "^") { return left ^ right; }
        
        throw_type_error(pos, "Invalid binary operator for const integer.");
        return 0L;
    }
    throw_invalid_syntax(pos, "Expression is not a compile-time constant integer.");
    return 0L;
}

func get_const_symbol(c -> Compiler, node -> VarAccessNode, pos -> Position) -> SymbolInfo {
    let info -> SymbolInfo = find_symbol(c, node.name_tok.value);
    if (info is null) {
        throw_name_error(pos, "Unknown constant '" + node.name_tok.value + "'.");
        return null;
    }
    if (!info.is_const) {
        throw_type_error(pos, "Global initializer cannot use non-constant variable '" + node.name_tok.value + "'.");
        return null;
    }
    if (info.reg == "poison") {
        throw_invalid_syntax(pos, "Constant '" + node.name_tok.value + "' is used before its declaration.");
        return null;
    }
    return info;
}

func get_const_num(c -> Compiler, node -> VarAccessNode, pos -> Position) -> Float {
    let info -> SymbolInfo = get_const_symbol(c, node, pos);
    if (info is null) { return 0.0; }
    if (!c.constant_nums.contains_key(info.reg)) {
        throw_type_error(pos, "Constant '" + node.name_tok.value + "' is not numeric.");
        return 0.0;
    }
    return c.constant_nums.get(info.reg);
}

func get_const_integer(c -> Compiler, node -> VarAccessNode, pos -> Position) -> Long {
    let info -> SymbolInfo = get_const_symbol(c, node, pos);
    if (info is null) { return 0L; }
    if (!c.constant_integers.contains_key(info.reg)) {
        throw_type_error(pos, "Constant '" + node.name_tok.value + "' is not an integer.");
        return 0L;
    }
    return c.constant_integers.get(info.reg);
}

func get_const_wide_integer(c -> Compiler, node -> VarAccessNode, pos -> Position) -> UInt128 {
    let info -> SymbolInfo = get_const_symbol(c, node, pos);
    if (info is null) { return UInt128(0); }
    if (c.constant_wide_integers.contains_key(info.reg)) { return c.constant_wide_integers.get(info.reg); }
    if (c.constant_integers.contains_key(info.reg)) { let integer -> Long = c.constant_integers.get(info.reg); return UInt128(integer); }
    throw_type_error(pos, "Constant '" + node.name_tok.value + "' is not an integer.");
    return UInt128(0);
}

func eval_const_float(c -> Compiler, node -> Struct, pos -> Position) -> Float {
    if (node is null) { return 0.0; }
    let base -> BaseNode = node;
    if (base.type == NODE_FLOAT) {
        let value -> FloatNode = node;
        return parse_decimal_float_literal(value.tok.value);
    }
    if (base.type == NODE_INT) {
        let value_type -> Int = get_expr_type(c, node);
        if (get_type_bitwidth(value_type) == 128) {
            throw_type_error(pos, "128-bit integers are not supported in floating-point constant expressions.");
            return 0.0;
        }
        return Float(eval_const_long(c, node, pos));
    }
    if (base.type == NODE_CHAR) {
        let value -> CharNode = node;
        return Float(string_to_int(value.tok.value, value.pos));
    }
    if (base.type == NODE_BOOL) {
        let value -> BooleanNode = node;
        return Float(value.value);
    }
    if (base.type == NODE_VAR_ACCESS) { return get_const_num(c, node, pos); }
    if (base.type == NODE_UNARYOP) {
        let unary -> UnaryOpNode = node;
        let value -> Float = eval_const_float(c, unary.node, pos);
        if (unary.op_tok.type == TOK_PLUS) { return value; }
        if (unary.op_tok.type == TOK_SUB) { return 0.0 - value; }
        throw_type_error(pos, "Invalid unary operator in floating-point constant expression.");
        return 0.0;
    }
    if (base.type == NODE_BINOP) {
        let binary -> BinOpNode = node;
        let left -> Float = eval_const_float(c, binary.left, pos);
        let right -> Float = eval_const_float(c, binary.right, pos);
        let op -> Int = binary.op_tok.type;
        if (op == TOK_PLUS) { return left + right; }
        if (op == TOK_SUB) { return left - right; }
        if (op == TOK_MUL) { return left * right; }
        if (op == TOK_DIV) {
            if (right == 0.0) { throw_zero_division_error(pos, "Compile-time division by zero."); return 0.0; }
            return left / right;
        }
        if (op == TOK_MOD) {
            if (right == 0.0) { throw_zero_division_error(pos, "Compile-time modulo by zero."); return 0.0; }
            return left % right;
        }
        if (op == TOK_POW) { return left ** right; }
        throw_type_error(pos, "Invalid binary operator in floating-point constant expression.");
        return 0.0;
    }
    throw_invalid_syntax(pos, "Expression is not a compile-time floating-point constant.");
    return 0.0;
}

func llvm_float_literal(value -> Float) -> String {
    let raw -> AnyPtr = AnyPtr(ref value);
    let ptr bits -> UInt64 = raw;
    let encoded -> UInt64 = deref bits;
    let digits -> String = "0123456789ABCDEF";
    let result -> String = "0x";
    let shift -> Int = 60;
    while (shift >= 0) {
        let digit -> Int = Int((encoded >> UInt64(shift)) & UInt64(15));
        result += digits.slice(digit, digit + 1);
        shift -= 4;
    }
    return result;
}

func parse_const_uint128(raw -> String, pos -> Position) -> UInt128 {
    let end -> Int = raw.length();
    if (raw.ends_with("ULL") || raw.ends_with("ull")) { end -= 3; }
    else if (raw.ends_with("LL") || raw.ends_with("ll") || raw.ends_with("UL") || raw.ends_with("ul")) { end -= 2; }
    else if (raw.ends_with("U") || raw.ends_with("u") || raw.ends_with("L") || raw.ends_with("l")) { end -= 1; }

    let value -> UInt128 = UInt128(0);
    let i -> Int = 0;
    while (i < end) {
        let ch -> Char = raw[i];
        if (ch != '_') {
            if (ch < '0' || ch > '9') {
                throw_invalid_syntax(pos, "Invalid 128-bit integer literal.");
                return UInt128(0);
            }
            let digit -> Int = Int(ch) - 48;
            if (value > 34028236692093846346337460743176821145ULL ||
                (value == 34028236692093846346337460743176821145ULL && digit > 5)) {
                throw_overflow_error(pos, "128-bit integer literal is out of range.");
                return UInt128(0);
            }
            value = value * UInt128(10) + UInt128(digit);
        }
        i += 1;
    }
    return value;
}

func eval_const_wide(c -> Compiler, node -> Struct, pos -> Position, is_unsigned -> Bool) -> UInt128 {
    if (node is null) { return UInt128(0); }
    let base -> BaseNode = node;

    if (base.type == NODE_INT) {
        let value -> IntNode = node;
        let parsed -> UInt128 = parse_const_uint128(value.tok.value, value.pos);
        if (!is_unsigned && parsed > 170141183460469231731687303715884105727ULL) {
            throw_overflow_error(value.pos, "Literal '" + value.tok.value + "' overflows Int128 valid range.");
            return UInt128(0);
        }
        return parsed;
    }
    if (base.type == NODE_VAR_ACCESS) { return get_const_wide_integer(c, node, pos); }
    if (base.type == NODE_TYPE_LAYOUT) { return UInt128(eval_const_long(c, node, pos)); }
    if (base.type == NODE_UNARYOP) {
        let unary -> UnaryOpNode = node;
        let value -> UInt128 = eval_const_wide(c, unary.node, pos, is_unsigned);
        if (unary.op_tok.value == "-") { return UInt128(0) - value; }
        if (unary.op_tok.value == "~") { return value ^ 340282366920938463463374607431768211455ULL; }
        throw_type_error(pos, "Invalid unary operator for 128-bit constant integer.");
        return UInt128(0);
    }
    if (base.type == NODE_BINOP) {
        let binary -> BinOpNode = node;
        let op -> String = binary.op_tok.value;
        let left -> UInt128 = eval_const_wide(c, binary.left, pos, is_unsigned);
        let right -> UInt128 = eval_const_wide(c, binary.right, pos, is_unsigned);

        if (op == "+") { return left + right; }
        if (op == "-") { return left - right; }
        if (op == "*") { return left * right; }
        if (op == "<<") { return left << right; }
        if (op == ">>") {
            if is_unsigned { return left >> right; }
            return UInt128(Int128(left) >> Int128(right));
        }
        if (op == "&") { return left & right; }
        if (op == "|") { return left | right; }
        if (op == "^") { return left ^ right; }
        if (op == "/" || op == "%") {
            if (right == UInt128(0)) {
                throw_zero_division_error(pos, "Compile-time division by zero.");
                return UInt128(0);
            }
            if is_unsigned {
                if (op == "/") { return left / right; }
                return left % right;
            }

            let signed_left -> Int128 = Int128(left);
            let signed_right -> Int128 = Int128(right);
            if (signed_left == -170141183460469231731687303715884105727LL - Int128(1) && signed_right == Int128(-1)) {
                throw_overflow_error(pos, "Compile-time signed division overflow.");
                return UInt128(0);
            }
            if (op == "/") { return UInt128(signed_left / signed_right); }
            return UInt128(signed_left % signed_right);
        }

        throw_type_error(pos, "Invalid binary operator for 128-bit constant integer.");
        return UInt128(0);
    }

    throw_invalid_syntax(pos, "Expression is not a compile-time constant 128-bit integer.");
    return UInt128(0);
}
func eval_const_bool(c -> Compiler, node -> Struct, pos -> Position) -> Int {
    if (node is null) { return 0; }
    let base -> BaseNode = node;

    if (base.type == NODE_BOOL) {
        let b -> BooleanNode = node;
        return b.value;
    }
    if (base.type == NODE_VAR_ACCESS) {
        let value -> Long = get_const_integer(c, node, pos);
        if (value == 0L) { return 0; }
        if (value == 1L) { return 1; }
        throw_type_error(pos, "Boolean constant expression requires a Bool value.");
        return 0;
    }
    if (base.type == NODE_UNARYOP) {
        let u -> UnaryOpNode = node;
        let op_str -> String = u.op_tok.value;
        if (op_str == "!") {
            let val -> Int = eval_const_bool(c, u.node, pos);
            if (val == 1) { return 0; } else { return 1; }
        }
        throw_type_error(pos, "Invalid unary operator for const boolean.");
        return 0;
    }
    if (base.type == NODE_BINOP) {
        let b -> BinOpNode = node;
        let op_str -> String = b.op_tok.value;

        if (op_str == "&&") {
            let left -> Int = eval_const_bool(c, b.left, pos);
            let right -> Int = eval_const_bool(c, b.right, pos);
            if (left == 1 && right == 1) { return 1; } else { return 0; }
        }
        if (op_str == "||") {
            let left -> Int = eval_const_bool(c, b.left, pos);
            let right -> Int = eval_const_bool(c, b.right, pos);
            if (left == 1 || right == 1) { return 1; } else { return 0; }
        }

        if (op_str == "==" || op_str == "!=" || op_str == "<" || op_str == ">" || op_str == "<=" || op_str == ">=") {
            let left_type -> Int = get_expr_type(c, b.left);
            let right_type -> Int = get_expr_type(c, b.right);
            if (get_type_bitwidth(left_type) == 128 || get_type_bitwidth(right_type) == 128) {
                let use_unsigned -> Bool = is_unsigned_integer(left_type) || is_unsigned_integer(right_type);
                let left_wide -> UInt128 = eval_const_wide(c, b.left, pos, use_unsigned);
                let right_wide -> UInt128 = eval_const_wide(c, b.right, pos, use_unsigned);
                if (op_str == "==") { if (left_wide == right_wide) { return 1; } else { return 0; } }
                if (op_str == "!=") { if (left_wide != right_wide) { return 1; } else { return 0; } }
                if use_unsigned {
                    if (op_str == "<") { if (left_wide < right_wide) { return 1; } else { return 0; } }
                    if (op_str == ">") { if (left_wide > right_wide) { return 1; } else { return 0; } }
                    if (op_str == "<=") { if (left_wide <= right_wide) { return 1; } else { return 0; } }
                    if (op_str == ">=") { if (left_wide >= right_wide) { return 1; } else { return 0; } }
                } else {
                    let signed_left -> Int128 = Int128(left_wide);
                    let signed_right -> Int128 = Int128(right_wide);
                    if (op_str == "<") { if (signed_left < signed_right) { return 1; } else { return 0; } }
                    if (op_str == ">") { if (signed_left > signed_right) { return 1; } else { return 0; } }
                    if (op_str == "<=") { if (signed_left <= signed_right) { return 1; } else { return 0; } }
                    if (op_str == ">=") { if (signed_left >= signed_right) { return 1; } else { return 0; } }
                }
            }
            let left -> Long = eval_const_long(c, b.left, pos);
            let right -> Long = eval_const_long(c, b.right, pos);
            if (op_str == "==") { if (left == right) { return 1; } else { return 0; } }
            if (op_str == "!=") { if (left != right) { return 1; } else { return 0; } }
            if (op_str == "<") { if (left < right) { return 1; } else { return 0; } }
            if (op_str == ">") { if (left > right) { return 1; } else { return 0; } }
            if (op_str == "<=") { if (left <= right) { return 1; } else { return 0; } }
            if (op_str == ">=") { if (left >= right) { return 1; } else { return 0; } }
        }

        throw_type_error(pos, "Invalid binary operator for const boolean.");
        return 0;
    }

    throw_invalid_syntax(pos, "Expression is not a compile-time constant boolean.");
    return 0;
}

func emit_implicit_cast(c -> Compiler, val_res -> CompileResult, expected_type -> Int, pos -> Position) -> CompileResult {
    if (val_res is null || val_res.reg == "") {
        let dummy_reg -> String = "0";
        if (is_nullable_reference_type(c, expected_type) || is_pointer_type(c, expected_type)) {
            dummy_reg = "null";
        } else if (expected_type == TYPE_FLOAT) {
            dummy_reg = "0.0";
        }
        return CompileResult(reg=dummy_reg, type=expected_type, origin_type=expected_type);
    }

    if (val_res.type == expected_type) { return val_res; }
    if (val_res is !null && val_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    if (expected_type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let origin -> Int = val_res.origin_type;

    let variant_info -> StructInfo = c.struct_table.get("$Variant");
    if (variant_info is !null && expected_type == variant_info.type_id) {
        let boxed_info -> StructInfo = c.struct_id_map.get("" + val_res.type);
        let boxed_enum -> Bool = boxed_info is !null && boxed_info.is_enum;
        let boxed_type_supported -> Bool = val_res.type == TYPE_NULL ||
                                           is_primitive_type(val_res.type) ||
                                           is_ref_type(c, val_res.type) ||
                                           is_pointer_type(c, val_res.type) ||
                                           boxed_enum;
        if (!boxed_type_supported) {
            throw_type_error(pos, "Type " + get_type_name(c, val_res.type) + " cannot be stored in Dict.");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }

        let variant_llvm -> String = variant_info.llvm_name;
        let box_ptr -> String = emit_alloc_obj(c, "" + variant_payload_size(), "" + expected_type, variant_llvm + "*");

        let type_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + type_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + box_ptr + ", i32 0, i32 0\n");
        let boxed_tag -> UInt64 = type_fingerprint(c, val_res.type);
        if (val_res.type == TYPE_NULL || val_res.type == TYPE_NULLPTR) { boxed_tag = UInt64(0); }
        c.output_file.write(c.indent + "store i64 " + boxed_tag + ", i64* " + type_ptr + "\n");

        let payload_low_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + payload_low_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + box_ptr + ", i32 0, i32 1\n");
        let payload_high_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + payload_high_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + box_ptr + ", i32 0, i32 2\n");

        let payload_low -> String = "0";
        let payload_high -> String = "0";

        if (val_res.type == TYPE_NULL || val_res.type == TYPE_NULLPTR) {
            payload_low = "0";
        } else if (boxed_info is !null && boxed_info.is_interface) {
            let interface_ty -> String = get_llvm_type_str(c, val_res.type);
            let object_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + object_ptr + " = extractvalue " + interface_ty + " " + val_res.reg + ", 0\n");
            let table_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + table_ptr + " = extractvalue " + interface_ty + " " + val_res.reg + ", 1\n");
            payload_low = next_reg(c);
            c.output_file.write(c.indent + payload_low + " = ptrtoint i8* " + object_ptr + " to i64\n");
            payload_high = next_reg(c);
            c.output_file.write(c.indent + payload_high + " = ptrtoint i8* " + table_ptr + " to i64\n");
            if (!val_res.owns_ref) {
                emit_retain(c, val_res.reg, val_res.type);
            }
        } else if (val_res.type == TYPE_INT128 || val_res.type == TYPE_UINT128) {
            payload_low = next_reg(c);
            c.output_file.write(c.indent + payload_low + " = trunc i128 " + val_res.reg + " to i64\n");
            let shifted_high -> String = next_reg(c);
            c.output_file.write(c.indent + shifted_high + " = lshr i128 " + val_res.reg + ", 64\n");
            payload_high = next_reg(c);
            c.output_file.write(c.indent + payload_high + " = trunc i128 " + shifted_high + " to i64\n");
        } else if (is_small_primitive_type(val_res.type)) {
            let prim_ty -> String = get_llvm_type_str(c, val_res.type);
            payload_low = next_reg(c);
            if (is_signed_integer(val_res.type)) {
                c.output_file.write(c.indent + payload_low + " = sext " + prim_ty + " " + val_res.reg + " to i64\n");
            } else {
                c.output_file.write(c.indent + payload_low + " = zext " + prim_ty + " " + val_res.reg + " to i64\n");
            }
        } else if (val_res.type == TYPE_FLOAT32) {
            let fpext_reg -> String = next_reg(c);
            c.output_file.write(c.indent + fpext_reg + " = fpext float " + val_res.reg + " to double\n");
            payload_low = next_reg(c);
            c.output_file.write(c.indent + payload_low + " = bitcast double " + fpext_reg + " to i64\n");
        } else if (val_res.type == TYPE_INTSIZE || val_res.type == TYPE_UINTSIZE) {
            let size_ty -> String = get_size_llvm_type();
            payload_low = next_reg(c);
            if (val_res.type == TYPE_INTSIZE) {
                c.output_file.write(c.indent + payload_low + " = sext " + size_ty + " " + val_res.reg + " to i64\n");
            } else {
                c.output_file.write(c.indent + payload_low + " = zext " + size_ty + " " + val_res.reg + " to i64\n");
            }
        } else if (val_res.type == TYPE_LONG || val_res.type == TYPE_UINT64) {
            payload_low = next_reg(c);
            c.output_file.write(c.indent + payload_low + " = add i64 0, " + val_res.reg + "\n");
        } else if (val_res.type == TYPE_FLOAT) {
            payload_low = next_reg(c);
            c.output_file.write(c.indent + payload_low + " = bitcast double " + val_res.reg + " to i64\n");
        } else {
            payload_low = next_reg(c);
            if boxed_enum {
                c.output_file.write(c.indent + payload_low + " = zext i32 " + val_res.reg + " to i64\n");
            } else {
                let ptr_ty -> String = get_llvm_type_str(c, val_res.type);
                c.output_file.write(c.indent + payload_low + " = ptrtoint " + ptr_ty + " " + val_res.reg + " to i64\n");
                if (is_ref_type(c, val_res.type) && !val_res.owns_ref) {
                    emit_retain(c, val_res.reg, val_res.type);
                }
            }
        }

        c.output_file.write(c.indent + "store i64 " + payload_low + ", i64* " + payload_low_ptr + "\n");
        c.output_file.write(c.indent + "store i64 " + payload_high + ", i64* " + payload_high_ptr + "\n");
        return CompileResult(reg=box_ptr, type=expected_type, origin_type=val_res.type);
    }

    let variant_info_check -> StructInfo = c.struct_table.get("$Variant");
    if (variant_info_check is !null && val_res.type == variant_info_check.type_id) {
        let variant_llvm -> String = variant_info_check.llvm_name;
        
        let read_box_label -> String = "read_box_" + c.type_counter;
        let check_match_label -> String = "check_match_" + c.type_counter;
        let unbox_label -> String = "unbox_" + c.type_counter;
        let merge_label -> String = "merge_" + c.type_counter;
        let fail_label -> String = "unbox_fail_" + c.type_counter;
        let null_return_label -> String = "ret_null_" + c.type_counter;
        c.type_counter += 1;

        let can_be_null -> Bool = is_ref_type(c, expected_type) || is_pointer_type(c, expected_type);

        let is_null_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + is_null_ptr + " = icmp eq " + variant_llvm + "* " + val_res.reg + ", null\n");
        
        if can_be_null {
            c.output_file.write(c.indent + "br i1 " + is_null_ptr + ", label %" + null_return_label + ", label %" + read_box_label + "\n");
        } else {
            c.output_file.write(c.indent + "br i1 " + is_null_ptr + ", label %" + fail_label + ", label %" + read_box_label + "\n");
        }

        c.output_file.write("\n" + read_box_label + ":\n");
        let type_id_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + type_id_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + val_res.reg + ", i32 0, i32 0\n");
        let type_id_reg -> String = next_reg(c);
        c.output_file.write(c.indent + type_id_reg + " = load i64, i64* " + type_id_ptr + "\n");

        let is_zero_tag -> String = next_reg(c);
        c.output_file.write(c.indent + is_zero_tag + " = icmp eq i64 " + type_id_reg + ", 0\n");
        
        if can_be_null {
            c.output_file.write(c.indent + "br i1 " + is_zero_tag + ", label %" + null_return_label + ", label %" + check_match_label + "\n");
        } else {
            c.output_file.write(c.indent + "br i1 " + is_zero_tag + ", label %" + fail_label + ", label %" + check_match_label + "\n");
        }

        c.output_file.write("\n" + check_match_label + ":\n");
        let is_match -> String = next_reg(c);
        
        if (expected_type == TYPE_GENERIC_STRUCT || expected_type == TYPE_GENERIC_CLASS) {
            let match_acc -> String = "false";
            let candidate -> Int = 1;
            while (candidate < c.type_counter) {
                let candidate_info -> StructInfo = c.struct_id_map.get("" + candidate);
                let accepts -> Bool = false;
                if (candidate == TYPE_STRING) { accepts = true; }
                if (candidate_info is !null && !candidate_info.is_enum && !candidate_info.is_interface) {
                    if (expected_type == TYPE_GENERIC_STRUCT && !candidate_info.is_class) { accepts = true; }
                    if (expected_type == TYPE_GENERIC_CLASS && candidate_info.is_class) { accepts = true; }
                }
                if accepts {
                    let candidate_match -> String = next_reg(c);
                    c.output_file.write(c.indent + candidate_match + " = icmp eq i64 " + type_id_reg + ", " + type_fingerprint(c, candidate) + "\n");
                    if (match_acc == "false") {
                        match_acc = candidate_match;
                    } else {
                        let combined -> String = next_reg(c);
                        c.output_file.write(c.indent + combined + " = or i1 " + match_acc + ", " + candidate_match + "\n");
                        match_acc = combined;
                    }
                }
                candidate += 1;
            }
            if (match_acc == "false") {
                c.output_file.write(c.indent + is_match + " = icmp eq i1 false, true\n");
            } else {
                c.output_file.write(c.indent + is_match + " = or i1 false, " + match_acc + "\n");
            }
        } else {
            c.output_file.write(c.indent + is_match + " = icmp eq i64 " + type_id_reg + ", " + type_fingerprint(c, expected_type) + "\n");
        }
        
        c.output_file.write(c.indent + "br i1 " + is_match + ", label %" + unbox_label + ", label %" + fail_label + "\n");

        c.output_file.write("\n" + fail_label + ":\n");
        emit_runtime_error(c, pos, "Dict value type mismatch or missing. Expected " + get_type_name(c, expected_type) + ".");

        c.output_file.write("\n" + unbox_label + ":\n");
        let payload_low_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + payload_low_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + val_res.reg + ", i32 0, i32 1\n");
        let payload_low -> String = next_reg(c);
        c.output_file.write(c.indent + payload_low + " = load i64, i64* " + payload_low_ptr + "\n");
        let payload_high_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + payload_high_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + val_res.reg + ", i32 0, i32 2\n");
        let payload_high -> String = next_reg(c);
        c.output_file.write(c.indent + payload_high + " = load i64, i64* " + payload_high_ptr + "\n");
        
        let unboxed_reg -> String = "";
        if (expected_type == TYPE_INT128 || expected_type == TYPE_UINT128) {
            unboxed_reg = combine_i128_words(c, payload_low, payload_high);
        } else if (is_small_primitive_type(expected_type)) {
            let prim_ty -> String = get_llvm_type_str(c, expected_type);
            unboxed_reg = next_reg(c);
            c.output_file.write(c.indent + unboxed_reg + " = trunc i64 " + payload_low + " to " + prim_ty + "\n");
        } else if (expected_type == TYPE_FLOAT32) {
            let cast_double -> String = next_reg(c);
            c.output_file.write(c.indent + cast_double + " = bitcast i64 " + payload_low + " to double\n");
            unboxed_reg = next_reg(c);
            c.output_file.write(c.indent + unboxed_reg + " = fptrunc double " + cast_double + " to float\n");
        } else if (expected_type == TYPE_INTSIZE || expected_type == TYPE_UINTSIZE) {
            let size_ty -> String = get_size_llvm_type();
            unboxed_reg = next_reg(c);
            c.output_file.write(c.indent + unboxed_reg + " = trunc i64 " + payload_low + " to " + size_ty + "\n");
        } else if (expected_type == TYPE_LONG || expected_type == TYPE_UINT64) {
            unboxed_reg = next_reg(c);
            c.output_file.write(c.indent + unboxed_reg + " = add i64 0, " + payload_low + "\n");
        } else if (expected_type == TYPE_FLOAT) {
            unboxed_reg = next_reg(c);
            c.output_file.write(c.indent + unboxed_reg + " = bitcast i64 " + payload_low + " to double\n");
        } else {
            let exp_s_info -> StructInfo = c.struct_id_map.get("" + expected_type);
            if (exp_s_info is !null && exp_s_info.is_interface) {
                let object_ptr -> String = next_reg(c);
                c.output_file.write(c.indent + object_ptr + " = inttoptr i64 " + payload_low + " to i8*\n");
                let table_ptr -> String = next_reg(c);
                c.output_file.write(c.indent + table_ptr + " = inttoptr i64 " + payload_high + " to i8*\n");
                let interface_ty -> String = get_llvm_type_str(c, expected_type);
                let with_object -> String = next_reg(c);
                c.output_file.write(c.indent + with_object + " = insertvalue " + interface_ty + " undef, i8* " + object_ptr + ", 0\n");
                unboxed_reg = next_reg(c);
                c.output_file.write(c.indent + unboxed_reg + " = insertvalue " + interface_ty + " " + with_object + ", i8* " + table_ptr + ", 1\n");
            } else if (exp_s_info is !null && exp_s_info.is_enum) {
                unboxed_reg = next_reg(c);
                c.output_file.write(c.indent + unboxed_reg + " = trunc i64 " + payload_low + " to i32\n");
            } else {
                let ptr_ty -> String = get_llvm_type_str(c, expected_type);
                unboxed_reg = next_reg(c);
                c.output_file.write(c.indent + unboxed_reg + " = inttoptr i64 " + payload_low + " to " + ptr_ty + "\n");
            }
        }
        c.output_file.write(c.indent + "br label %" + merge_label + "\n");

        if can_be_null {
            c.output_file.write("\n" + null_return_label + ":\n");
            c.output_file.write(c.indent + "br label %" + merge_label + "\n");
        }

        c.output_file.write("\n" + merge_label + ":\n");
        let final_val_reg -> String = next_reg(c);
        let exp_ty_str -> String = get_llvm_type_str(c, expected_type);
        
        if can_be_null {
            let zero_val -> String = "0";
            if (expected_type == TYPE_FLOAT) {
                zero_val = "0.0";
            } else if (is_nullable_reference_type(c, expected_type)) {
                zero_val = "null";
            }
            let expected_info -> StructInfo = c.struct_id_map.get("" + expected_type);
            if (expected_info is !null && expected_info.is_interface) {
                zero_val = "zeroinitializer";
            }
            
            c.output_file.write(c.indent + final_val_reg + " = phi " + exp_ty_str + " [ " + unboxed_reg + ", %" + unbox_label + " ], [ " + zero_val + ", %" + null_return_label + " ]\n");
        } else {
            c.output_file.write(c.indent + final_val_reg + " = phi " + exp_ty_str + " [ " + unboxed_reg + ", %" + unbox_label + " ]\n");
        }

        let result_owned -> Bool = false;
        if (val_res.owns_ref) {
            if (is_ref_type(c, expected_type)) {
                emit_retain(c, final_val_reg, expected_type);
                result_owned = true;
            }
            emit_release_owned(c, val_res);
        }

        return CompileResult(reg=final_val_reg, type=expected_type, origin_type=0, owns_ref=result_owned);
    }

    if (val_res.type == TYPE_NULLPTR) {
        if (is_pointer_type(c, expected_type)) {
            return CompileResult(reg="null", type=expected_type, origin_type=expected_type);
        }
        throw_type_error(pos, "'nullptr' can only be assigned to explicit pointer types.");
        return CompileResult(reg="0", type=expected_type, origin_type=expected_type);
    }
    if (val_res.type == TYPE_NULL) {
        let ex_s -> StructInfo = c.struct_id_map.get("" + expected_type);
        if (ex_s is !null && ex_s.is_interface) {
            return CompileResult(reg="zeroinitializer", type=expected_type, origin_type=expected_type);
        }
        if (is_pointer_type(c, expected_type)) {
            throw_type_error(pos, "Keyword 'null' cannot be assigned to explicit pointer types. Use 'nullptr'.");
            return CompileResult(reg="0", type=expected_type, origin_type=expected_type);
        }
        if (!is_nullable_reference_type(c, expected_type)) {
            throw_type_error(pos, "Type " + get_type_name(c, expected_type) + " cannot be null.");
            return CompileResult(reg="zeroinitializer", type=expected_type, origin_type=expected_type);
        }
        return CompileResult(reg="null", type=expected_type, origin_type=expected_type);
    }

    if (is_integer_type(expected_type) && is_integer_type(val_res.type)) {
        let widened_int -> CompileResult = widen_int(c, val_res, expected_type);
        if (widened_int.type == expected_type) { return widened_int; }
    }
    if (expected_type == TYPE_CHAR && val_res.type == TYPE_BYTE) {
        let char_reg -> String = next_reg(c);
        c.output_file.write(c.indent + char_reg + " = zext i8 " + val_res.reg + " to i32\n");
        return CompileResult(reg=char_reg, type=TYPE_CHAR, origin_type=TYPE_BYTE);
    }
    if (expected_type == TYPE_FLOAT && val_res.type == TYPE_INT) { return promote_to_float(c, val_res); }
    if (expected_type == TYPE_FLOAT && val_res.type == TYPE_LONG) { return promote_to_float(c, val_res); }
    if (expected_type == TYPE_FLOAT && val_res.type == TYPE_FLOAT32) { return promote_to_float(c, val_res); }

    if (expected_type == TYPE_GENERIC_ENUM) {
        if (val_res.type >= 100) {
            let s_info -> StructInfo = c.struct_id_map.get("" + val_res.type);
            if (s_info is !null && s_info.is_enum) {
                return CompileResult(reg=val_res.reg, type=TYPE_GENERIC_ENUM, origin_type=val_res.type);
            }
        }
    }
    if (val_res.type == TYPE_GENERIC_ENUM && expected_type >= 100) {
        let s_info -> StructInfo = c.struct_id_map.get("" + expected_type);
        if (s_info is !null && s_info.is_enum) {
            return CompileResult(reg=val_res.reg, type=expected_type, origin_type=origin);
        }
    }

    let ex_info -> StructInfo = c.struct_id_map.get("" + expected_type);
    let val_info -> StructInfo = c.struct_id_map.get("" + val_res.type);

    if (ex_info is !null && ex_info.is_interface) {
        if (val_info is !null && val_info.is_class) {
            if (!class_has_interface(c, val_info, ex_info)) {
                throw_type_error(pos, "class '" + val_info.name + "' does not implement interface '" + ex_info.name + "'");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            let itable_name -> String = "@itable." + val_info.name + "." + ex_info.name;
            let itable_len -> Int = 0; if (ex_info.vtable is !null) { itable_len = ex_info.vtable.length(); }
            let obj_cast -> String = next_reg(c);
            c.output_file.write(c.indent + obj_cast + " = bitcast " + val_info.llvm_name + "* " + val_res.reg + " to i8*\n");
            let s1 -> String = next_reg(c);
            let s2 -> String = next_reg(c);
            c.output_file.write(c.indent + s1 + " = insertvalue { i8*, i8* } undef, i8* " + obj_cast + ", 0\n");
            if (itable_len > 0) {
                let itable_ptr -> String = next_reg(c);
                c.output_file.write(c.indent + itable_ptr + " = bitcast [ " + itable_len + " x i8* ]* " + itable_name + " to i8*\n");
                c.output_file.write(c.indent + s2 + " = insertvalue { i8*, i8* } " + s1 + ", i8* " + itable_ptr + ", 1\n");
            } else {
                c.output_file.write(c.indent + s2 + " = insertvalue { i8*, i8* } " + s1 + ", i8* null, 1\n");
            }
            return CompileResult(reg=s2, type=expected_type, origin_type=val_res.type, owns_ref=val_res.owns_ref, is_const_access=val_res.is_const_access);
        }
    }

    if (expected_type == TYPE_GENERIC_STRUCT || expected_type == TYPE_GENERIC_CLASS) {
        if (val_res.type >= 100) {
            let cast_reg -> String = next_reg(c);
            let src_ty -> String = get_llvm_type_str(c, val_res.type);
            c.output_file.write(c.indent + cast_reg + " = bitcast " + src_ty + " " + val_res.reg + " to i8*\n");
            return CompileResult(reg=cast_reg, type=expected_type, origin_type=val_res.type, owns_ref=val_res.owns_ref, is_const_access=val_res.is_const_access);
        }
    }
    if ((val_res.type == TYPE_GENERIC_STRUCT || val_res.type == TYPE_GENERIC_CLASS) && expected_type >= 100) {
        if (c.struct_id_map.get("" + expected_type) is !null || c.vector_base_map.get("" + expected_type) is !null) {
            if (origin >= 100) {
                let compatible -> Bool = origin == expected_type;
                if (val_res.type == TYPE_GENERIC_STRUCT) {
                    compatible = erased_struct_compatible(c, origin, expected_type);
                }
                if (val_res.type == TYPE_GENERIC_CLASS) {
                    compatible = is_subclass(c, origin, expected_type);
                }
                if (!compatible) {
                    throw_type_error(pos, "Cannot restore " + get_type_name(c, val_res.type) + " as " + get_type_name(c, expected_type));
                    return CompileResult(reg="poison", type=TYPE_POISON);
                }
            }
            let cast_reg -> String = next_reg(c);
            let dest_ty -> String = get_llvm_type_str(c, expected_type);
            c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + val_res.reg + " to " + dest_ty + "\n");
            return CompileResult(reg=cast_reg, type=expected_type, origin_type=origin, owns_ref=val_res.owns_ref, is_const_access=val_res.is_const_access);
        }
    }

    if (is_pointer_type(c, expected_type) && is_pointer_type(c, val_res.type)) {
        if (is_void_ptr(c, expected_type) || is_void_ptr(c, val_res.type)) {
            let cast_reg -> String = next_reg(c);
            let dest_ty -> String = get_llvm_type_str(c, expected_type);
            let src_ty -> String = get_llvm_type_str(c, val_res.type);
            if (dest_ty != src_ty) {
                c.output_file.write(c.indent + cast_reg + " = bitcast " + src_ty + " " + val_res.reg + " to " + dest_ty + "\n");
                return CompileResult(reg=cast_reg, type=expected_type, origin_type=origin);
            }
            return CompileResult(reg=val_res.reg, type=expected_type, origin_type=origin);
        }
    }

    if (is_void_ptr(c, expected_type)) {
        if (val_res.type == TYPE_STRING) {
            let cast_reg -> String = next_reg(c);
            let dest_ty -> String = get_llvm_type_str(c, expected_type);
            c.output_file.write(c.indent + cast_reg + " = bitcast %struct.$String* " + val_res.reg + " to " + dest_ty + "\n");
            return CompileResult(reg=cast_reg, type=expected_type, origin_type=val_res.type, owns_ref=val_res.owns_ref);
        }
    }

    if (is_void_ptr(c, val_res.type) && expected_type != TYPE_NULL && expected_type != TYPE_NULLPTR && !is_void_ptr(c, expected_type)) {
        if (expected_type == TYPE_STRING) {
            let cast_reg -> String = next_reg(c);
            let src_ty -> String = get_llvm_type_str(c, val_res.type);
            c.output_file.write(c.indent + cast_reg + " = bitcast " + src_ty + " " + val_res.reg + " to %struct.$String*\n");
            return CompileResult(reg=cast_reg, type=expected_type, origin_type=origin, owns_ref=val_res.owns_ref);
        }
    }

    if (expected_type == TYPE_GENERIC_FUNCTION) {
        if (val_res.type >= 100) {
            let f_check -> SymbolInfo = c.func_ret_map.get("" + val_res.type);
            if (f_check is !null) {
                return CompileResult(reg=val_res.reg, type=expected_type, origin_type=val_res.type, owns_ref=val_res.owns_ref);
            }
        }
    }
    if (expected_type == TYPE_GENERIC_METHOD) {
        if (val_res.type >= 100) {
            let m_check -> SymbolInfo = c.method_ret_map.get("" + val_res.type);
            if (m_check is !null) {
                return CompileResult(reg=val_res.reg, type=expected_type, origin_type=val_res.type, owns_ref=val_res.owns_ref);
            }
        }
    }
    if (val_res.type == TYPE_GENERIC_FUNCTION && expected_type >= 100) {
        if (c.func_ret_map.get("" + expected_type) is !null) {
            if (origin != 0 && origin != expected_type) {
                throw_type_error(pos, "Cannot restore Function as " + get_type_name(c, expected_type));
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            emit_erased_type_check(c, val_res.reg, expected_type, pos);
            return CompileResult(reg=val_res.reg, type=expected_type, origin_type=origin, owns_ref=val_res.owns_ref);
        }
    }
    if (val_res.type == TYPE_GENERIC_METHOD && expected_type >= 100) {
        if (c.method_ret_map.get("" + expected_type) is !null) {
            if (origin != 0 && origin != expected_type) {
                throw_type_error(pos, "Cannot restore Method as " + get_type_name(c, expected_type));
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            emit_erased_type_check(c, val_res.reg, expected_type, pos);
            return CompileResult(reg=val_res.reg, type=expected_type, origin_type=origin, owns_ref=val_res.owns_ref);
        }
    }

    if (val_res.type >= 100 && expected_type >= 100) {
        if (is_subclass(c, val_res.type, expected_type)) {
            let cast_reg -> String = next_reg(c);
            let dest_ty -> String = get_llvm_type_str(c, expected_type);
            let src_ty -> String = get_llvm_type_str(c, val_res.type);
            c.output_file.write(c.indent + cast_reg + " = bitcast " + src_ty + " " + val_res.reg + " to " + dest_ty + "\n");
            return CompileResult(reg=cast_reg, type=expected_type, origin_type=val_res.origin_type, owns_ref=val_res.owns_ref);
        }
    }

    let expected_arr -> ArrayInfo = c.array_info_map.get("" + expected_type);
    if (expected_arr is !null && expected_arr.size == -1) {
        let elem_type -> Int = expected_arr.base_type;
        let elem_ty_str -> String = get_llvm_type_str(c, elem_type);

        let val_arr -> ArrayInfo = c.array_info_map.get("" + val_res.type);
        if (val_arr is !null && val_arr.size > 0 && val_arr.base_type == elem_type) {
            let data_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + val_arr.llvm_name + ", " + val_arr.llvm_name + "* " + val_res.reg + ", i32 0, i32 0\n");
            return emit_slice_copy(c, elem_type, data_ptr, "0", "" + val_arr.size, pos);
        }

        let val_vec -> SymbolInfo = c.vector_base_map.get("" + val_res.type);
        if (val_vec is !null && val_vec.type == elem_type) {
            let vec_struct_ty -> String = get_vector_llvm_type(c, elem_type);
            let size_ty -> String = get_size_llvm_type();
            let size_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + vec_struct_ty + ", " + vec_struct_ty + "* " + val_res.reg + ", i32 0, i32 0\n");
            let size_val -> String = next_reg(c);
            c.output_file.write(c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");
            
            let data_ptr_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + data_ptr_ptr + " = getelementptr inbounds " + vec_struct_ty + ", " + vec_struct_ty + "* " + val_res.reg + ", i32 0, i32 2\n");
            let data_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_ptr_ptr + "\n");

            let size_i32 -> String = size_val;
            if (size_ty != "i32") {
                size_i32 = next_reg(c);
                c.output_file.write(c.indent + size_i32 + " = trunc " + size_ty + " " + size_val + " to i32\n");
            }
            let copied -> CompileResult = emit_slice_copy(c, elem_type, data_ptr, "0", size_i32, pos);
            emit_release_owned(c, val_res);
            return copied;
        }
    }

    throw_type_error(pos, "Type mismatch. Expected " + get_type_name(c, expected_type) + ", got " + get_type_name(c, val_res.type));
    return CompileResult(reg="0", type=expected_type, origin_type=expected_type);
}

func emit_target_intrinsic(c -> Compiler, info -> SymbolInfo) -> CompileResult {
    let name -> String = info.reg.slice(11, info.reg.length());
    return CompileResult(reg="" + target_value(name), type=info.type, origin_type=info.type);
}

func register_string_constant(c -> Compiler, val -> String) -> Int {
    let exist -> StringConstant = c.string_pool.get(val);
    if (exist is !null) {
        return exist.id;
    }
    let s_id -> Int = c.str_count;
    c.str_count += 1;
    let sc -> StringConstant = StringConstant(id=s_id, value=val);
    c.string_list.append(sc);
    c.string_pool.put(val, sc);
    return s_id;
}

func get_string_ptr(s_id -> Int, s_val -> String) -> String {
    let len -> Int = s_val.length() + 1;
    return "getelementptr inbounds ([" + len + " x i8], [" + len + " x i8]* @.str.bytes." + s_id + ", i32 0, i32 0)";
}

func get_string_object_ptr(s_id -> Int) -> String {
    return "getelementptr inbounds ({ i32, i32, %struct.$String }, { i32, i32, %struct.$String }* @.str." + s_id + ", i32 0, i32 2)";
}

func expr_root_name(node -> Struct) -> String {
    if (node is null) { return ""; }
    let base -> BaseNode = node;
    if (base.type == NODE_VAR_ACCESS) { let value -> VarAccessNode = node; return value.name_tok.value; }
    if (base.type == NODE_FIELD_ACCESS) { let value -> FieldAccessNode = node; return expr_root_name(value.obj); }
    if (base.type == NODE_INDEX_ACCESS) { let value -> IndexAccessNode = node; return expr_root_name(value.target); }
    if (base.type == NODE_SLICE_ACCESS) { let value -> SliceAccessNode = node; return expr_root_name(value.target); }
    if (base.type == NODE_DEREF) { let value -> DerefNode = node; return expr_root_name(value.node); }
    return "";
}

func const_access_root(c -> Compiler, node -> Struct) -> String {
    let name -> String = expr_root_name(node);
    if (name.length() == 0) { return ""; }
    let info -> SymbolInfo = find_symbol(c, name);
    if (info is !null && (info.is_const || info.is_const_access)) { return name; }
    return "";
}

func reject_const_write(c -> Compiler, node -> Struct, pos -> Position) -> Bool {
    let name -> String = const_access_root(c, node);
    if (name.length() == 0) { return false; }
    throw_type_error(pos, "Cannot modify value through const access '" + name + "'");
    return true;
}

func method_mutates_self(node -> Struct) -> Bool {
    if (node is null) { return false; }
    let base -> BaseNode = node;
    if (base.type == NODE_FIELD_ASSIGN) { let value -> FieldAssignNode = node; return expr_root_name(value.obj) == "self" || expr_root_name(value.value) == "self"; }
    if (base.type == NODE_INDEX_ASSIGN) { let value -> IndexAssignNode = node; return expr_root_name(value.target) == "self" || expr_root_name(value.value) == "self"; }
    if (base.type == NODE_PTR_ASSIGN) { let value -> PtrAssignNode = node; return expr_root_name(value.pointer) == "self" || expr_root_name(value.value) == "self"; }
    if (base.type == NODE_POSTFIX) { let value -> PostfixOpNode = node; return expr_root_name(value.node) == "self"; }
    if (base.type == NODE_REF) { let value -> RefNode = node; return expr_root_name(value.node) == "self"; }
    if (base.type == NODE_VAR_DECL) { let value -> VarDeclareNode = node; return expr_root_name(value.value) == "self"; }
    if (base.type == NODE_VAR_ASSIGN) { let value -> VarAssignNode = node; return expr_root_name(value.value) == "self"; }
    if (base.type == NODE_CALL) {
        let call -> CallNode = node;
        let callee -> BaseNode = call.callee;
        if (callee is !null && callee.type == NODE_FIELD_ACCESS) { let field -> FieldAccessNode = call.callee; if (expr_root_name(field.obj) == "self") { return true; } }
        let i -> Int = 0;
        while (call.args is !null && i < call.args.length()) { let arg -> ArgNode = call.args[i]; if (expr_root_name(arg.val) == "self") { return true; } i += 1; }
    }
    if (base.type == NODE_FUNC_DEF) { let value -> FunctionDefNode = node; return method_mutates_self(value.body); }
    if (base.type == NODE_BLOCK) {
        let block -> BlockNode = node;
        let i -> Int = 0;
        while (block.stmts is !null && i < block.stmts.length()) { if (method_mutates_self(block.stmts[i])) { return true; } i += 1; }
    }
    if (base.type == NODE_IF) { let value -> IfNode = node; return method_mutates_self(value.body) || method_mutates_self(value.else_body); }
    if (base.type == NODE_WHILE) { let value -> WhileNode = node; return method_mutates_self(value.body); }
    if (base.type == NODE_FOR) { let value -> ForNode = node; return method_mutates_self(value.init) || method_mutates_self(value.step) || method_mutates_self(value.body); }
    if (base.type == NODE_CATCH) { let value -> CatchNode = node; return method_mutates_self(value.stmt) || method_mutates_self(value.body); }
    return false;
}

func check_duplicate_params(params -> Vector(Struct), owner -> String, pos -> Position) -> Bool {
    let seen -> Dict = Dict(8);
    let i -> Int = 0;
    while (params is !null && i < params.length()) {
        let param -> ParamNode = params[i];
        let name -> String = param.name_tok.value;
        if (seen.contains_key(name)) { throw_name_error(param.pos, "Duplicate parameter '" + name + "' in " + owner); return false; }
        seen.put(name, StringConstant(id=0, value=name));
        i += 1;
    }
    return true;
}

func same_method_signature(parent -> FuncInfo, child -> FuncInfo) -> Bool {
    if (parent is null || child is null || parent.ret_type != child.ret_type) { return false; }
    let parent_len -> Int = 0; if (parent.arg_types is !null) { parent_len = parent.arg_types.length(); }
    let child_len -> Int = 0; if (child.arg_types is !null) { child_len = child.arg_types.length(); }
    if (parent_len != child_len) { return false; }
    let i -> Int = 1;
    while (i < parent_len) { let a -> TypeListNode = parent.arg_types[i]; let b -> TypeListNode = child.arg_types[i]; if (a.type != b.type) { return false; } i += 1; }
    return true;
}

func add_interface_type(c -> Compiler, list -> Vector(Struct), type_id -> Int, pos -> Position) -> Bool {
    let info -> StructInfo = c.struct_id_map.get("" + type_id);
    if (info is null || !info.is_interface) {
        throw_type_error(pos, "Type " + get_type_name(c, type_id) + " is not an interface.");
        return false;
    }
    let i -> Int = 0;
    while (i < list.length()) {
        let item -> TypeListNode = list[i];
        if (item.type == type_id) { return true; }
        i++;
    }
    list.append(TypeListNode(type=type_id));
    return true;
}

func add_interface(c -> Compiler, list -> Vector(Struct), node -> Struct, pos -> Position) -> Bool {
    return add_interface_type(c, list, resolve_type(c, node), pos);
}

func class_has_interface(c -> Compiler, class_info -> StructInfo, target -> StructInfo) -> Bool {
    let current -> StructInfo = class_info;
    while (current is !null) {
        let i -> Int = 0;
        while (current.interfaces is !null && i < current.interfaces.length()) {
            let item -> TypeListNode = current.interfaces[i];
            if (item.type == target.type_id) { return true; }
            i += 1;
        }
        if (current.parent_id == 0) { break; }
        current = c.struct_id_map.get("" + current.parent_id);
    }
    return false;
}

func is_unsuffix_int_literal(node -> Struct) -> Bool {
    if (node is null) { return false; }
    let base -> BaseNode = node;
    if (base.type != NODE_INT) { return false; }
    let value -> IntNode = node;
    let text -> String = value.tok.value;
    return !text.ends_with("u") && !text.ends_with("U") && !text.ends_with("ul") && !text.ends_with("UL") && !text.ends_with("ull") && !text.ends_with("ULL");
}

func bind_call_args(args -> Vector(Struct), names -> Vector(String), skip -> Int, pos -> Position) -> Vector(Struct) {
    let expected -> Int = 0; if (names is !null) { expected = names.length() - skip; }
    let count -> Int = 0; if (args is !null) { count = args.length(); }
    if (count != expected) { throw_type_error(pos, "Expected " + expected + " arguments, got " + count); return null; }
    let ordered -> Vector(Struct) = [];
    let i -> Int = 0;
    while (i < expected) { ordered.append(null); i += 1; }
    let next_positional -> Int = 0;
    let saw_named -> Bool = false;
    i = 0;
    while (i < count) {
        let arg -> ArgNode = args[i];
        let target -> Int = -1;
        if (arg.name is null || arg.name.length() == 0) {
            if (saw_named) { throw_invalid_syntax(pos, "Positional argument cannot follow a named argument"); return null; }
            target = next_positional;
            next_positional += 1;
        } else {
            saw_named = true;
            let name_index -> Int = skip;
            while (name_index < names.length()) { if (names[name_index] == arg.name) { target = name_index - skip; break; } name_index += 1; }
            if (target < 0) { throw_name_error(pos, "Unknown argument '" + arg.name + "'"); return null; }
        }
        if (target < 0 || target >= expected) { throw_type_error(pos, "Too many arguments"); return null; }
        if (ordered[target] is !null) { let duplicate -> String = names[target + skip]; throw_name_error(pos, "Argument '" + duplicate + "' is specified more than once"); return null; }
        ordered[target] = arg;
        i += 1;
    }
    i = 0;
    while (i < expected) { if (ordered[i] is null) { throw_type_error(pos, "Missing argument '" + names[i + skip] + "'"); return null; } i += 1; }
    return ordered;
}

func reject_named_args(args -> Vector(Struct), pos -> Position, target -> String) -> Bool {
    let i -> Int = 0;
    while (args is !null && i < args.length()) {
        let arg -> ArgNode = args[i];
        if (arg.name is !null && arg.name.length() > 0) { throw_invalid_syntax(pos, "Named arguments are not available when calling " + target); return true; }
        i += 1;
    }
    return false;
}

func convert_to_string(c -> Compiler, res -> CompileResult) -> CompileResult {
    if (res.type == TYPE_STRING) { return res; }

    if (res.type == TYPE_INT8 || res.type == TYPE_INT16 || res.type == TYPE_UINT16) {
        res = promote_to_int(c, res);
    }
    if (res.type == TYPE_UINT32) {
        res = promote_to_long(c, res);
    }
    if (res.type == TYPE_FLOAT32) {
        res = promote_to_float(c, res);
    }
    if (res.type == TYPE_INTSIZE && get_target_pointer_bits() < 64) {
        let widened -> String = next_reg(c);
        c.output_file.write(c.indent + widened + " = sext " + get_size_llvm_type() + " " + res.reg + " to i64\n");
        res = CompileResult(reg=widened, type=TYPE_LONG);
    } else if (res.type == TYPE_INTSIZE) {
        res.type = TYPE_LONG;
    }
    if (res.type == TYPE_UINTSIZE && get_target_pointer_bits() < 64) {
        let widened -> String = next_reg(c);
        c.output_file.write(c.indent + widened + " = zext " + get_size_llvm_type() + " " + res.reg + " to i64\n");
        res = CompileResult(reg=widened, type=TYPE_UINT64);
    }

    if (res.type == TYPE_INT128 || res.type == TYPE_UINT128) {
        let hook_name -> String = "format_int128";
        if (res.type == TYPE_UINT128) {
            hook_name = "format_uint128";
        }
        let format_hook -> String = get_mangled_symbol(c, hook_name, null);
        let result -> String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + format_hook + "(i128 " + res.reg + ")\n");
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    if (res.type == TYPE_UINT64 || res.type == TYPE_UINTSIZE) {
        let format_hook -> String = get_mangled_symbol(c, "format_uint64", null);
        let result -> String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + format_hook + "(i64 " + res.reg + ")\n");
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    if (res.type == TYPE_INT || res.type == TYPE_BYTE) {
        let val_reg -> String = res.reg;
        if (res.type == TYPE_BYTE) {
            val_reg = next_reg(c);
            c.output_file.write(c.indent + val_reg + " = zext i8 " + res.reg + " to i32\n");
        }

        let format_hook -> String = get_mangled_symbol(c, "format_int", null);
        let result -> String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + format_hook + "(i32 " + val_reg + ")\n");
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    if (res.type == TYPE_LONG) {
        let format_hook -> String = get_mangled_symbol(c, "format_long", null);
        let result -> String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + format_hook + "(i64 " + res.reg + ")\n");
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    if (res.type == TYPE_FLOAT) {
        let format_hook -> String = get_mangled_symbol(c, "format_float", null);
        let result -> String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + format_hook + "(double " + res.reg + ")\n");
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    if (res.type == TYPE_BOOL) {
        let true_id -> Int = register_string_constant(c, "true");
        let false_id -> Int = register_string_constant(c, "false");
        let result -> String = next_reg(c);
        c.output_file.write(c.indent + result + " = select i1 " + res.reg + ", %struct.$String* " + get_string_object_ptr(true_id) + ", %struct.$String* " + get_string_object_ptr(false_id) + "\n");
        return CompileResult(reg=result, type=TYPE_STRING);
    }

    if (res.type == TYPE_CHAR) {
        let format_hook -> String = get_mangled_symbol(c, "utf8_encode_char", null);
        let result -> String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + format_hook + "(i32 " + res.reg + ")\n");
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    // fallback for null uses an immortal string literal and requires no allocation.
    let null_id -> Int = register_string_constant(c, "null");
    return CompileResult(reg=get_string_object_ptr(null_id), type=TYPE_STRING);
}

func pre_register_structs(c -> Compiler, node -> Struct) -> Void {
    let block -> BlockNode = node;
    let stmts -> Vector(Struct) = block.stmts;
    let len -> Int = 0;
    if (stmts is !null) { len = stmts.length(); }
    let i -> Int = 0;
    
    while (i < len) {
        let base -> BaseNode = stmts[i];
        if (base.type == NODE_STRUCT_DEF) {
            let n -> StructDefNode = stmts[i];
            let raw_name -> String = n.name_tok.value;
            let s_name -> String = c.current_package_prefix + raw_name;

            if (n.type_params is !null && n.type_params.length() > 0) {
                if (c.generic_structs.get(s_name) is !null || c.struct_table.get(s_name) is !null) {
                    throw_name_error(n.pos, "Type '" + s_name + "' is already defined");
                    i += 1;
                    continue;
                }
                c.generic_structs.put(s_name, GenericTemplate(name=s_name, node=n, type_params=n.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                i += 1;
                continue;
            }

            // for dict.wl
            let sys_anns -> SystemAnnResult = consume_annotations(n.annotations, raw_name);
            if ((sys_anns.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
                if (c.current_package_prefix != "dict." && c.current_package_prefix != "") {
                    throw_internal_compiler_error(n.pos, "@CompilerIntrinsic is restricted to compiler internal libraries.");
                    return; 
                }

                if (raw_name == "Variant") {
                    let intrinsic_info -> StructInfo = c.struct_table.get("$Variant");
                    c.struct_table.put(s_name, intrinsic_info); 
                    i += 1;
                    continue; 
                } else {
                    throw_internal_compiler_error(n.pos, "Unknown intrinsic struct '" + raw_name + "'.");
                    return;
                }
            }
            if (c.struct_table.get(s_name) is !null || c.generic_structs.get(s_name) is !null) {
                throw_name_error(n.pos, "Type '" + s_name + "' is already defined");
                i += 1;
                continue;
            }

            let new_id -> Int = c.type_counter;
            c.type_counter += 1;
            let info -> StructInfo = StructInfo(
                name=s_name, 
                type_id=new_id, 
                fields=null, 
                llvm_name="%struct." + s_name, 
                init_body=n.body, is_class=false, 
                vtable_name="", 
                parent_id=0, 
                vtable=null,
                ann_flags=sys_anns.ann_flags,
                compiler_link_name=sys_anns.compiler_link_name,
                is_enum=false,
                is_error=false,
                is_interface=false,
                interfaces=null
            );
            c.struct_table.put(s_name, info);
            c.struct_id_map.put("" + new_id, info);
            
        } else if (base.type == NODE_CLASS_DEF) {
            let c_node -> ClassDefNode = stmts[i];
            let raw_name -> String = c_node.name_tok.value;
            let c_name -> String = c.current_package_prefix + raw_name;
            if (c_node.type_params is !null && c_node.type_params.length() > 0) {
                if (c.generic_structs.get(c_name) is !null || (c.struct_table.get(c_name) is !null && c_name != "dict.Dict")) {
                    throw_name_error(c_node.pos, "Type '" + c_name + "' is already defined");
                    i += 1;
                    continue;
                }

                c.generic_structs.put(c_name, GenericTemplate(name=c_name, node=c_node, type_params=c_node.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                i++;
                continue;
            }
            if (c.struct_table.get(c_name) is !null || (c.generic_structs.get(c_name) is !null && c_name != "dict.Dict")) {
                throw_name_error(c_node.pos, "Type '" + c_name + "' is already defined");
                i += 1;
                continue;
            }
            let sys_anns -> SystemAnnResult = consume_annotations(c_node.annotations, raw_name);
            let new_id -> Int = c.type_counter;
            c.type_counter += 1;
            let info -> StructInfo = StructInfo(
                name=c_name, 
                type_id=new_id, 
                fields=null, 
                llvm_name="%class." + c_name, 
                init_body=c_node, 
                is_class=true, 
                vtable_name="@vtable." + c_name, 
                parent_id=0, 
                vtable=null,
                ann_flags=sys_anns.ann_flags,
                compiler_link_name=sys_anns.compiler_link_name,
                is_enum=false,
                is_error=false,
                is_interface=false,
                interfaces=c_node.interfaces
            );
            c.struct_table.put(c_name, info);
            c.struct_id_map.put("" + new_id, info);
        } else if (base.type == NODE_INTERFACE_DEF) {
            let i_node -> InterfaceDefNode = stmts[i];
            let raw_name -> String = i_node.name_tok.value;
            let i_name -> String = c.current_package_prefix + raw_name;
            if (c.struct_table.get(i_name) is !null || c.generic_structs.get(i_name) is !null) {
                throw_name_error(i_node.pos, "Type '" + i_name + "' is already defined");
                i += 1;
                continue;
            }
            if (i_node.type_params is !null && i_node.type_params.length() > 0) {
                c.generic_structs.put(i_name, GenericTemplate(name=i_name, node=i_node, type_params=i_node.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                i++;
                continue;
            }
            let method_names -> Dict = Dict(8);
            let method_index -> Int = 0;
            while (i_node.methods is !null && method_index < i_node.methods.length()) {
                let iface_method -> MethodDefNode = i_node.methods[method_index];
                let method_name -> String = iface_method.name_tok.value;
                if (iface_method.type_params is !null && iface_method.type_params.length() > 0) {
                    throw_type_error(iface_method.pos, "Interface methods cannot declare type parameters.");
                    break;
                }
                if (method_names.contains_key(method_name)) { throw_name_error(iface_method.pos, "method '" + method_name + "' is already declared in interface '" + i_name + "'"); break; }
                method_names.put(method_name, StringConstant(id=0, value=method_name));
                check_duplicate_params(iface_method.params, "interface method '" + method_name + "'", iface_method.pos);
                method_index += 1;
            }
            let sys_anns -> SystemAnnResult = consume_annotations(null, raw_name);
            let new_id -> Int = c.type_counter;
            c.type_counter += 1;
            let info -> StructInfo = StructInfo(
                name=i_name, 
                type_id=new_id, 
                fields=null, 
                llvm_name="{ i8*, i8* }", 
                init_body=null, 
                is_class=false, 
                vtable_name="", 
                parent_id=0, 
                vtable=i_node.methods,
                ann_flags=sys_anns.ann_flags,
                compiler_link_name=sys_anns.compiler_link_name,
                is_enum=false,
                is_error=false,
                is_interface=true,
                interfaces=null
            );
            c.struct_table.put(i_name, info);
            c.struct_id_map.put("" + new_id, info);
        } else if (base.type == NODE_ENUM_DEF) {
            let e_node -> EnumDefNode = stmts[i];
            let raw_name -> String = e_node.name_tok.value;
            let e_name -> String = c.current_package_prefix + raw_name;
            if (c.struct_table.get(e_name) is !null) { throw_name_error(e_node.pos, "Type '" + e_name + "' is already defined"); i += 1; continue; }
            let sys_anns -> SystemAnnResult = consume_annotations(e_node.annotations, raw_name);
            let new_id -> Int = c.type_counter;
            c.type_counter += 1;
            
            let info -> StructInfo = StructInfo(
                name=e_name, 
                type_id=new_id, 
                fields=[], 
                llvm_name="i32", 
                init_body=null, 
                is_class=false, 
                vtable_name="", 
                parent_id=0, 
                vtable=null,
                ann_flags=sys_anns.ann_flags,
                compiler_link_name=sys_anns.compiler_link_name,
                is_enum=true,
                is_error=e_node.is_error || sys_anns.compiler_link_name == "Error",
                is_interface=false,
                interfaces=null
            );
            c.struct_table.put(e_name, info);
            c.struct_id_map.put("" + new_id, info);
            if (info.is_error) {
                c.error_types.append(info);
            }
        }
        i += 1;
    }
}
func pre_register_globals(c -> Compiler, node -> Struct) -> Void {
    let block -> BlockNode = node;
    let stmts -> Vector(Struct) = block.stmts;
    let len -> Int = 0;
    if (stmts is !null) { len = stmts.length(); }
    let i -> Int = 0;
    
    while (i < len) {
        let base -> BaseNode = stmts[i];
        if (base.type == NODE_VAR_DECL) {
            let var_decl -> VarDeclareNode = stmts[i];
            let var_name -> String = var_decl.name_tok.value;
            let full_var_name -> String = var_name;
            if (c.current_package_prefix != "") {
                full_var_name = c.current_package_prefix + var_name;
            }
            if (c.global_symbol_table.get(full_var_name) is !null) {
                throw_name_error(var_decl.pos, "Global '" + full_var_name + "' is already defined");
                i += 1;
                continue;
            }
            // keep the declared type visible while module imports are bound
            let declared_type -> Int = resolve_type(c, var_decl.type_node);
            c.global_symbol_table.put(full_var_name, SymbolInfo(reg="poison", type=declared_type, origin_type=declared_type, is_const=var_decl.is_const));
        }
        i += 1;
    }
}
func pre_register_funcs(c -> Compiler, node -> Struct) -> Void {
    let block -> BlockNode = node;
    let stmts -> Vector(Struct) = block.stmts;
    let len -> Int = 0;
    if (stmts is !null) { len = stmts.length(); }
    let i -> Int = 0;
    
    while (i < len) {
        let base -> BaseNode = stmts[i];
        if (base.type == NODE_FUNC_DEF) {
            let f_node -> FunctionDefNode = stmts[i];
            let raw_name -> String = f_node.name_tok.value;

            if (f_node.type_params is !null && f_node.type_params.length() > 0) {
                let template_name -> String = c.current_package_prefix + raw_name;
                if (c.generic_funcs.get(template_name) is !null || c.func_table.get(template_name) is !null) {
                    throw_name_error(f_node.pos, "Function '" + template_name + "' is already defined.");
                    return;
                }
                c.generic_funcs.put(template_name, GenericTemplate(name=template_name, node=f_node, type_params=f_node.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                i += 1;
                continue;
            }
            
            let ret_type_id -> Int = resolve_type(c, f_node.ret_type_tok);
            if (ret_type_id == TYPE_AUTO) {
                throw_type_error(f_node.pos, "Auto return type deduction is not supported yet.");
                return;
            }
            let arg_types -> Vector(Struct) = [];
            let arg_names -> Vector(String) = [];
            
            let params -> Vector(Struct) = f_node.params;
            if (!check_duplicate_params(params, "function '" + raw_name + "'", f_node.pos)) { return; }
            let p_len -> Int = 0; if (params is !null) { p_len = params.length(); }
            let p_idx -> Int = 0;
            
            while (p_idx < p_len) {
                let p -> ParamNode = params[p_idx];
                let p_id -> Int = resolve_type(c, p.type_tok);
                if (p_id == TYPE_AUTO) {
                    throw_type_error(p.pos, "Auto cannot be used in function parameters.");
                    return;
                }
                arg_types.append(TypeListNode(type=p_id));
                arg_names.append(p.name_tok.value);
                p_idx += 1;
            }

            if (raw_name == "main") {
                let valid_main -> Bool = ret_type_id == TYPE_INT && p_len == 0;
                if (ret_type_id == TYPE_INT && p_len == 2) {
                    let first_arg -> TypeListNode = arg_types[0];
                    let second_arg -> TypeListNode = arg_types[1];
                    let pointer_base -> SymbolInfo = c.ptr_base_map.get("" + second_arg.type);
                    if (first_arg.type == TYPE_INT && pointer_base is !null && pointer_base.type == TYPE_STRING) { valid_main = true; }
                }
                if (!valid_main) { throw_type_error(f_node.pos, "function 'main' must be 'func main() -> Int' or 'func main(argc -> Int, ptr argv -> String) -> Int'"); return; }
            }

            let sys_anns -> SystemAnnResult = consume_annotations(f_node.annotations, raw_name);
            if ((sys_anns.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
                if ((raw_name != "size_of" && raw_name != "align_of") || sys_anns.intrinsic_name != raw_name) {
                    throw_internal_compiler_error(f_node.pos, "Unknown intrinsic function '" + sys_anns.intrinsic_name + "'.");
                    return;
                }
                if (p_len != 0 || ret_type_id != TYPE_UINTSIZE) {
                    throw_internal_compiler_error(f_node.pos, "Intrinsic '" + raw_name + "' must be declared as func " + raw_name + "() -> UIntSize.");
                    return;
                }
            }
            let func_key -> String = raw_name;
            if (raw_name != "main") {
                func_key = c.current_package_prefix + raw_name;
            }

            let llvm_func_name -> String = func_key;
            if ((sys_anns.ann_flags & FLAG_ANN_EXPORT) != 0 || raw_name == "main") {
                llvm_func_name = raw_name;
            } else {
                llvm_func_name = mangle_wl_name(c, c.current_package_prefix, raw_name, arg_types);
            }

            if (c.func_table.get(func_key) is !null || c.generic_funcs.get(func_key) is !null) {
                throw_name_error(f_node.pos, "Function '" + func_key + "' is already defined.");
                return;
            }

            let f_info -> FuncInfo = FuncInfo(name=llvm_func_name, base_name=raw_name, ret_type=ret_type_id, arg_types=arg_types, arg_names=arg_names, is_varargs=false, ann_flags=sys_anns.ann_flags, compiler_link_name=sys_anns.compiler_link_name, mutates_self=false);
            c.func_table.put(func_key, f_info);

            if ((sys_anns.ann_flags & FLAG_ANN_COMP_LINK) != 0) {
                c.compiler_link.put(sys_anns.compiler_link_name, func_key);
            }

        } else if (base.type == NODE_CLASS_DEF) {
            let c_node -> ClassDefNode = stmts[i];
            if (c_node.type_params is !null && c_node.type_params.length() > 0) {
                i += 1;
                continue;
            }

            let raw_name -> String = c_node.name_tok.value;
            let c_name -> String = c.current_package_prefix + raw_name;
            let m_vec -> Vector(Struct) = c_node.methods;
            let m_len -> Int = 0; if (m_vec is !null) { m_len = m_vec.length(); }

            let c_info -> StructInfo = c.struct_table.get(c_name);
            let class_type_id -> Int = c_info.type_id;

            let m_idx -> Int = 0;
            while (m_idx < m_len) {
                let m_node -> MethodDefNode = m_vec[m_idx];
                let m_raw_name -> String = method_base_name(c, m_node);

                if (m_node.type_params is !null && m_node.type_params.length() > 0) {
                    let method_key -> String = c_name + "_" + m_raw_name;
                    if (c.generic_methods.get(method_key) is !null || c.func_table.get(method_key) is !null) {
                        throw_name_error(m_node.pos, "Method '" + method_key + "' is already defined.");
                        return;
                    }
                    c.generic_methods.put(method_key, GenericTemplate(name=method_key, node=m_node, type_params=m_node.type_params, prefix=c.current_package_prefix, dir=c.current_dir, visible=c.current_file_visible_prefixes, namespaces=c.current_file_namespaces, types=c.current_file_type_aliases, funcs=c.current_file_func_aliases, globals=c.current_file_global_aliases));
                    m_idx++;
                    continue;
                }

                let ret_id -> Int = resolve_type(c, m_node.return_type);
                if (ret_id == TYPE_AUTO) { 
                    throw_type_error(m_node.pos, "Auto return type deduction is not supported in methods."); 
                    return; 
                }
                if (m_node.name_tok.value == "$type") {
                    let target_id -> Int = ret_id;
                    if (is_fallible_type(c, target_id)) {
                        target_id = get_inner_fallible_type(c, target_id);
                    }
                    if (!is_conversion_target(target_id)) {
                        throw_type_error(m_node.pos, "Conversion target " + get_type_name(c, target_id) + " is not a built-in value type");
                    }
                }
                let arg_types -> Vector(Struct) = [];
                let arg_names -> Vector(String) = ["self"];

                arg_types.append(TypeListNode(type=class_type_id));
                
                let p_vec -> Vector(Struct) = m_node.params;
                if (!check_duplicate_params(p_vec, "method '" + m_raw_name + "'", m_node.pos)) { return; }
                let p_len -> Int = 0; if (p_vec is !null) { p_len = p_vec.length(); }
                let p_idx -> Int = 0;
                while (p_idx < p_len) {
                    let p -> ParamNode = p_vec[p_idx];
                    let p_type -> Int = resolve_type(c, p.type_tok);
                    if (p_type == TYPE_AUTO) { 
                        throw_type_error(p.pos, "Auto cannot be used in method parameters."); 
                        return; 
                    }
                    arg_types.append(TypeListNode(type=p_type));
                    arg_names.append(p.name_tok.value);
                    p_idx += 1;
                }

                let m_key -> String = c_name + "_" + m_raw_name;
                let m_llvm_name -> String = mangle_wl_name(c, c_name + ".", m_raw_name, arg_types);
                
                if (c.func_table.get(m_key) is !null || c.generic_methods.get(m_key) is !null) {
                    if (m_node.name_tok.value == "$type") {
                        let target_id -> Int = ret_id;
                        if (is_fallible_type(c, target_id)) {
                            target_id = get_inner_fallible_type(c, target_id);
                        }
                        throw_name_error(m_node.pos, "class '" + c_name + "' already defines a conversion to " + get_type_name(c, target_id));
                    } else {
                        throw_name_error(m_node.pos, "method '" + m_key + "' is already defined.");
                    }
                    return;
                }

                let f_info -> FuncInfo = FuncInfo(name=m_llvm_name, base_name=m_raw_name, ret_type=ret_id, arg_types=arg_types, arg_names=arg_names, is_varargs=false, mutates_self=method_mutates_self(m_node.body));
                c.func_table.put(m_key, f_info);
                m_idx += 1;
            }
        }
        i += 1;
    }
}

// === SCOPE ===
func enter_scope(c -> Compiler) -> Void {
    let new_scope -> Scope = Scope(table=Dict(32), parent=c.symbol_table, gc_vars=[], depth=c.scope_depth + 1);
    c.symbol_table = new_scope;
    c.scope_depth += 1;
}
func exit_scope(c -> Compiler) -> Void {
    let curr_scope -> Scope = c.symbol_table;

    let gc_vec -> Vector(Struct) = curr_scope.gc_vars;
    let gc_len -> Int = 0; if (gc_vec is !null) { gc_len = gc_vec.length(); }
    let gc_idx -> Int = 0;
    while (gc_idx < gc_len) {
        let curr_gc -> GCTracker = gc_vec[gc_idx];
        emit_drop_slot(c, curr_gc.reg, curr_gc.type);
        gc_idx += 1;
    }

    if (c.symbol_table.parent is !null) {
        c.symbol_table = c.symbol_table.parent;
    }
    c.scope_depth -= 1;
}
func cleanup_all_scopes(c -> Compiler) -> Void {
    let curr -> Scope = c.symbol_table;
    while (curr is !null) { 
        let gc_vec -> Vector(Struct) = curr.gc_vars;
        let gc_len -> Int = 0; if (gc_vec is !null) { gc_len = gc_vec.length(); }
        let gc_idx -> Int = 0;
        while (gc_idx < gc_len) {
            let gc_node -> GCTracker = gc_vec[gc_idx];
            emit_drop_slot(c, gc_node.reg, gc_node.type);
            gc_idx += 1;
        }
        curr = curr.parent;
    }
}

func cleanup_scopes_until(c -> Compiler, target_scope -> Scope) -> Void {
    let curr -> Scope = c.symbol_table;
    while (curr is !null && curr.depth > target_scope.depth) { 
        let gc_vec -> Vector(Struct) = curr.gc_vars;
        let gc_len -> Int = 0; if (gc_vec is !null) { gc_len = gc_vec.length(); }
        let gc_idx -> Int = 0;
        while (gc_idx < gc_len) {
            let gc_node -> GCTracker = gc_vec[gc_idx];
            emit_drop_slot(c, gc_node.reg, gc_node.type);
            gc_idx += 1;
        }
        curr = curr.parent;
    }
}


// TODO: Current RC mechanism fails on strong reference cycles.
// Need to introduce WeakRef or bolt on a cycle collector / tracing GC to clean up the mess at boundaries.
func emit_retain(c -> Compiler, reg -> String, type_id -> Int) -> Void {
    if (!is_ref_type(c, type_id)) { return; }
    
    let s_info -> StructInfo = c.struct_id_map.get("" + type_id);
    if (s_info is !null && s_info.is_interface) {
        let obj_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + obj_ptr + " = extractvalue { i8*, i8* } " + reg + ", 0\n");
        c.output_file.write(c.indent + "call void @__wl_retain(i8* " + obj_ptr + ")\n");
        return;
    }

    // cast to i8* for the runtime function
    let cast_reg -> String = next_reg(c);
    let src_ty -> String = get_llvm_type_str(c, type_id);
    if (src_ty == "i8*") {
        c.output_file.write(c.indent + "call void @__wl_retain(i8* " + reg + ")\n");
        return;
    }
    c.output_file.write(c.indent + cast_reg + " = bitcast " + src_ty + " " + reg + " to i8*\n");
    c.output_file.write(c.indent + "call void @__wl_retain(i8* " + cast_reg + ")\n");
}

func emit_release(c -> Compiler, reg -> String, type_id -> Int) -> Void {
    if (!is_ref_type(c, type_id)) { return; }

    let s_info -> StructInfo = c.struct_id_map.get("" + type_id);
    if (s_info is !null && s_info.is_interface) {
        let obj_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + obj_ptr + " = extractvalue { i8*, i8* } " + reg + ", 0\n");
        c.output_file.write(c.indent + "call void @__wl_release(i8* " + obj_ptr + ")\n");
        return;
    }

    let cast_reg -> String = next_reg(c);
    let src_ty -> String = get_llvm_type_str(c, type_id);
    if (src_ty == "i8*") {
        c.output_file.write(c.indent + "call void @__wl_release(i8* " + reg + ")\n");
        return;
    }
    c.output_file.write(c.indent + cast_reg + " = bitcast " + src_ty + " " + reg + " to i8*\n");
    c.output_file.write(c.indent + "call void @__wl_release(i8* " + cast_reg + ")\n");
}

func emit_retain_value(c -> Compiler, reg -> String, type_id -> Int) -> Void {
    if (is_ref_type(c, type_id)) {
        emit_retain(c, reg, type_id);
        return;
    }
    if (is_fallible_type(c, type_id) && needs_drop(c, type_id)) {
        let llvm_ty -> String = get_llvm_type_str(c, type_id);
        let slot -> String = next_reg(c);
        c.output_file.write(c.indent + slot + " = alloca " + llvm_ty + "\n");
        c.output_file.write(c.indent + "store " + llvm_ty + " " + reg + ", " + llvm_ty + "* " + slot + "\n");
        emit_retain_slot(c, slot, type_id);
    }
}

func emit_drop_value(c -> Compiler, reg -> String, type_id -> Int) -> Void {
    if (is_ref_type(c, type_id)) {
        emit_release(c, reg, type_id);
        return;
    }
    if (is_fallible_type(c, type_id) && needs_drop(c, type_id)) {
        let llvm_ty -> String = get_llvm_type_str(c, type_id);
        let slot -> String = next_reg(c);
        c.output_file.write(c.indent + slot + " = alloca " + llvm_ty + "\n");
        c.output_file.write(c.indent + "store " + llvm_ty + " " + reg + ", " + llvm_ty + "* " + slot + "\n");
        emit_drop_slot(c, slot, type_id);
    }
}

func emit_release_owned(c -> Compiler, value -> CompileResult) -> Void {
    if (value is null || !value.owns_ref) { return; }
    if (is_void_ptr(c, value.type) && is_ref_type(c, value.origin_type)) {
        c.output_file.write(c.indent + "call void @__wl_release(i8* " + value.reg + ")\n");
        return;
    }
    emit_drop_value(c, value.reg, value.type);
}

func emit_release_owned_args(c -> Compiler, values -> Vector(Struct)) -> Void {
    let i -> Int = 0;
    while (i < values.length()) {
        let value -> CompileResult = values[i];
        emit_release_owned(c, value);
        i += 1;
    }
}

func emit_alloc_check(c -> Compiler, ptr_reg -> String) -> Void {
    let failed -> String = next_reg(c);
    c.output_file.write(c.indent + failed + " = icmp eq i8* " + ptr_reg + ", null\n");
    let fail_label -> String = next_label(c);
    let ok_label -> String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + failed + ", label %" + fail_label + ", label %" + ok_label + "\n");
    c.output_file.write("\n" + fail_label + ":\n");
    c.output_file.write(c.indent + "call void @__wl_oom()\n");
    c.output_file.write(c.indent + "unreachable\n");
    c.output_file.write("\n" + ok_label + ":\n");
}

func emit_alloc_obj(c -> Compiler, payload_size_reg -> String, type_id_str -> String, dest_llvm_type -> String) -> String {
    let header_size -> Int = 16;
    if (type_id_str == "" + TYPE_STRING) { header_size = 8; }
    let size_ty -> String = get_size_llvm_type();

    let total_size -> String = next_reg(c);
    c.output_file.write(c.indent + total_size + " = add " + size_ty + " " + payload_size_reg + ", " + header_size + "\n");
    
    let raw_mem -> String = next_reg(c);
    let alloc_hook -> String = get_mangled_symbol(c, "memory_alloc", null);
    c.output_file.write(c.indent + raw_mem + " = call i8* @" + alloc_hook + "(" + size_ty + " " + total_size + ")\n");
    emit_alloc_check(c, raw_mem);

    let header_mem -> String = raw_mem;
    if (header_size == 16) {
        let drop_slot -> String = next_reg(c);
        c.output_file.write(c.indent + drop_slot + " = bitcast i8* " + raw_mem + " to i8**\n");
        let drop_fn -> String = next_reg(c);
        c.output_file.write(c.indent + drop_fn + " = bitcast void (i8*)* @__wl_drop." + type_id_str + " to i8*\n");
        c.output_file.write(c.indent + "store i8* " + drop_fn + ", i8** " + drop_slot + "\n");

        header_mem = next_reg(c);
        c.output_file.write(c.indent + header_mem + " = getelementptr inbounds i8, i8* " + raw_mem + ", i32 8\n");
    }
    
    let rc_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + rc_ptr + " = bitcast i8* " + header_mem + " to i32*\n");
    c.output_file.write(c.indent + "store i32 0, i32* " + rc_ptr + "\n");
    
    let type_ptr_i8 -> String = next_reg(c);
    c.output_file.write(c.indent + type_ptr_i8 + " = getelementptr inbounds i8, i8* " + header_mem + ", i32 4\n");
    let type_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + type_ptr + " = bitcast i8* " + type_ptr_i8 + " to i32*\n");
    c.output_file.write(c.indent + "store i32 " + type_id_str + ", i32* " + type_ptr + "\n");
    
    let payload_i8 -> String = next_reg(c);
    c.output_file.write(c.indent + payload_i8 + " = getelementptr inbounds i8, i8* " + header_mem + ", i32 8\n");
    
    if (dest_llvm_type == "i8*") {
        return payload_i8; 
    }
    
    let final_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + final_ptr + " = bitcast i8* " + payload_i8 + " to " + dest_llvm_type + "\n");
    return final_ptr;
}

func emit_alloc_closure(c -> Compiler, type_id -> Int) -> String {
    let closure -> String = emit_alloc_obj(c, "" + closure_payload_size(), "" + TYPE_GENERIC_FUNCTION, "i8*");
    let tag_bytes -> String = next_reg(c);
    let tag_slot -> String = next_reg(c);
    c.output_file.write(c.indent + tag_bytes + " = getelementptr inbounds i8, i8* " + closure + ", i32 -4\n");
    c.output_file.write(c.indent + tag_slot + " = bitcast i8* " + tag_bytes + " to i32*\n");
    c.output_file.write(c.indent + "store i32 " + type_id + ", i32* " + tag_slot + "\n");
    return closure;
}

func erased_struct_compatible(c -> Compiler, actual -> Int, expected -> Int) -> Bool {
    if (actual == expected) { return true; }

    let actual_info -> StructInfo = c.struct_id_map.get("" + actual);
    let expected_info -> StructInfo = c.struct_id_map.get("" + expected);
    if (actual_info is null || expected_info is null || 
        actual_info.is_class || expected_info.is_class || 
        actual_info.is_enum || expected_info.is_enum || 
        actual_info.is_interface || expected_info.is_interface) {
        return false;
    }

    let actual_count -> Int = 0;
    let expected_count -> Int = 0;
    if (actual_info.fields is !null) {
        actual_count = actual_info.fields.length();
    }

    if (expected_info.fields is !null) {
        expected_count = expected_info.fields.length();
    }

    if (expected_count != 1 || expected_count > actual_count) { return false; }

    let index -> Int = 0;
    while (index < expected_count) {
        let actual_field -> FieldInfo = actual_info.fields[index];
        let expected_field -> FieldInfo = expected_info.fields[index];
        if (actual_field.type != expected_field.type) { return false; }
        index += 1;
    }
    return true;
}

func emit_erased_type_check(c -> Compiler, value -> String, expected -> Int, pos -> Position) -> Void {
    let tag_bytes -> String = next_reg(c);
    let tag_slot -> String = next_reg(c);
    let tag -> String = next_reg(c);
    let matches -> String = next_reg(c);
    let success -> String = next_label(c);
    let failure -> String = next_label(c);
    c.output_file.write(c.indent + tag_bytes + " = getelementptr inbounds i8, i8* " + value + ", i32 -4\n");
    c.output_file.write(c.indent + tag_slot + " = bitcast i8* " + tag_bytes + " to i32*\n");
    c.output_file.write(c.indent + tag + " = load i32, i32* " + tag_slot + "\n");
    let helper -> String = "@__wl_erased_accept_" + expected;
    c.erased_checks.put("" + expected, StringConstant(id=expected, value=helper));
    c.output_file.write(c.indent + matches + " = call i1 " + helper + "(i32 " + tag + ")\n");
    c.output_file.write(c.indent + "br i1 " + matches + ", label %" + success + ", label %" + failure + "\n");
    c.output_file.write("\n" + failure + ":\n");
    emit_runtime_error(c, pos, "Erased value has the wrong concrete type");
    c.output_file.write("\n" + success + ":\n");
}

func hoist_allocas(c -> Compiler, node -> Struct) -> Void {
    if (node is null) { return;
    }
    let base -> BaseNode = node;
    if (base.type == NODE_BLOCK) {
        let block -> BlockNode = node;
        let old_scope -> Scope = c.hoist_scope;
        c.hoist_scope = Scope(parent=old_scope, table=Dict(32), gc_vars=[], depth=0);

        let stmts -> Vector(Struct) = block.stmts;
        let len -> Int = 0;
        if (stmts is !null) { len = stmts.length(); }
        let i -> Int = 0;
        while (i < len) {
            hoist_allocas(c, stmts[i]);
            i += 1;
        }

        c.hoist_scope = old_scope;
    } else if (base.type == NODE_IF) {
        let if_n -> IfNode = node;
        hoist_allocas(c, if_n.body);
        hoist_allocas(c, if_n.else_body);
    } else if (base.type == NODE_WHILE) {
        let w_n -> WhileNode = node;
        hoist_allocas(c, w_n.body);
    } else if (base.type == NODE_FOR) {
        let f_n -> ForNode = node;
        hoist_allocas(c, f_n.init);
        hoist_allocas(c, f_n.body);
    } else if (base.type == NODE_CATCH) {
        let c_node -> CatchNode = node;
        let err_reg -> String = next_reg(c);
        c_node.alloc_id = c.alloc_regs.length();
        c.alloc_regs.append(err_reg);
        c.output_file.write(c.indent + err_reg + " = alloca { i64, i32 }\n");
        
        hoist_allocas(c, c_node.stmt);
        hoist_allocas(c, c_node.body);
    } else if (base.type == NODE_VAR_DECL) {
        let v_node -> VarDeclareNode = node;
        if (c.scope_depth > 0) {
            let target_type_id -> Int = resolve_type(c, v_node.type_node);

            if (target_type_id == TYPE_AUTO) {
                target_type_id = get_expr_type(c, v_node.value);
                if (target_type_id == TYPE_POISON) { return; }
                if (target_type_id == 0 || target_type_id == TYPE_AUTO) {
                    throw_type_error(v_node.pos, "Failed to statically infer type for 'Auto'. Please specify type explicitly.");
                    return;
                }
            }

            if (c.hoist_scope is !null) {
                c.hoist_scope.table.put(v_node.name_tok.value, SymbolInfo(reg="", type=target_type_id, origin_type=target_type_id, is_const=v_node.is_const));
            }

            let var_reg -> String = next_reg(c);
            v_node.alloc_id = c.alloc_regs.length();
            c.alloc_regs.append(var_reg);
            
            let llvm_ty_str -> String = get_llvm_type_str(c, target_type_id);
            c.output_file.write(c.indent + var_reg + " = alloca " + llvm_ty_str + "\n");
            if (needs_drop(c, target_type_id)) {
                c.output_file.write(c.indent + "store " + llvm_ty_str + " zeroinitializer, " + llvm_ty_str + "* " + var_reg + "\n");
            }
        }
    }
}

func emit_runtime_error(c -> Compiler, pos -> Position, msg -> String) -> Void {
    let hook_raw_str -> String = get_mangled_symbol(c, "print_bytes", null);
    let hook_int -> String = get_mangled_symbol(c, "print_int", null);

    if (hook_raw_str is !null && hook_int is !null) {
        let header_1 -> String = "RuntimeError: " + msg + "\n    at " + pos.fn + ":";
        let header_1_id -> Int = register_string_constant(c, header_1);
        let header_1_ptr -> String = get_string_ptr(header_1_id, header_1);
        
        let header_2 -> String = ":";
        let header_2_id -> Int = register_string_constant(c, header_2);
        let header_2_ptr -> String = get_string_ptr(header_2_id, header_2);

        let header_3 -> String = "\n\n";
        let header_3_id -> Int = register_string_constant(c, header_3);
        let header_3_ptr -> String = get_string_ptr(header_3_id, header_3);
        
        let ln -> Int = pos.ln + 1;
        let col -> Int = pos.col + 1;
        
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + header_1_ptr + ", i32 " + header_1.length() + ")\n");
        c.output_file.write(c.indent + "call void @" + hook_int + "(i32 " + ln + ")\n");
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + header_2_ptr + ", i32 " + header_2.length() + ")\n");
        c.output_file.write(c.indent + "call void @" + hook_int + "(i32 " + col + ")\n");
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + header_3_ptr + ", i32 " + header_3.length() + ")\n");

        let full_text -> String = pos.text;
        if (c.emit_source_context && full_text.length() > 0) {
            let current_ln -> Int = 0;
            let scan_idx -> Int = 0;
            let len -> Int = full_text.length();
            let line_start_idx -> Int = 0;

            while (scan_idx < len) {
                if (current_ln == pos.ln) { line_start_idx = scan_idx; break; }
                if (full_text[scan_idx] == '\n') { current_ln += 1; }
                scan_idx += 1;
            }

            let line_end_idx -> Int = line_start_idx;
            while (line_end_idx < len) {
                let ch -> Char = full_text[line_end_idx];
                if (ch == '\n' || ch == '\r') { break; }
                line_end_idx += 1;
            }

            let raw_line -> String = full_text.slice(line_start_idx, line_end_idx);
            let code_content -> String = "    " + raw_line + "\n";
        
            let code_id -> Int = register_string_constant(c, code_content);
            let code_ptr -> String = get_string_ptr(code_id, code_content);
            c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + code_ptr + ", i32 " + code_content.length() + ")\n");

            let err_len -> Int = 1;
            let line_len -> Int = raw_line.length();
            if (pos.col < line_len) {
                let ch -> Char = raw_line[pos.col];
                if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_' || (ch >= '0' && ch <= '9')) {
                    let cur -> Int = pos.col + 1;
                    while (cur < line_len) {
                        let c2 -> Char = raw_line[cur];
                        if ((c2 >= 'A' && c2 <= 'Z') || (c2 >= 'a' && c2 <= 'z') || c2 == '_' || (c2 >= '0' && c2 <= '9')) {
                            cur += 1;
                        } else {
                            break;
                        }
                    }
                    err_len = cur - pos.col;
                }
            }

            let arrow_str -> String = "    ";
            let k -> Int = 0;
            while (k < pos.col) {
                arrow_str += " ";
                k += 1;
            }
            let j -> Int = 0;
            while (j < err_len) {
                arrow_str += "^";
                j += 1;
            }
            arrow_str += "\n";
            let arrow_id -> Int = register_string_constant(c, arrow_str);
            let arrow_ptr -> String = get_string_ptr(arrow_id, arrow_str);
            c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + arrow_ptr + ", i32 " + arrow_str.length() + ")\n");
        }
    }

    let exit_hook -> String = get_mangled_symbol(c, "process_exit", pos);
    c.output_file.write(c.indent + "call void @" + exit_hook + "(i32 1)\n");
    c.output_file.write(c.indent + "unreachable\n");
}

func emit_pointer_null_check(c -> Compiler, ptr_reg -> String, type_id -> Int, pos -> Position) -> Void {
    let ptr_ty -> String = get_llvm_type_str(c, type_id);
    let is_null -> String = next_reg(c);
    c.output_file.write(c.indent + is_null + " = icmp eq " + ptr_ty + " " + ptr_reg + ", null\n");
    let fail_label -> String = next_label(c);
    let ok_label -> String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + is_null + ", label %" + fail_label + ", label %" + ok_label + "\n");
    c.output_file.write("\n" + fail_label + ":\n");
    emit_runtime_error(c, pos, "Null pointer dereference");
    c.output_file.write("\n" + ok_label + ":\n");
}

func emit_size_to_int(c -> Compiler, value -> String) -> String {
    let size_ty -> String = get_size_llvm_type();
    if (size_ty == "i32") { return value; }
    let result -> String = next_reg(c);
    c.output_file.write(c.indent + result + " = trunc " + size_ty + " " + value + " to i32\n");
    return result;
}

func emit_int_to_size(c -> Compiler, value -> String, signed -> Bool) -> String {
    let size_ty -> String = get_size_llvm_type();
    if (size_ty == "i32") { return value; }
    let result -> String = next_reg(c);
    let op -> String = "zext";
    if signed { op = "sext"; }
    c.output_file.write(c.indent + result + " = " + op + " i32 " + value + " to " + size_ty + "\n");
    return result;
}


func emit_vector_bounds_check(c -> Compiler, vec_reg -> String, idx_reg -> String, struct_ty -> String, pos -> Position) -> Void {
    let size_ty -> String = get_size_llvm_type();
    let size_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_reg + ", i32 0, i32 0\n");
    let size_val -> String = next_reg(c);
    c.output_file.write(c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");

    let size_index -> String = emit_int_to_size(c, idx_reg, true);

    let cmp_reg -> String = next_reg(c);
    c.output_file.write(c.indent + cmp_reg + " = icmp uge " + size_ty + " " + size_index + ", " + size_val + "\n");

    let fail_label -> String = "bounds_fail_" + c.type_counter;
    let ok_label -> String = "bounds_ok_" + c.type_counter;
    c.type_counter += 1;
    
    c.output_file.write(c.indent + "br i1 " + cmp_reg + ", label %" + fail_label + ", label %" + ok_label + "\n");

    c.output_file.write("\n" + fail_label + ":\n");
    emit_runtime_error(c, pos, "Index out of bounds");

    c.output_file.write("\n" + ok_label + ":\n");
}

func emit_array_bounds_check(c -> Compiler, idx_reg -> String, len_val -> String, pos -> Position) -> Void {
    let cmp1 -> String = next_reg(c);
    c.output_file.write(c.indent + cmp1 + " = icmp slt i32 " + idx_reg + ", 0\n");
    let cmp2 -> String = next_reg(c);
    c.output_file.write(c.indent + cmp2 + " = icmp sge i32 " + idx_reg + ", " + len_val + "\n");
    
    let or1 -> String = next_reg(c);
    c.output_file.write(c.indent + or1 + " = or i1 " + cmp1 + ", " + cmp2 + "\n");
    
    let fail_lbl -> String = "arr_fail_" + c.type_counter;
    let ok_lbl -> String = "arr_ok_" + c.type_counter;
    c.type_counter += 1;

    c.output_file.write(c.indent + "br i1 " + or1 + ", label %" + fail_lbl + ", label %" + ok_lbl + "\n");
    c.output_file.write("\n" + fail_lbl + ":\n");
    emit_runtime_error(c, pos, "Index out of bounds.");
    c.output_file.write("\n" + ok_lbl + ":\n");
}

func emit_slice_bounds_check(c -> Compiler, start_reg -> String, end_reg -> String, len_val -> String, pos -> Position) -> Void {
    let cmp1 -> String = next_reg(c);
    c.output_file.write(c.indent + cmp1 + " = icmp slt i32 " + start_reg + ", 0\n");
    let cmp2 -> String = next_reg(c);
    c.output_file.write(c.indent + cmp2 + " = icmp sgt i32 " + start_reg + ", " + end_reg + "\n");
    let cmp3 -> String = next_reg(c);
    c.output_file.write(c.indent + cmp3 + " = icmp sgt i32 " + end_reg + ", " + len_val + "\n");
    
    let or1 -> String = next_reg(c);
    c.output_file.write(c.indent + or1 + " = or i1 " + cmp1 + ", " + cmp2 + "\n");
    let or2 -> String = next_reg(c);
    c.output_file.write(c.indent + or2 + " = or i1 " + or1 + ", " + cmp3 + "\n");
    
    let fail_lbl -> String = "slice_fail_" + c.type_counter;
    let ok_lbl -> String = "slice_ok_" + c.type_counter;
    c.type_counter += 1;
    
    c.output_file.write(c.indent + "br i1 " + or2 + ", label %" + fail_lbl + ", label %" + ok_lbl + "\n");
    c.output_file.write("\n" + fail_lbl + ":\n");
    emit_runtime_error(c, pos, "Slice boundaries out of range.");
    c.output_file.write("\n" + ok_lbl + ":\n");
}

func emit_slice_parts(c -> Compiler, slice_reg -> String, slice_type -> Int, pos -> Position) -> SliceParts {
    let arr_info -> ArrayInfo = c.array_info_map.get("" + slice_type);
    let elem_ty -> String = get_llvm_type_str(c, arr_info.base_type);
    let slice_ty -> String = arr_info.llvm_name;
    let size_ty -> String = get_size_llvm_type();
    emit_pointer_null_check(c, slice_reg, slice_type, pos);

    let start_slot -> String = next_reg(c);
    c.output_file.write(c.indent + start_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 0\n");
    let start -> String = next_reg(c);
    c.output_file.write(c.indent + start + " = load " + size_ty + ", " + size_ty + "* " + start_slot + "\n");

    let len_slot -> String = next_reg(c);
    c.output_file.write(c.indent + len_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 1\n");
    let length -> String = next_reg(c);
    c.output_file.write(c.indent + length + " = load " + size_ty + ", " + size_ty + "* " + len_slot + "\n");

    let owner_slot -> String = next_reg(c);
    c.output_file.write(c.indent + owner_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 2\n");
    let owner -> String = next_reg(c);
    c.output_file.write(c.indent + owner + " = load i8*, i8** " + owner_slot + "\n");

    let data_slot_slot -> String = next_reg(c);
    c.output_file.write(c.indent + data_slot_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 3\n");
    let data_slot -> String = next_reg(c);
    c.output_file.write(c.indent + data_slot + " = load " + elem_ty + "**, " + elem_ty + "*** " + data_slot_slot + "\n");

    let size_slot_slot -> String = next_reg(c);
    c.output_file.write(c.indent + size_slot_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + slice_reg + ", i32 0, i32 4\n");
    let size_slot -> String = next_reg(c);
    c.output_file.write(c.indent + size_slot + " = load " + size_ty + "*, " + size_ty + "** " + size_slot_slot + "\n");
    let owner_size -> String = next_reg(c);
    c.output_file.write(c.indent + owner_size + " = load " + size_ty + ", " + size_ty + "* " + size_slot + "\n");

    let slice_end -> String = next_reg(c);
    c.output_file.write(c.indent + slice_end + " = add " + size_ty + " " + start + ", " + length + "\n");
    let invalid -> String = next_reg(c);
    c.output_file.write(c.indent + invalid + " = icmp ugt " + size_ty + " " + slice_end + ", " + owner_size + "\n");
    let fail_label -> String = next_label(c);
    let ok_label -> String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + invalid + ", label %" + fail_label + ", label %" + ok_label + "\n");
    c.output_file.write("\n" + fail_label + ":\n");
    emit_runtime_error(c, pos, "Slice backing storage was shortened");
    c.output_file.write("\n" + ok_label + ":\n");

    let data -> String = next_reg(c);
    c.output_file.write(c.indent + data + " = load " + elem_ty + "*, " + elem_ty + "** " + data_slot + "\n");
    return SliceParts(start=start, length=length, owner=owner, data_slot=data_slot, size_slot=size_slot, data=data);
}

func emit_make_slice(c -> Compiler, elem_type -> Int, owner -> String, data_slot -> String, size_slot -> String, start -> String, length -> String) -> CompileResult {
    let slice_type -> Int = get_slice_type_id(c, elem_type);
    let arr_info -> ArrayInfo = c.array_info_map.get("" + slice_type);
    let elem_ty -> String = get_llvm_type_str(c, elem_type);
    let slice_ty -> String = arr_info.llvm_name;
    let size_ty -> String = get_size_llvm_type();

    let size_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr " + slice_ty + ", " + slice_ty + "* null, i32 1\n");
    let size -> String = next_reg(c);
    c.output_file.write(c.indent + size + " = ptrtoint " + slice_ty + "* " + size_ptr + " to " + size_ty + "\n");
    let result -> String = emit_alloc_obj(c, size, "" + slice_type, slice_ty + "*");

    let start_slot -> String = next_reg(c);
    c.output_file.write(c.indent + start_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 0\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + start + ", " + size_ty + "* " + start_slot + "\n");
    let len_slot -> String = next_reg(c);
    c.output_file.write(c.indent + len_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + length + ", " + size_ty + "* " + len_slot + "\n");
    let owner_slot -> String = next_reg(c);
    c.output_file.write(c.indent + owner_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 2\n");
    c.output_file.write(c.indent + "store i8* " + owner + ", i8** " + owner_slot + "\n");
    let data_slot_slot -> String = next_reg(c);
    c.output_file.write(c.indent + data_slot_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 3\n");
    c.output_file.write(c.indent + "store " + elem_ty + "** " + data_slot + ", " + elem_ty + "*** " + data_slot_slot + "\n");
    let size_slot_slot -> String = next_reg(c);
    c.output_file.write(c.indent + size_slot_slot + " = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* " + result + ", i32 0, i32 4\n");
    c.output_file.write(c.indent + "store " + size_ty + "* " + size_slot + ", " + size_ty + "** " + size_slot_slot + "\n");
    c.output_file.write(c.indent + "call void @__wl_retain(i8* " + owner + ")\n");
    return CompileResult(reg=result, type=slice_type);
}

func emit_slice_copy(c -> Compiler, elem_type -> Int, source -> String, start_i32 -> String, length_i32 -> String, pos -> Position) -> CompileResult {
    let elem_ty -> String = get_llvm_type_str(c, elem_type);
    let vec_type -> Int = get_vector_type_id(c, elem_type);
    let vec_ty -> String = get_vector_llvm_type(c, elem_type);
    let size_ty -> String = get_size_llvm_type();

    let vec_size_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + vec_size_ptr + " = getelementptr " + vec_ty + ", " + vec_ty + "* null, i32 1\n");
    let vec_size -> String = next_reg(c);
    c.output_file.write(c.indent + vec_size + " = ptrtoint " + vec_ty + "* " + vec_size_ptr + " to " + size_ty + "\n");
    let owner_ptr -> String = emit_alloc_obj(c, vec_size, "" + vec_type, vec_ty + "*");

    let length -> String = emit_int_to_size(c, length_i32, false);
    let start -> String = emit_int_to_size(c, start_i32, false);
    let is_empty -> String = next_reg(c);
    c.output_file.write(c.indent + is_empty + " = icmp eq " + size_ty + " " + length + ", 0\n");
    let alloc_count -> String = next_reg(c);
    c.output_file.write(c.indent + alloc_count + " = select i1 " + is_empty + ", " + size_ty + " 1, " + size_ty + " " + length + "\n");

    let elem_size -> Int = get_type_size_bytes(c, elem_type);
    let max_capacity -> Long = vector_capacity_limit(elem_size);
    let overflow -> String = next_reg(c);
    c.output_file.write(c.indent + overflow + " = icmp ugt " + size_ty + " " + alloc_count + ", " + max_capacity + "\n");
    let fail_label -> String = next_label(c);
    let alloc_label -> String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + overflow + ", label %" + fail_label + ", label %" + alloc_label + "\n");
    c.output_file.write("\n" + fail_label + ":\n");
    c.output_file.write(c.indent + "call void @__wl_oom()\n");
    c.output_file.write(c.indent + "unreachable\n");
    c.output_file.write("\n" + alloc_label + ":\n");

    let bytes -> String = next_reg(c);
    c.output_file.write(c.indent + bytes + " = mul " + size_ty + " " + alloc_count + ", " + elem_size + "\n");
    let alloc_hook -> String = get_mangled_symbol(c, "memory_alloc", pos);
    let raw_data -> String = next_reg(c);
    c.output_file.write(c.indent + raw_data + " = call i8* @" + alloc_hook + "(" + size_ty + " " + bytes + ")\n");
    emit_alloc_check(c, raw_data);
    let data -> String = next_reg(c);
    c.output_file.write(c.indent + data + " = bitcast i8* " + raw_data + " to " + elem_ty + "*\n");

    let size_slot -> String = next_reg(c);
    c.output_file.write(c.indent + size_slot + " = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* " + owner_ptr + ", i32 0, i32 0\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + length + ", " + size_ty + "* " + size_slot + "\n");
    let cap_slot -> String = next_reg(c);
    c.output_file.write(c.indent + cap_slot + " = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* " + owner_ptr + ", i32 0, i32 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + length + ", " + size_ty + "* " + cap_slot + "\n");
    let data_slot -> String = next_reg(c);
    c.output_file.write(c.indent + data_slot + " = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* " + owner_ptr + ", i32 0, i32 2\n");
    c.output_file.write(c.indent + "store " + elem_ty + "* " + data + ", " + elem_ty + "** " + data_slot + "\n");

    let index -> String = next_reg(c);
    c.output_file.write(c.indent + index + " = alloca " + size_ty + "\n");
    c.output_file.write(c.indent + "store " + size_ty + " 0, " + size_ty + "* " + index + "\n");
    let loop_cond -> String = next_label(c);
    let loop_body -> String = next_label(c);
    let loop_end -> String = next_label(c);
    c.output_file.write(c.indent + "br label %" + loop_cond + "\n");
    c.output_file.write("\n" + loop_cond + ":\n");
    let i -> String = next_reg(c);
    c.output_file.write(c.indent + i + " = load " + size_ty + ", " + size_ty + "* " + index + "\n");
    let more -> String = next_reg(c);
    c.output_file.write(c.indent + more + " = icmp ult " + size_ty + " " + i + ", " + length + "\n");
    c.output_file.write(c.indent + "br i1 " + more + ", label %" + loop_body + ", label %" + loop_end + "\n");
    c.output_file.write("\n" + loop_body + ":\n");
    let source_index -> String = next_reg(c);
    c.output_file.write(c.indent + source_index + " = add " + size_ty + " " + start + ", " + i + "\n");
    let source_slot -> String = next_reg(c);
    c.output_file.write(c.indent + source_slot + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + source + ", " + size_ty + " " + source_index + "\n");
    let value -> String = next_reg(c);
    c.output_file.write(c.indent + value + " = load " + elem_ty + ", " + elem_ty + "* " + source_slot + "\n");
    let dest_slot -> String = next_reg(c);
    c.output_file.write(c.indent + dest_slot + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + data + ", " + size_ty + " " + i + "\n");
    c.output_file.write(c.indent + "store " + elem_ty + " " + value + ", " + elem_ty + "* " + dest_slot + "\n");
    if (needs_drop(c, elem_type)) { emit_retain_slot(c, dest_slot, elem_type); }
    let next -> String = next_reg(c);
    c.output_file.write(c.indent + next + " = add " + size_ty + " " + i + ", 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + next + ", " + size_ty + "* " + index + "\n");
    c.output_file.write(c.indent + "br label %" + loop_cond + "\n");
    c.output_file.write("\n" + loop_end + ":\n");

    let owner -> String = next_reg(c);
    c.output_file.write(c.indent + owner + " = bitcast " + vec_ty + "* " + owner_ptr + " to i8*\n");
    return emit_make_slice(c, elem_type, owner, data_slot, size_slot, "0", length);
}

func emit_drop_slot(c -> Compiler, ptr_reg -> String, type_id -> Int) -> Void {
    if (is_fallible_type(c, type_id)) {
        let inner_type -> Int = get_inner_fallible_type(c, type_id);
        if (!needs_drop(c, inner_type)) { return; }

        let fallible_ty -> String = get_llvm_type_str(c, type_id);
        let err_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + err_ptr + " = getelementptr inbounds " + fallible_ty + ", " + fallible_ty + "* " + ptr_reg + ", i32 0, i32 0\n");
        let is_err -> String = next_reg(c);
        c.output_file.write(c.indent + is_err + " = load i1, i1* " + err_ptr + "\n");
        let drop_label -> String = next_label(c);
        let done_label -> String = next_label(c);
        c.output_file.write(c.indent + "br i1 " + is_err + ", label %" + done_label + ", label %" + drop_label + "\n");
        c.output_file.write("\n" + drop_label + ":\n");
        let value_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + value_ptr + " = getelementptr inbounds " + fallible_ty + ", " + fallible_ty + "* " + ptr_reg + ", i32 0, i32 2\n");
        emit_drop_slot(c, value_ptr, inner_type);
        c.output_file.write(c.indent + "br label %" + done_label + "\n");
        c.output_file.write("\n" + done_label + ":\n");
        return;
    }

    let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
    if (arr_info is !null && arr_info.size >= 0) {
        let i -> Int = 0;
        while (i < arr_info.size) {
            let elem_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + elem_ptr + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + ptr_reg + ", i32 0, i32 " + i + "\n");
            emit_drop_slot(c, elem_ptr, arr_info.base_type);
            i += 1;
        }
        return;
    }

    if (!is_ref_type(c, type_id)) { return; }
    let llvm_ty -> String = get_llvm_type_str(c, type_id);
    let value -> String = next_reg(c);
    c.output_file.write(c.indent + value + " = load " + llvm_ty + ", " + llvm_ty + "* " + ptr_reg + "\n");
    emit_release(c, value, type_id);
}

func emit_retain_slot(c -> Compiler, ptr_reg -> String, type_id -> Int) -> Void {
    if (is_fallible_type(c, type_id)) {
        let inner_type -> Int = get_inner_fallible_type(c, type_id);
        if (!needs_drop(c, inner_type)) { return; }

        let fallible_ty -> String = get_llvm_type_str(c, type_id);
        let err_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + err_ptr + " = getelementptr inbounds " + fallible_ty + ", " + fallible_ty + "* " + ptr_reg + ", i32 0, i32 0\n");
        let is_err -> String = next_reg(c);
        c.output_file.write(c.indent + is_err + " = load i1, i1* " + err_ptr + "\n");
        let retain_label -> String = next_label(c);
        let done_label -> String = next_label(c);
        c.output_file.write(c.indent + "br i1 " + is_err + ", label %" + done_label + ", label %" + retain_label + "\n");
        c.output_file.write("\n" + retain_label + ":\n");
        let value_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + value_ptr + " = getelementptr inbounds " + fallible_ty + ", " + fallible_ty + "* " + ptr_reg + ", i32 0, i32 2\n");
        emit_retain_slot(c, value_ptr, inner_type);
        c.output_file.write(c.indent + "br label %" + done_label + "\n");
        c.output_file.write("\n" + done_label + ":\n");
        return;
    }

    let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
    if (arr_info is !null && arr_info.size >= 0) {
        let i -> Int = 0;
        while (i < arr_info.size) {
            let elem_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + elem_ptr + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + ptr_reg + ", i32 0, i32 " + i + "\n");
            emit_retain_slot(c, elem_ptr, arr_info.base_type);
            i += 1;
        }
        return;
    }

    if (!is_ref_type(c, type_id)) { return; }
    let llvm_ty -> String = get_llvm_type_str(c, type_id);
    let value -> String = next_reg(c);
    c.output_file.write(c.indent + value + " = load " + llvm_ty + ", " + llvm_ty + "* " + ptr_reg + "\n");
    emit_retain(c, value, type_id);
}

func emit_type_drop(c -> Compiler, type_id -> Int) -> Void {
    let free_hook -> String = get_mangled_symbol(c, "memory_free", null);
    c.output_file.write("define internal void @__wl_drop." + type_id + "(i8* %ptr) {\n");
    c.output_file.write("entry:\n");

    if (type_id == TYPE_GENERIC_FUNCTION) {
        c.output_file.write("  %env.addr = getelementptr inbounds i8, i8* %ptr, i32 " + closure_env_offset() + "\n");
        c.output_file.write("  %env.slot = bitcast i8* %env.addr to i8**\n");
        c.output_file.write("  %env = load i8*, i8** %env.slot\n");
        c.output_file.write("  call void @__wl_release(i8* %env)\n");
        c.output_file.write("  ret void\n");
        c.output_file.write("}\n\n");
        return;
    }

    let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
    if (arr_info is !null && arr_info.size == -1) {
        let slice_ty -> String = arr_info.llvm_name;
        c.output_file.write("  %slice = bitcast i8* %ptr to " + slice_ty + "*\n");
        c.output_file.write("  %owner.slot = getelementptr inbounds " + slice_ty + ", " + slice_ty + "* %slice, i32 0, i32 2\n");
        c.output_file.write("  %owner = load i8*, i8** %owner.slot\n");
        c.output_file.write("  call void @__wl_release(i8* %owner)\n");
        c.output_file.write("  ret void\n");
        c.output_file.write("}\n\n");
        return;
    }

    let variant_info -> StructInfo = c.struct_table.get("$Variant");
    if (variant_info is !null && type_id == variant_info.type_id) {
        c.output_file.write("  %box = bitcast i8* %ptr to %struct.$Variant*\n");
        c.output_file.write("  %tag.slot = getelementptr inbounds %struct.$Variant, %struct.$Variant* %box, i32 0, i32 0\n");
        c.output_file.write("  %tag = load i64, i64* %tag.slot\n");
        c.output_file.write("  switch i64 %tag, label %done [\n");

        let ref_cases -> String = "";
        let seen_refs -> Dict = Dict(64);
        let ref_id -> Int = 1;
        while (ref_id < c.type_counter) {
            if (is_ref_type(c, ref_id) && ref_id != type_id) {
                ref_cases = append_variant_ref_case(c, ref_cases, seen_refs, ref_id);
            }
            ref_id += 1;
        }
        c.output_file.write(ref_cases);
        c.output_file.write("  ]\n");
        c.output_file.write("release:\n");
        c.output_file.write("  %payload.slot = getelementptr inbounds %struct.$Variant, %struct.$Variant* %box, i32 0, i32 1\n");
        c.output_file.write("  %payload = load i64, i64* %payload.slot\n");
        c.output_file.write("  %value = inttoptr i64 %payload to i8*\n");
        c.output_file.write("  call void @__wl_release(i8* %value)\n");
        c.output_file.write("  br label %done\n");
        c.output_file.write("done:\n");
        c.output_file.write("  ret void\n");
        c.output_file.write("}\n\n");
        return;
    }

    let vec_info -> SymbolInfo = c.vector_base_map.get("" + type_id);
    if (vec_info is !null) {
        let elem_type -> Int = vec_info.type;
        let elem_ty -> String = get_llvm_type_str(c, elem_type);
        let vec_ty -> String = get_vector_llvm_type(c, elem_type);
        let size_ty -> String = get_size_llvm_type();
        c.output_file.write("  %vec = bitcast i8* %ptr to " + vec_ty + "*\n");
        c.output_file.write("  %size.slot = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* %vec, i32 0, i32 0\n");
        c.output_file.write("  %size = load " + size_ty + ", " + size_ty + "* %size.slot\n");
        c.output_file.write("  %data.slot = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* %vec, i32 0, i32 2\n");
        c.output_file.write("  %data = load " + elem_ty + "*, " + elem_ty + "** %data.slot\n");

        if (needs_drop(c, elem_type)) {
            c.output_file.write("  %index = alloca " + size_ty + "\n");
            c.output_file.write("  store " + size_ty + " 0, " + size_ty + "* %index\n");
            c.output_file.write("  br label %loop.cond\n");
            c.output_file.write("loop.cond:\n");
            c.output_file.write("  %i = load " + size_ty + ", " + size_ty + "* %index\n");
            c.output_file.write("  %more = icmp ult " + size_ty + " %i, %size\n");
            c.output_file.write("  br i1 %more, label %loop.body, label %loop.end\n");
            c.output_file.write("loop.body:\n");
            c.output_file.write("  %slot = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* %data, " + size_ty + " %i\n");
            emit_drop_slot(c, "%slot", elem_type);
            c.output_file.write("  %next = add " + size_ty + " %i, 1\n");
            c.output_file.write("  store " + size_ty + " %next, " + size_ty + "* %index\n");
            c.output_file.write("  br label %loop.cond\n");
            c.output_file.write("loop.end:\n");
        }

        c.output_file.write("  %data.raw = bitcast " + elem_ty + "* %data to i8*\n");
        c.output_file.write("  call void @" + free_hook + "(i8* %data.raw)\n");
        c.output_file.write("  ret void\n");
        c.output_file.write("}\n\n");
        return;
    }

    let s_info -> StructInfo = c.struct_id_map.get("" + type_id);
    if (s_info is !null) {
        if (s_info.is_class) {
            let methods -> Vector(Struct) = s_info.vtable;
            let method_len -> Int = 0; if (methods is !null) { method_len = methods.length(); }
            let method_i -> Int = 0;
            let deinit -> FuncInfo = null;
            while (method_i < method_len) {
                let method_info -> FuncInfo = methods[method_i];
                if (method_info.base_name == "$deinit") {
                    deinit = method_info;
                    break;
                }
                method_i += 1;
            }
            if (deinit is !null) {
                let self_arg -> TypeListNode = deinit.arg_types[0];
                let self_ty -> String = get_llvm_type_str(c, self_arg.type);
                let deinit_ret -> String = get_llvm_type_str(c, deinit.ret_type);
                c.output_file.write("  %self = bitcast i8* %ptr to " + self_ty + "\n");
                c.output_file.write("  call " + deinit_ret + " @" + deinit.name + "(" + self_ty + " %self)\n");
            }
        }

        c.output_file.write("  %object = bitcast i8* %ptr to " + s_info.llvm_name + "*\n");
        let fields -> Vector(Struct) = s_info.fields;
        let field_len -> Int = 0; if (fields is !null) { field_len = fields.length(); }
        let field_i -> Int = 0;
        while (field_i < field_len) {
            let field -> FieldInfo = fields[field_i];
            if (field.name != "_vptr" && needs_drop(c, field.type)) {
                let field_ptr -> String = next_reg(c);
                c.output_file.write(c.indent + field_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* %object, i32 0, i32 " + field.offset + "\n");
                emit_drop_slot(c, field_ptr, field.type);
            }
            field_i += 1;
        }
    }

    c.output_file.write("  ret void\n");
    c.output_file.write("}\n\n");
}

func emit_dict_key_helpers(c -> Compiler) -> Void {
    c.output_file.write("define internal i32 @__wl_dict_hash_bits(i64 %tag, i64 %low, i64 %high) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %mixed.0 = xor i64 %tag, %low\n");
    c.output_file.write("  %mixed.1 = xor i64 %mixed.0, %high\n");
    c.output_file.write("  %shifted.0 = lshr i64 %mixed.1, 30\n");
    c.output_file.write("  %mixed.2 = xor i64 %mixed.1, %shifted.0\n");
    c.output_file.write("  %mixed.3 = mul i64 %mixed.2, -4658895280553007687\n");
    c.output_file.write("  %shifted.1 = lshr i64 %mixed.3, 27\n");
    c.output_file.write("  %mixed.4 = xor i64 %mixed.3, %shifted.1\n");
    c.output_file.write("  %mixed.5 = mul i64 %mixed.4, -7723592293110705685\n");
    c.output_file.write("  %shifted.2 = lshr i64 %mixed.5, 31\n");
    c.output_file.write("  %mixed.6 = xor i64 %mixed.5, %shifted.2\n");
    c.output_file.write("  %raw = trunc i64 %mixed.6 to i32\n");
    c.output_file.write("  %positive = and i32 %raw, 2147483647\n");
    c.output_file.write("  %small = icmp ult i32 %positive, 2\n");
    c.output_file.write("  %adjusted = add i32 %positive, 2\n");
    c.output_file.write("  %result = select i1 %small, i32 %adjusted, i32 %positive\n");
    c.output_file.write("  ret i32 %result\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define internal i1 @__wl_dict_string_equal(%struct.$String* %left, %struct.$String* %right) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %same = icmp eq %struct.$String* %left, %right\n");
    c.output_file.write("  br i1 %same, label %equal, label %check.null\n");
    c.output_file.write("check.null:\n");
    c.output_file.write("  %left.null = icmp eq %struct.$String* %left, null\n");
    c.output_file.write("  %right.null = icmp eq %struct.$String* %right, null\n");
    c.output_file.write("  %has.null = or i1 %left.null, %right.null\n");
    c.output_file.write("  br i1 %has.null, label %different, label %check.length\n");
    c.output_file.write("check.length:\n");
    c.output_file.write("  %left.len.addr = getelementptr inbounds %struct.$String, %struct.$String* %left, i32 0, i32 1\n");
    c.output_file.write("  %right.len.addr = getelementptr inbounds %struct.$String, %struct.$String* %right, i32 0, i32 1\n");
    c.output_file.write("  %left.len = load i32, i32* %left.len.addr\n");
    c.output_file.write("  %right.len = load i32, i32* %right.len.addr\n");
    c.output_file.write("  %same.len = icmp eq i32 %left.len, %right.len\n");
    c.output_file.write("  br i1 %same.len, label %prepare, label %different\n");
    c.output_file.write("prepare:\n");
    c.output_file.write("  %left.buf.addr = getelementptr inbounds %struct.$String, %struct.$String* %left, i32 0, i32 0\n");
    c.output_file.write("  %right.buf.addr = getelementptr inbounds %struct.$String, %struct.$String* %right, i32 0, i32 0\n");
    c.output_file.write("  %left.buf = load i8*, i8** %left.buf.addr\n");
    c.output_file.write("  %right.buf = load i8*, i8** %right.buf.addr\n");
    c.output_file.write("  br label %compare\n");
    c.output_file.write("compare:\n");
    c.output_file.write("  %index = phi i32 [ 0, %prepare ], [ %next, %matched ]\n");
    c.output_file.write("  %done = icmp uge i32 %index, %left.len\n");
    c.output_file.write("  br i1 %done, label %equal, label %read\n");
    c.output_file.write("read:\n");
    c.output_file.write("  %left.byte.addr = getelementptr inbounds i8, i8* %left.buf, i32 %index\n");
    c.output_file.write("  %right.byte.addr = getelementptr inbounds i8, i8* %right.buf, i32 %index\n");
    c.output_file.write("  %left.byte = load i8, i8* %left.byte.addr\n");
    c.output_file.write("  %right.byte = load i8, i8* %right.byte.addr\n");
    c.output_file.write("  %byte.equal = icmp eq i8 %left.byte, %right.byte\n");
    c.output_file.write("  br i1 %byte.equal, label %matched, label %different\n");
    c.output_file.write("matched:\n");
    c.output_file.write("  %next = add i32 %index, 1\n");
    c.output_file.write("  br label %compare\n");
    c.output_file.write("equal:\n");
    c.output_file.write("  ret i1 true\n");
    c.output_file.write("different:\n");
    c.output_file.write("  ret i1 false\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define internal i32 @__wl_dict_key_hash(%struct.$Variant* %key) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %is.null = icmp eq %struct.$Variant* %key, null\n");
    c.output_file.write("  br i1 %is.null, label %invalid, label %read\n");
    c.output_file.write("read:\n");
    c.output_file.write("  %tag.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %key, i32 0, i32 0\n");
    c.output_file.write("  %low.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %key, i32 0, i32 1\n");
    c.output_file.write("  %high.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %key, i32 0, i32 2\n");
    c.output_file.write("  %tag = load i64, i64* %tag.addr\n");
    c.output_file.write("  %low = load i64, i64* %low.addr\n");
    c.output_file.write("  %high = load i64, i64* %high.addr\n");
    c.output_file.write("  switch i64 %tag, label %invalid [\n");
    c.output_file.write("    i64 0, label %bits\n");
    let key_cases -> String = "";
    let seen_keys -> Dict = Dict(64);
    seen_keys.put("0", StringConstant(id=0, value="null"));
    let type_id -> Int = 1;
    while (type_id < c.type_counter) {
        if (type_id != TYPE_NULL && type_id != TYPE_NULLPTR && type_id != TYPE_GENERIC_CLASS && type_id != TYPE_GENERIC_FUNCTION && type_id != TYPE_GENERIC_METHOD && is_dict_key_type(c, type_id)) {
            let label -> String = "%bits";
            if (type_id == TYPE_STRING) { label = "%string"; }
            if (type_id == TYPE_FLOAT || type_id == TYPE_FLOAT32) { label = "%float"; }
            key_cases = append_dict_key_case(c, key_cases, seen_keys, type_id, label);
        }
        type_id++;
    }
    c.output_file.write(key_cases);
    c.output_file.write("  ]\n");
    c.output_file.write("bits:\n");
    c.output_file.write("  %bits.hash = call i32 @__wl_dict_hash_bits(i64 %tag, i64 %low, i64 %high)\n");
    c.output_file.write("  ret i32 %bits.hash\n");
    c.output_file.write("float:\n");
    c.output_file.write("  %float.value = bitcast i64 %low to double\n");
    c.output_file.write("  %float.nan = fcmp uno double %float.value, %float.value\n");
    c.output_file.write("  br i1 %float.nan, label %invalid, label %float.valid\n");
    c.output_file.write("float.valid:\n");
    c.output_file.write("  %float.zero = fcmp oeq double %float.value, 0.0\n");
    c.output_file.write("  %float.bits = select i1 %float.zero, i64 0, i64 %low\n");
    c.output_file.write("  %float.hash = call i32 @__wl_dict_hash_bits(i64 %tag, i64 %float.bits, i64 0)\n");
    c.output_file.write("  ret i32 %float.hash\n");
    c.output_file.write("string:\n");
    c.output_file.write("  %string.ptr = inttoptr i64 %low to %struct.$String*\n");
    c.output_file.write("  %string.null = icmp eq %struct.$String* %string.ptr, null\n");
    c.output_file.write("  br i1 %string.null, label %invalid, label %string.read\n");
    c.output_file.write("string.read:\n");
    c.output_file.write("  %string.buf.addr = getelementptr inbounds %struct.$String, %struct.$String* %string.ptr, i32 0, i32 0\n");
    c.output_file.write("  %string.len.addr = getelementptr inbounds %struct.$String, %struct.$String* %string.ptr, i32 0, i32 1\n");
    c.output_file.write("  %string.buf = load i8*, i8** %string.buf.addr\n");
    c.output_file.write("  %string.len = load i32, i32* %string.len.addr\n");
    c.output_file.write("  %string.bad.len = icmp slt i32 %string.len, 0\n");
    c.output_file.write("  br i1 %string.bad.len, label %invalid, label %string.loop\n");
    c.output_file.write("string.loop:\n");
    c.output_file.write("  %string.index = phi i32 [ 0, %string.read ], [ %string.next, %string.body ]\n");
    c.output_file.write("  %string.state = phi i64 [ 14695981039346656037, %string.read ], [ %string.next.state, %string.body ]\n");
    c.output_file.write("  %string.done = icmp uge i32 %string.index, %string.len\n");
    c.output_file.write("  br i1 %string.done, label %string.end, label %string.body\n");
    c.output_file.write("string.body:\n");
    c.output_file.write("  %string.byte.addr = getelementptr inbounds i8, i8* %string.buf, i32 %string.index\n");
    c.output_file.write("  %string.byte = load i8, i8* %string.byte.addr\n");
    c.output_file.write("  %string.byte.wide = zext i8 %string.byte to i64\n");
    c.output_file.write("  %string.xor = xor i64 %string.state, %string.byte.wide\n");
    c.output_file.write("  %string.next.state = mul i64 %string.xor, 1099511628211\n");
    c.output_file.write("  %string.next = add i32 %string.index, 1\n");
    c.output_file.write("  br label %string.loop\n");
    c.output_file.write("string.end:\n");
    c.output_file.write("  %string.len.wide = zext i32 %string.len to i64\n");
    c.output_file.write("  %string.hash = call i32 @__wl_dict_hash_bits(i64 %tag, i64 %string.state, i64 %string.len.wide)\n");
    c.output_file.write("  ret i32 %string.hash\n");
    c.output_file.write("invalid:\n");
    c.output_file.write("  ret i32 0\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define internal i1 @__wl_dict_keys_equal(%struct.$Variant* %left, %struct.$Variant* %right) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %same = icmp eq %struct.$Variant* %left, %right\n");
    c.output_file.write("  br i1 %same, label %equal, label %check.null\n");
    c.output_file.write("check.null:\n");
    c.output_file.write("  %left.null = icmp eq %struct.$Variant* %left, null\n");
    c.output_file.write("  %right.null = icmp eq %struct.$Variant* %right, null\n");
    c.output_file.write("  %has.null = or i1 %left.null, %right.null\n");
    c.output_file.write("  br i1 %has.null, label %different, label %read\n");
    c.output_file.write("read:\n");
    c.output_file.write("  %left.tag.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %left, i32 0, i32 0\n");
    c.output_file.write("  %right.tag.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %right, i32 0, i32 0\n");
    c.output_file.write("  %left.tag = load i64, i64* %left.tag.addr\n");
    c.output_file.write("  %right.tag = load i64, i64* %right.tag.addr\n");
    c.output_file.write("  %same.tag = icmp eq i64 %left.tag, %right.tag\n");
    c.output_file.write("  br i1 %same.tag, label %dispatch, label %different\n");
    c.output_file.write("dispatch:\n");
    c.output_file.write("  switch i64 %left.tag, label %bits [\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_STRING) + ", label %string\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_FLOAT) + ", label %float\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_FLOAT32) + ", label %float\n");
    c.output_file.write("  ]\n");
    c.output_file.write("bits:\n");
    c.output_file.write("  %left.low.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %left, i32 0, i32 1\n");
    c.output_file.write("  %right.low.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %right, i32 0, i32 1\n");
    c.output_file.write("  %left.high.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %left, i32 0, i32 2\n");
    c.output_file.write("  %right.high.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %right, i32 0, i32 2\n");
    c.output_file.write("  %left.low = load i64, i64* %left.low.addr\n");
    c.output_file.write("  %right.low = load i64, i64* %right.low.addr\n");
    c.output_file.write("  %left.high = load i64, i64* %left.high.addr\n");
    c.output_file.write("  %right.high = load i64, i64* %right.high.addr\n");
    c.output_file.write("  %same.low = icmp eq i64 %left.low, %right.low\n");
    c.output_file.write("  %same.high = icmp eq i64 %left.high, %right.high\n");
    c.output_file.write("  %same.bits = and i1 %same.low, %same.high\n");
    c.output_file.write("  ret i1 %same.bits\n");
    c.output_file.write("float:\n");
    c.output_file.write("  %float.left.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %left, i32 0, i32 1\n");
    c.output_file.write("  %float.right.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %right, i32 0, i32 1\n");
    c.output_file.write("  %float.left.bits = load i64, i64* %float.left.addr\n");
    c.output_file.write("  %float.right.bits = load i64, i64* %float.right.addr\n");
    c.output_file.write("  %float.left = bitcast i64 %float.left.bits to double\n");
    c.output_file.write("  %float.right = bitcast i64 %float.right.bits to double\n");
    c.output_file.write("  %float.equal = fcmp oeq double %float.left, %float.right\n");
    c.output_file.write("  ret i1 %float.equal\n");
    c.output_file.write("string:\n");
    c.output_file.write("  %string.left.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %left, i32 0, i32 1\n");
    c.output_file.write("  %string.right.addr = getelementptr inbounds %struct.$Variant, %struct.$Variant* %right, i32 0, i32 1\n");
    c.output_file.write("  %string.left.raw = load i64, i64* %string.left.addr\n");
    c.output_file.write("  %string.right.raw = load i64, i64* %string.right.addr\n");
    c.output_file.write("  %string.left = inttoptr i64 %string.left.raw to %struct.$String*\n");
    c.output_file.write("  %string.right = inttoptr i64 %string.right.raw to %struct.$String*\n");
    c.output_file.write("  %string.equal = call i1 @__wl_dict_string_equal(%struct.$String* %string.left, %struct.$String* %string.right)\n");
    c.output_file.write("  ret i1 %string.equal\n");
    c.output_file.write("equal:\n");
    c.output_file.write("  ret i1 true\n");
    c.output_file.write("different:\n");
    c.output_file.write("  ret i1 false\n");
    c.output_file.write("}\n\n");
}

func compile_arc_hooks(c -> Compiler) -> Void {
    let free_hook -> String = get_mangled_symbol(c, "memory_free", null);
    let exit_hook -> String = get_mangled_symbol(c, "process_exit", null);

    c.output_file.write("define internal void @__wl_oom() noreturn {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  call void @" + exit_hook + "(i32 1)\n");
    c.output_file.write("  unreachable\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define internal void @__wl_retain(i8* %ptr) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %is.null = icmp eq i8* %ptr, null\n");
    c.output_file.write("  br i1 %is.null, label %done, label %work\n");
    c.output_file.write("work:\n");
    c.output_file.write("  %base = getelementptr i8, i8* %ptr, i32 -8\n");
    c.output_file.write("  %rc.ptr = bitcast i8* %base to i32*\n");
    c.output_file.write("  %rc = load atomic i32, i32* %rc.ptr monotonic, align 4\n");
    c.output_file.write("  %is.static = icmp eq i32 %rc, -1\n");
    c.output_file.write("  br i1 %is.static, label %done, label %retain\n");
    c.output_file.write("retain:\n");
    c.output_file.write("  %old = atomicrmw add i32* %rc.ptr, i32 1 monotonic\n");
    c.output_file.write("  %invalid = icmp slt i32 %old, 0\n");
    c.output_file.write("  br i1 %invalid, label %trap, label %done\n");
    c.output_file.write("trap:\n");
    c.output_file.write("  call void @llvm.trap()\n");
    c.output_file.write("  unreachable\n");
    c.output_file.write("done:\n");
    c.output_file.write("  ret void\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define internal void @__wl_release(i8* %ptr) {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %is.null = icmp eq i8* %ptr, null\n");
    c.output_file.write("  br i1 %is.null, label %done, label %work\n");
    c.output_file.write("work:\n");
    c.output_file.write("  %base = getelementptr i8, i8* %ptr, i32 -8\n");
    c.output_file.write("  %rc.ptr = bitcast i8* %base to i32*\n");
    c.output_file.write("  %rc = load atomic i32, i32* %rc.ptr monotonic, align 4\n");
    c.output_file.write("  %is.static = icmp eq i32 %rc, -1\n");
    c.output_file.write("  br i1 %is.static, label %done, label %release\n");
    c.output_file.write("release:\n");
    c.output_file.write("  %old = atomicrmw sub i32* %rc.ptr, i32 1 acq_rel\n");
    c.output_file.write("  %invalid = icmp sle i32 %old, 0\n");
    c.output_file.write("  br i1 %invalid, label %trap, label %check.last\n");
    c.output_file.write("trap:\n");
    c.output_file.write("  call void @llvm.trap()\n");
    c.output_file.write("  unreachable\n");
    c.output_file.write("check.last:\n");
    c.output_file.write("  %is.last = icmp eq i32 %old, 1\n");
    c.output_file.write("  br i1 %is.last, label %destroy, label %done\n");
    c.output_file.write("destroy:\n");
    c.output_file.write("  %tag.addr = getelementptr inbounds i8, i8* %base, i32 4\n");
    c.output_file.write("  %tag.ptr = bitcast i8* %tag.addr to i32*\n");
    c.output_file.write("  %tag = load i32, i32* %tag.ptr\n");
    c.output_file.write("  %is.dynamic = icmp ne i32 %tag, " + TYPE_STRING + "\n");
    c.output_file.write("  br i1 %is.dynamic, label %destroy.dynamic, label %destroy.legacy\n");
    c.output_file.write("destroy.dynamic:\n");
    c.output_file.write("  %raw = getelementptr inbounds i8, i8* %base, i32 -8\n");
    c.output_file.write("  %drop.slot = bitcast i8* %raw to i8**\n");
    c.output_file.write("  %drop.raw = load i8*, i8** %drop.slot\n");
    c.output_file.write("  %drop = bitcast i8* %drop.raw to void (i8*)*\n");
    c.output_file.write("  call void %drop(i8* %ptr)\n");
    c.output_file.write("  call void @" + free_hook + "(i8* %raw)\n");
    c.output_file.write("  br label %done\n");
    c.output_file.write("destroy.legacy:\n");
    c.output_file.write("  call void @" + free_hook + "(i8* %base)\n");
    c.output_file.write("  br label %done\n");
    c.output_file.write("done:\n");
    c.output_file.write("  ret void\n");
    c.output_file.write("}\n\n");

    emit_type_drop(c, TYPE_GENERIC_FUNCTION);

    let variant_info -> StructInfo = c.struct_table.get("$Variant");
    if (variant_info is !null) { emit_type_drop(c, variant_info.type_id); }

    let type_id -> Int = 100;
    while (type_id < c.type_counter) {
        let should_emit -> Bool = false;
        let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
        if (arr_info is !null && arr_info.size == -1) { should_emit = true; }
        if (c.vector_base_map.get("" + type_id) is !null) { should_emit = true; }

        let s_info -> StructInfo = c.struct_id_map.get("" + type_id);
        if (s_info is !null && !s_info.is_enum && !s_info.is_interface) {
            if (variant_info is null || type_id != variant_info.type_id) { should_emit = true; }
        }

        if should_emit { emit_type_drop(c, type_id); }
        type_id += 1;
    }
}

func precompile_ast(c -> Compiler, node -> Struct, final_path -> String, import_prefix -> String, old_dir -> String) -> Void {
    let block -> BlockNode = node;
    let stmts -> Vector(Struct) = block.stmts;
    let len -> Int = 0;
    if (stmts is !null) { len = stmts.length(); }

    let imports -> Vector(Struct) = [];
    let i -> Int = 0;
    while (i < len) {
        let base -> BaseNode = stmts[i];
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

    let p_mod -> ParsedModule = ParsedModule(
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

func module_symbol_stem(name -> String) -> String {
    let stem -> String = "";
    let i -> Int = 0;
    while (i < name.length()) {
        let ch -> Char = name[i];
        let valid -> Bool = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                            (ch >= '0' && ch <= '9') || ch == '_';
        if valid { stem += ch; } else { stem += '_'; }
        i += 1;
    }
    if (stem.length() == 0) { return "module"; }
    return stem;
}

func reserve_module_prefix(c -> Compiler, canonical_name -> String, final_path -> String) -> String {
    let stem -> String = module_symbol_stem(canonical_name);
    let prefix -> String = stem + ".";
    let owner -> StringConstant = c.module_prefix_owners.get(prefix);
    if (owner is null || owner.value == final_path) {
        c.module_prefix_owners.put(prefix, StringConstant(id=0, value=final_path));
        return prefix;
    }

    while true {
        prefix = stem + "__m" + c.module_id + ".";
        c.module_id += 1;
        owner = c.module_prefix_owners.get(prefix);
        if (owner is null || owner.value == final_path) {
            c.module_prefix_owners.put(prefix, StringConstant(id=0, value=final_path));
            return prefix;
        }
    }
    return "";
}

func bind_loaded_prelude(c -> Compiler, path -> String, pos -> Position) -> Void {
    let final_path -> String = resolve_import_path(c, path, pos);
    if (final_path is null || final_path.length() == 0) { return; }
    let loaded -> StringConstant = c.imported_modules.get(final_path);
    if (loaded is null) { return; }
    let star -> Token = Token(type=TOK_MUL, value="*", line=pos.ln, col=pos.col);
    let symbols -> Vector(Struct) = [ImportSymbolNode(name_tok=star, alias_tok=null)];
    let path_tok -> Token = Token(type=TOK_STR_LIT, value=path, line=pos.ln, col=pos.col);
    bind_import_symbols(c, ImportNode(type=NODE_IMPORT, path_tok=path_tok, symbols=symbols, alias_tok=null, pos=pos), loaded.value, false, true);
}

func bind_module_prelude(c -> Compiler, pos -> Position) -> Void {
    bind_loaded_prelude(c, "errors", pos);
    bind_loaded_prelude(c, "builtin", pos);
    bind_loaded_prelude(c, "dict", pos);
}

func compile_import(c -> Compiler, node -> ImportNode) -> Void {
    let raw_path -> String = node.path_tok.value;
    let final_path -> String = resolve_import_path(c, raw_path, node.pos);
    if (final_path is null || final_path.length() == 0) { return; }

    let is_pkg -> Bool = final_path.ends_with("/_pkg.wl") || final_path.ends_with("\\_pkg.wl");

    let len -> Int = raw_path.length();
    let end_idx -> Int = len;
    if (raw_path.ends_with(".wl")) {
        end_idx = len - 3;
    }
    let start_idx -> Int = 0;
    let i -> Int = len - 1;
    while (i >= 0) {
        let ch -> Char = raw_path[i];
        if (ch == '/' || ch == '\\') {
            start_idx = i + 1;
            break;
        }
        i -= 1;
    }
    let canonical_name -> String = raw_path.slice(start_idx, end_idx);

    let module_name -> String = canonical_name;
    if (node.alias_tok is !null) {
        module_name = node.alias_tok.value;
    }

    let loaded_module -> StringConstant = c.imported_modules.get(final_path);
    let import_prefix -> String = "";
    if (loaded_module is !null) {
        import_prefix = loaded_module.value;
    } else {
        import_prefix = reserve_module_prefix(c, canonical_name, final_path);
    }
    if (node.symbols is null) {
        if (c.current_file_namespaces.get(module_name) is !null) { unbind_namespace(c, module_name); }
        let existing_prefix -> String = c.current_file_visible_prefixes.get(module_name);
        if (existing_prefix is !null && existing_prefix != import_prefix) {
            throw_import_error(node.pos, "Module name '" + module_name + "' is already bound to another module.");
            return;
        }
        c.current_file_visible_prefixes.put(module_name, import_prefix);
    }

    if (loaded_module is !null) {
        if (node.symbols is !null) {
            bind_import_symbols(c, node, import_prefix, true, false);
            let s_len -> Int = node.symbols.length();
            let i -> Int = 0;
            let is_star -> Bool = false;
            while (i < s_len) {
                let curr_sym -> ImportSymbolNode = node.symbols[i];
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

    let f -> file.File = file.open(final_path)?;
    catch(err) {
        throw_import_error(node.pos, "Failed to open module '" + final_path + "' (error " + Int(err) + ").");
        return;
    }
    let source -> String = f.read_all()?;
    catch(err) {
        f.close();
        throw_import_error(node.pos, "Failed to read module '" + final_path + "' (error " + Int(err) + ").");
        return;
    }
    f.close();

    let marker -> StringConstant = StringConstant(id=0, value=import_prefix);
    c.imported_modules.put(final_path, marker);

    let old_prefix -> String = c.current_package_prefix;
    let old_is_package -> Bool = c.current_module_is_package;
    let old_dir -> String = c.current_dir;

    c.current_dir = get_dir_name(final_path);
    c.current_package_prefix = import_prefix;
    c.current_module_is_package = is_pkg;

    let backup_visible -> Dict = c.current_file_visible_prefixes;
    let backup_namespaces -> Dict = c.current_file_namespaces;
    let backup_types   -> Dict = c.current_file_type_aliases;
    let backup_funcs   -> Dict = c.current_file_func_aliases;
    let backup_globals -> Dict = c.current_file_global_aliases;
    c.current_file_visible_prefixes = Dict(32);
    c.current_file_namespaces       = Dict(32);
    c.current_file_type_aliases     = Dict(32);
    c.current_file_func_aliases     = Dict(32);
    c.current_file_global_aliases   = Dict(32);
    let lexer -> Lexer = new_lexer(final_path, source);
    let parser -> Parser = Parser(lexer=lexer, current_tok=get_next_token(lexer), nesting=0);
    let mod_ast -> Struct = parse(parser);

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
        let s_len -> Int = node.symbols.length();
        let i -> Int = 0;
        let is_star -> Bool = false;
        while (i < s_len) {
            let curr_sym -> ImportSymbolNode = node.symbols[i];
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

func compile_ast_pass(c -> Compiler, p_mod -> ParsedModule) -> Void {
    c.current_file_visible_prefixes = p_mod.visible;
    c.current_file_namespaces       = p_mod.namespaces;
    c.current_file_type_aliases     = p_mod.types;
    c.current_file_func_aliases     = p_mod.funcs;
    c.current_file_global_aliases   = p_mod.globals;
    c.current_package_prefix        = p_mod.prefix;
    c.current_module_is_package     = p_mod.is_package;
    c.current_dir                   = p_mod.dir;

    let imports -> Vector(Struct) = p_mod.imports;
    let i_len -> Int = 0; if (imports is !null) { i_len = imports.length(); }
    let i -> Int = 0;
    while (i < i_len) {
        let imp -> ImportNode = imports[i];
        if (imp.symbols is !null) {
            let raw_path -> String = imp.path_tok.value;
            let final_path -> String = resolve_import_path(c, raw_path, imp.pos);
            if (final_path is !null && final_path.length() > 0) {
                let loaded_module -> StringConstant = c.imported_modules.get(final_path);
                if (loaded_module is !null) {
                    bind_import_symbols(c, imp, loaded_module.value, true, false);
                }
            }
        }
        i += 1;
    }

    let block -> BlockNode = p_mod.ast;
    let stmts -> Vector(Struct) = block.stmts;
    let len -> Int = 0;
    if (stmts is !null) { len = stmts.length(); }

    i = 0;
    while (i < len) {
        let base -> BaseNode = stmts[i];
        if (base.type == NODE_ENUM_DEF) {
            compile_node(c, stmts[i]);
        }
        i += 1;
    }

    i = 0;
    while (i < len) {
        let base -> BaseNode = stmts[i];
        if (base.type != NODE_IMPORT && base.type != NODE_ENUM_DEF) {
            compile_node(c, stmts[i]);
        }
        i += 1;
    }

    // free AST memory immediately since code generation for this module is done
    p_mod.ast = null;
}

func must_terminate(c -> Compiler, node -> Struct) -> Bool {
    if (node is null) { return false; }
    let base -> BaseNode = node;

    if (base.type == NODE_RETURN || base.type == NODE_BREAK ||
        base.type == NODE_CONTINUE || base.type == NODE_THROW) {
        return true;
    }

    if (base.type == NODE_BLOCK) {
        let block -> BlockNode = node;
        if (block.stmts is null || block.stmts.length() == 0) { return false; }
        return must_terminate(c, block.stmts[block.stmts.length() - 1]);
    }

    if (base.type == NODE_IF) {
        let if_node -> IfNode = node;
        let platform_value -> Int = fold_target_cond(c, if_node.condition);
        if (platform_value == 1) {
            return must_terminate(c, if_node.body);
        }
        if (platform_value == 0 && if_node.else_body is !null) {
            return must_terminate(c, if_node.else_body);
        }

        // for a runtime condition, execution terminates only if both paths do
        if (platform_value == -1 && if_node.else_body is !null) {
            if (must_terminate(c, if_node.body) &&
                must_terminate(c, if_node.else_body)) {
                return true;
            }
        }
    }

    if (base.type == NODE_WHILE) {
        let loop -> WhileNode = node;
        let condition -> BaseNode = loop.condition;
        if (condition is !null && condition.type == NODE_BOOL) {
            let boolean -> BooleanNode = loop.condition;
            return boolean.value == 1 && !has_loop_break(loop.body);
        }
    }
    if (base.type == NODE_FOR) {
        let loop -> ForNode = node;
        if (loop.cond is null && !has_loop_break(loop.body)) { return true; }
        if (loop.cond is !null) {
            let condition -> BaseNode = loop.cond;
            if (condition.type == NODE_BOOL) { let boolean -> BooleanNode = loop.cond; if (boolean.value == 1 && !has_loop_break(loop.body)) { return true; } }
        }
    }
    return false;
}

func discard_statement_result(c -> Compiler, node -> Struct, result -> CompileResult) -> Void {
    if (node is null || result is null) { return; }
    let base -> BaseNode = node;
    if (base.type == NODE_VAR_ASSIGN || base.type == NODE_FIELD_ASSIGN || base.type == NODE_INDEX_ASSIGN || base.type == NODE_PTR_ASSIGN || base.type == NODE_CATCH) { return; }
    if (result.owns_ref) {
        emit_release_owned(c, result);
        result.owns_ref = false;
        return;
    }
    if (base.type == NODE_CALL && result_owns_value(c, result.type)) {
        emit_retain_value(c, result.reg, result.type);
        emit_drop_value(c, result.reg, result.type);
    }
}

func validate_fallible_call(c -> Compiler, type_id -> Int, handled -> Bool, name -> String, pos -> Position) -> Bool {
    if (!is_fallible_type(c, type_id) || handled) { return true; }
    let message -> String = "fallible call requires '?'";
    if (name is !null && name.length() > 0) { message = "call to fallible function '" + name + "' requires '?'"; }
    throw_type_error(pos, message);
    return false;
}

func compile_block(c -> Compiler, node -> BlockNode) -> CompileResult {
    let is_root -> Bool = false;
    if (c.scope_depth == 0) {
        is_root = true;
    }

    if (!is_root) {
        enter_scope(c);
    }
    
    let stmts -> Vector(Struct) = node.stmts;
    let len -> Int = 0;
    if (stmts is !null) { len = stmts.length(); }
    let i -> Int = 0;
    
    let last_res -> CompileResult = null;
    let terminated -> Bool = false;
    while (i < len) {
        let stmt -> BaseNode = stmts[i];
        last_res = compile_node(c, stmts[i]);
        discard_statement_result(c, stmts[i], last_res);
        if (must_terminate(c, stmts[i])) {
            terminated = true;
            break;
        }
        i += 1;
    }
    
    if (!is_root) {
        if terminated {
            if (c.symbol_table.parent is !null) {
                c.symbol_table = c.symbol_table.parent;
            }
            c.scope_depth -= 1;
        } else {
            exit_scope(c);
        }
    }
    
    if (last_res is null) { return void_result();}
    return last_res;
}

func compile_var_decl(c -> Compiler, node -> VarDeclareNode) -> CompileResult {
    let target_type_id -> Int = resolve_type(c, node.type_node);
    let const_access -> Bool = node.is_const;

    if (target_type_id == TYPE_AUTO) {
        target_type_id = get_expr_type(c, node.value);
        if (target_type_id == TYPE_POISON) {
            let curr_scope -> Scope = c.symbol_table;
            curr_scope.table.put(node.name_tok.value, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
            return void_result();
        }
        if (target_type_id == 0 || target_type_id == TYPE_AUTO) {
            throw_type_error(node.pos, "Failed to statically infer type for 'Auto'.");
            let curr_scope -> Scope = c.symbol_table;
            curr_scope.table.put(node.name_tok.value, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
            return void_result();
        }
        if (target_type_id == TYPE_NULL || target_type_id == TYPE_NULLPTR || target_type_id == TYPE_VOID || target_type_id == TYPE_POISON) {
            throw_type_error(node.pos, "Cannot infer 'Auto' as null, Void");
            let curr_scope -> Scope = c.symbol_table;
            curr_scope.table.put(node.name_tok.value, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
            return void_result();
        }
    }

    if (is_fallible_type(c, target_type_id)) {
        throw_type_error(node.pos, "Fallible values cannot be stored; handle the call with '?'");
        let curr_scope -> Scope = c.symbol_table;
        curr_scope.table.put(node.name_tok.value, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
        return void_result();
    }

    if (target_type_id == TYPE_VOID || target_type_id == TYPE_POISON) {
        let curr_scope -> Scope = c.symbol_table;
        curr_scope.table.put(node.name_tok.value, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
        return void_result();
    }

    let llvm_ty_str -> String = get_llvm_type_str(c, target_type_id);
    let var_name -> String = node.name_tok.value;

    if (c.scope_depth == 0) {
        let sys_anns -> SystemAnnResult = consume_annotations(node.annotations, var_name);

        let full_var_name -> String = var_name;
        if (c.current_package_prefix != "") {
            full_var_name = c.current_package_prefix + var_name;
        }

        if ((sys_anns.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
            let intrinsic -> String = sys_anns.intrinsic_name;
            if (intrinsic != "target_os" && intrinsic != "target_arch" && intrinsic != "target_abi" && intrinsic != "target_binary_format" && intrinsic != "target_pointer_bits") {
                throw_internal_compiler_error(node.pos, "Unknown intrinsic global '" + sys_anns.intrinsic_name + "'.");
                return void_result();
            }
            if (!node.is_const) {
                throw_type_error(node.pos, "Target intrinsics must be declared as const values.");
                return void_result();
            }
            if (intrinsic == "target_pointer_bits") {
                if (target_type_id != TYPE_INT) {
                    throw_type_error(node.pos, "Intrinsic 'sys.POINTER_BITS' must be declared as const Int.");
                    return void_result();
                }
            } else {
                let target_info -> StructInfo = c.struct_id_map.get("" + target_type_id);
                let enum_name -> String = target_enum_name(intrinsic);
                if (target_info is null || !target_info.is_enum || (target_info.name != enum_name && !target_info.name.ends_with("." + enum_name))) {
                    throw_type_error(node.pos, "Target intrinsics must use their target enum type.");
                    return void_result();
                }
            }
            c.global_symbol_table.put(full_var_name, SymbolInfo(reg="$intrinsic." + intrinsic, type=target_type_id, origin_type=target_type_id, is_const=true));
            return void_result();
        }

        let global_name -> String = "@" + full_var_name;

        if ((sys_anns.ann_flags & FLAG_ANN_EXPORT) != 0) {
            global_name = "@" + var_name; 
        }

        let init_val_str -> String = "0";
        let has_const_num -> Bool = false;
        let const_num -> Float = 0.0;
        if (is_nullable_reference_type(c, target_type_id)) { 
            let s_info -> StructInfo = c.struct_id_map.get("" + target_type_id);
            if (s_info is !null && s_info.is_interface) {
                init_val_str = "zeroinitializer";
            } else {
                init_val_str = "null"; 
            }
        }

        if (node.value is !null) {
            let val_node -> BaseNode = node.value;
            if (val_node.type == NODE_STRING) {
                let s_node -> StringNode = node.value;
                let s_val -> String = s_node.tok.value;
                let s_id -> Int = register_string_constant(c, s_val);
                init_val_str = get_string_object_ptr(s_id);
            }
            else if (val_node.type == NODE_NULLPTR) {
                if (!is_pointer_type(c, target_type_id)) {
                    throw_invalid_syntax(node.pos, "Global 'nullptr' can only be assigned to pointer types.");
                    return void_result();
                }
                init_val_str = "null";
            }
            else if (val_node.type == NODE_NULL) {
                if (is_pointer_type(c, target_type_id)) {
                    throw_invalid_syntax(node.pos, "Global 'null' cannot be assigned to explicit pointer types. Use 'nullptr'.");
                    return void_result();
                }
                if (is_primitive_type(target_type_id)) {
                    throw_type_error(node.pos, "Primitive types cannot be null.");
                    return void_result();
                }
                init_val_str = "null";
            }
            else if (is_integer_type(target_type_id)) {
                let expr_type -> Int = get_expr_type(c, val_node);
                if (get_type_bitwidth(target_type_id) < 64 && expr_type == TYPE_LONG) {
                    throw_type_error(node.pos, "Type mismatch. Expected " + get_type_name(c, target_type_id) + ", got Long.");
                    return void_result();
                }

                let bits -> Int = get_type_bitwidth(target_type_id);
                if (bits == 128) {
                    let folded_wide -> UInt128 = eval_const_wide(c, val_node, node.pos, is_unsigned_integer(target_type_id));
                    if (is_unsigned_integer(target_type_id)) {
                        init_val_str = "" + folded_wide;
                    } else {
                        init_val_str = "" + Int128(folded_wide);
                    }
                    if (node.is_const) { c.constant_wide_integers.put(global_name, folded_wide); }
                } else {
                    let folded_val -> Long = eval_const_long(c, val_node, node.pos);
                    const_num = Float(folded_val);
                    has_const_num = true;
                    if (node.is_const) { c.constant_integers.put(global_name, folded_val); }
                    let is_overflow -> Bool = false;
                    
                    if (bits == 8) {
                        if (is_unsigned_integer(target_type_id)) {
                            if (folded_val < 0L || folded_val > 255L) { is_overflow = true; }
                        } else {
                            if (folded_val < -128L || folded_val > 127L) { is_overflow = true; }
                        }
                    } else if (bits == 16) {
                        if (is_unsigned_integer(target_type_id)) {
                            if (folded_val < 0L || folded_val > 65535L) { is_overflow = true; }
                        } else {
                            if (folded_val < -32768L || folded_val > 32767L) { is_overflow = true; }
                        }
                    } else if (bits == 32) {
                        if (is_unsigned_integer(target_type_id)) {
                            if (folded_val < 0L || folded_val > 4294967295L) { is_overflow = true; }
                        } else {
                            if (folded_val < -2147483648L || folded_val > 2147483647L) { is_overflow = true; }
                        }
                    }

                    if (is_overflow) {
                        throw_overflow_error(node.pos, "Global constant overflows " + get_type_name(c, target_type_id) + " valid range.");
                        return void_result();
                    }
                    
                    init_val_str = "" + folded_val;
                }
            }
            else if (target_type_id == TYPE_CHAR) {
                if (val_node.type != NODE_CHAR) {
                    throw_type_error(node.pos, "Type mismatch. Expected Char literal for Char type.");
                    return void_result();
                }
                let cn -> CharNode = node.value;
                init_val_str = "" + string_to_int(cn.tok.value, cn.pos);
                const_num = Float(string_to_int(cn.tok.value, cn.pos));
                has_const_num = true;
                if (node.is_const) { c.constant_integers.put(global_name, Long(string_to_int(cn.tok.value, cn.pos))); }
            }
            else if (target_type_id == TYPE_BOOL) {
                let folded_val -> Int = eval_const_bool(c, val_node, node.pos);
                if (folded_val == 1) { init_val_str = "1"; } else { init_val_str = "0"; }
                const_num = Float(folded_val);
                has_const_num = true;
                if (node.is_const) { c.constant_integers.put(global_name, Long(folded_val)); }
            }
            else if (target_type_id == TYPE_FLOAT || target_type_id == TYPE_FLOAT32) {
                const_num = eval_const_float(c, val_node, node.pos);
                if (target_type_id == TYPE_FLOAT32) { const_num = Float(Float32(const_num)); }
                init_val_str = llvm_float_literal(const_num);
                has_const_num = true;
            } else {
                throw_invalid_syntax(node.pos, "Global variable initialisation must be a compile-time constant expression. ");
                return void_result();
            }
        }

        let linkage -> String = "";
    if (c.is_shared && get_target_os() == sys.Os.Windows) {
            if ((sys_anns.ann_flags & FLAG_ANN_EXPORT) != 0) {
                linkage = "dllexport ";
            } else {
                linkage = "hidden ";
            }
        }

        let storage -> String = "global";
        if (node.is_const) { storage = "constant"; }
        c.output_file.write(global_name + " = " + linkage + storage + " " + llvm_ty_str + " " + init_val_str + "\n");
        c.global_symbol_table.put(full_var_name, SymbolInfo(reg=global_name, type=target_type_id, origin_type=target_type_id, is_const=node.is_const));
        if (node.is_const && has_const_num) { c.constant_nums.put(global_name, const_num); }
        return void_result();
    }

    let local_scope -> Scope = c.symbol_table;
    if (local_scope.table.get(var_name) is !null) {
        throw_name_error(node.pos, "Variable '" + var_name + "' is already declared in this scope");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    let ptr_reg -> String = c.alloc_regs[node.alloc_id];
    let origin_id -> Int = target_type_id;

    if (node.value is null) {
        let s_info -> StructInfo = c.struct_id_map.get("" + target_type_id);
        let is_valid_struct -> Bool = false;
        
        if (s_info is !null) {
            if (c.array_info_map.get("" + target_type_id) is null && 
                c.vector_base_map.get("" + target_type_id) is null && 
                c.func_ret_map.get("" + target_type_id) is null &&
                !s_info.is_enum) {
                is_valid_struct = true;
            }
        }

        if is_valid_struct {
            let fake_args -> Vector(Struct) = [];
            let fake_call -> CallNode = CallNode(type=NODE_CALL, callee=null, args=fake_args, type_args=null, pos=node.pos, preserve_fallible=false);
            let val_res -> CompileResult = null;
            
            if (s_info.is_class) {
                val_res = compile_class_init(c, s_info, fake_call);
            } else {
                val_res = compile_struct_init(c, s_info, fake_call);
            }
            
            if (c.scope_depth > 0 && result_owns_value(c, target_type_id) && !val_res.owns_ref) {
                emit_retain_value(c, val_res.reg, target_type_id);
            }
            c.output_file.write(c.indent + "store " + llvm_ty_str + " " + val_res.reg + ", " + llvm_ty_str + "* " + ptr_reg + "\n");
        } else {
            throw_missing_initializer(node.pos, "Local variable '" + var_name + "' must be initialised immediately upon declaration.");
            let curr_scope -> Scope = c.symbol_table;
            curr_scope.table.put(node.name_tok.value, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
            return void_result();
        }
    } else {
        let is_array_init -> Bool = false;
        let val_base -> BaseNode = node.value;
        let target_arr -> ArrayInfo = c.array_info_map.get("" + target_type_id);
        if (target_arr is !null && val_base.type == NODE_VECTOR_LIT) {
            if (target_arr.size == -1) {
                throw_type_error(node.pos, "Cannot initialise Array(Type) slice directly from a literal.");
                return void_result();
            }

            is_array_init = true;
            let lit_node -> VectorLitNode = node.value;
            
            if (lit_node.count > target_arr.size) {
                throw_type_error(node.pos, "Array literal too large: expected " + target_arr.size + " elements.");
                return void_result();
            }

            compile_array_literal(c, lit_node, target_type_id, ptr_reg);
        }

        if (!is_array_init) {
            c.expected_type = target_type_id;
            let val_res -> CompileResult = compile_node(c, node.value);
            c.expected_type = 0;

            val_res = emit_implicit_cast(c, val_res, target_type_id, node.pos);
            if (val_res.is_const_access) { const_access = true; }
            if (target_type_id == TYPE_GENERIC_STRUCT || target_type_id == TYPE_GENERIC_CLASS) {
                if (val_res.origin_type >= 100) { origin_id = val_res.origin_type; }
            } else if (target_type_id == TYPE_GENERIC_FUNCTION || target_type_id == TYPE_GENERIC_METHOD) {
                if (val_res.origin_type >= 100) { origin_id = val_res.origin_type; }
            }

            if (c.scope_depth > 0 && result_owns_value(c, target_type_id) && !val_res.owns_ref) {
                emit_retain_value(c, val_res.reg, target_type_id);
            }

            c.output_file.write(c.indent + "store " + llvm_ty_str + " " + val_res.reg + ", " + llvm_ty_str + "* " + ptr_reg + "\n");
        }
    }

    let curr_scope -> Scope = c.symbol_table;
    curr_scope.table.put(var_name, SymbolInfo(reg=ptr_reg, type=target_type_id, origin_type=origin_id, is_const=node.is_const, is_const_access=const_access));

    if (c.scope_depth > 0) {
        if (needs_drop(c, target_type_id)) {
            curr_scope.gc_vars.append(GCTracker(reg = ptr_reg, type = target_type_id));
        }
    }

    return void_result(); 
}
func compile_var_assign(c -> Compiler, node -> VarAssignNode) -> CompileResult {
    let var_name -> String = node.name_tok.value;
    let info -> SymbolInfo = find_symbol(c, var_name);
    if (info is null) {
        throw_name_error(node.pos, "Undefined variable '" + var_name + "'.");
        let curr_scope -> Scope = c.symbol_table;
        curr_scope.table.put(var_name, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    if (info.type == TYPE_POISON) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    if (info.is_const) {
        throw_type_error(node.pos, "Cannot assign to constant variable '" + var_name + "'.");
        return void_result();
    }

    c.expected_type = info.type;
    let val_res -> CompileResult = compile_node(c, node.value);
    c.expected_type = 0;

    val_res = emit_implicit_cast(c, val_res, info.type, node.pos);
    info.is_const_access = val_res.is_const_access;

    if (result_owns_value(c, info.type)) {
        if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, info.type); }
        emit_drop_slot(c, info.reg, info.type);
    }
    
    let ty_str -> String = get_llvm_type_str(c, info.type);
    c.output_file.write(c.indent + "store " + ty_str + " " + val_res.reg + ", " + ty_str + "* " + info.reg + "\n");
    return val_res; 
}

func compile_if(c -> Compiler, node -> IfNode) -> CompileResult {
    let platform_value -> Int = fold_target_cond(c, node.condition);
    if (platform_value == 1) {
        compile_node(c, node.body);
        return void_result();
    }
    if (platform_value == 0) {
        if (node.else_body is !null) { compile_node(c, node.else_body); }
        return void_result();
    }

    let cond_res -> CompileResult = compile_node(c, node.condition);
    if (cond_res is !null && cond_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    if (cond_res.type != TYPE_BOOL) {
        throw_type_error(node.pos, "If condition must be a Bool. ");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    
    let label_then -> String = next_label(c);
    let label_else -> String = next_label(c);
    let label_merge -> String = next_label(c);

    let then_terminates -> Bool = must_terminate(c, node.body);
    let else_terminates -> Bool = false;
    if (node.else_body is !null) {
        else_terminates = must_terminate(c, node.else_body);
    }

    let needs_merge -> Bool = true;
    if (node.else_body is !null && then_terminates && else_terminates) {
        needs_merge = false;
    }
    
    let target_else -> String = label_else;
    if (node.else_body is null) {
        target_else = label_merge;
    }
    
    c.output_file.write(c.indent + "br i1 " + cond_res.reg + ", label %" + label_then + ", label %" + target_else + "\n");
    
    c.output_file.write("\n" + label_then + ":\n");
    compile_node(c, node.body);
    if (!then_terminates) {
        c.output_file.write(c.indent + "br label %" + label_merge + "\n");
    }
    
    if (node.else_body is !null) {
        c.output_file.write("\n" + label_else + ":\n");
        compile_node(c, node.else_body);
        if (!else_terminates) {
            c.output_file.write(c.indent + "br label %" + label_merge + "\n");
        }
    }

    if needs_merge {
        c.output_file.write("\n" + label_merge + ":\n");
    }
    return void_result();
}

func compile_while(c -> Compiler, node -> WhileNode) -> CompileResult {
    let label_cond -> String = next_label(c);
    let label_body -> String = next_label(c);
    let label_end  -> String = next_label(c);

    let current_scope -> LoopScope = LoopScope(label_continue=label_cond, label_break=label_end, parent=c.loop_stack, loop_scope=c.symbol_table);
    c.loop_stack = current_scope;

    c.output_file.write(c.indent + "br label %" + label_cond + "\n");
    c.output_file.write("\n" + label_cond + ":\n");
    
    let cond_res -> CompileResult = compile_node(c, node.condition);
    if (cond_res is !null && cond_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    if (cond_res.type != TYPE_BOOL) {
        throw_type_error(node.pos, "While condition must be a Bool. ");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    c.output_file.write(c.indent + "br i1 " + cond_res.reg + ", label %" + label_body + ", label %" + label_end + "\n");

    c.output_file.write("\n" + label_body + ":\n");
    compile_node(c, node.body);
    if (!must_terminate(c, node.body)) {
        c.output_file.write(c.indent + "br label %" + label_cond + "\n");
    }

    c.output_file.write("\n" + label_end + ":\n");
    if (must_terminate(c, node)) {
        c.output_file.write(c.indent + "unreachable\n");
    }
    c.loop_stack = current_scope.parent;
    return void_result();
}

func compile_for(c -> Compiler, node -> ForNode) -> CompileResult {
    enter_scope(c);
    if (node.init is !null) {
        let init_res -> CompileResult = compile_node(c, node.init);
        discard_statement_result(c, node.init, init_res);
    }
    let label_cond -> String = next_label(c);
    let label_body -> String = next_label(c);
    let label_step -> String = next_label(c);
    let label_end  -> String = next_label(c);

    let current_scope -> LoopScope = LoopScope(label_continue=label_step, label_break=label_end, parent=c.loop_stack, loop_scope=c.symbol_table);
    c.loop_stack = current_scope;
    
    c.output_file.write(c.indent + "br label %" + label_cond + "\n");
    c.output_file.write("\n" + label_cond + ":\n");
    if (node.cond is !null) {
        let cond_res -> CompileResult = compile_node(c, node.cond);
        if (cond_res is !null && cond_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
        if (cond_res.type != TYPE_BOOL) {
            throw_type_error(node.pos, "For condition must be a Bool. ");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        c.output_file.write(c.indent + "br i1 " + cond_res.reg + ", label %" + label_body + ", label %" + label_end + "\n");
    } else {
        c.output_file.write(c.indent + "br label %" + label_body + "\n");
    }

    c.output_file.write("\n" + label_body + ":\n");
    compile_node(c, node.body);

    c.output_file.write(c.indent + "br label %" + label_step + "\n");
    c.output_file.write("\n" + label_step + ":\n");
    if (node.step is !null) {
        let step_res -> CompileResult = compile_node(c, node.step);
        discard_statement_result(c, node.step, step_res);
    }
    c.output_file.write(c.indent + "br label %" + label_cond + "\n");
    c.output_file.write("\n" + label_end + ":\n");
    c.loop_stack = current_scope.parent;
    exit_scope(c);
    if (must_terminate(c, node)) { c.output_file.write(c.indent + "unreachable\n"); }
    
    return void_result();
}

func compile_ptr_assign(c -> Compiler, node -> PtrAssignNode) -> CompileResult {
    let d_node -> DerefNode = node.pointer;
    if (reject_const_write(c, d_node.node, node.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let ptr_res -> CompileResult = compile_node(c, d_node.node);

    let i -> Int = 0;
    let curr_reg -> String = ptr_res.reg;
    let curr_type -> Int = ptr_res.type;

    while (i < d_node.level - 1) {
        if (curr_type == TYPE_NULL) { 
            throw_type_error(node.pos, "Cannot dereference 'nullptr'.");
            return void_result(); 
        }
        let base_info -> SymbolInfo = c.ptr_base_map.get("" + curr_type);
        if (base_info is null) { 
            throw_type_error(node.pos, "Cannot dereference non-pointer.");
            return void_result(); 
        }
        
        let next_type -> Int = base_info.type;
        if (next_type == TYPE_VOID) {
            throw_type_error(d_node.pos, "Cannot dereference 'ptr Void'. Cast it to a specific pointer type first.");
            return void_result();
        }
        emit_pointer_null_check(c, curr_reg, curr_type, node.pos);
        let ty_str -> String = get_llvm_type_str(c, next_type);
        let next_reg -> String = next_reg(c);
        c.output_file.write(c.indent + next_reg + " = load " + ty_str + ", " + ty_str + "* " + curr_reg + "\n");
        
        curr_reg = next_reg;
        curr_type = next_type;
        i += 1;
    }

    if (curr_type == TYPE_NULL) {
        throw_null_dereference_error(node.pos, "Cannot dereference 'nullptr'. ");
        return void_result();
    }

    let final_base_info -> SymbolInfo = c.ptr_base_map.get("" + curr_type);
    if (final_base_info is null) { 
        throw_type_error(node.pos, "Cannot assign to non-pointer.");
        return void_result(); 
    }
    
    let target_type_id -> Int = final_base_info.type;
    emit_pointer_null_check(c, curr_reg, curr_type, node.pos);

    c.expected_type = target_type_id;
    let val_res -> CompileResult = compile_node(c, node.value);
    c.expected_type = 0;
    
    val_res = emit_implicit_cast(c, val_res, target_type_id, node.pos);
    
    let llvm_ty -> String = get_llvm_type_str(c, target_type_id);

    if (result_owns_value(c, target_type_id)) {
        if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, target_type_id); }
        emit_drop_slot(c, curr_reg, target_type_id);
    }
    
    c.output_file.write(c.indent + "store " + llvm_ty + " " + val_res.reg + ", " + llvm_ty + "* " + curr_reg + "\n");

    return val_res;
}

func has_loop_break(node -> Struct) -> Bool {
    if (node is null) { return false; }
    let base -> BaseNode = node;
    if (base.type == NODE_BREAK) { return true; }
    if (base.type == NODE_WHILE || base.type == NODE_FOR) { return false; }
    if (base.type == NODE_BLOCK) {
        let block -> BlockNode = node;
        let i -> Int = 0;
        while (block.stmts is !null && i < block.stmts.length()) {
            if (has_loop_break(block.stmts[i])) { return true; }
            i += 1;
        }
        return false;
    }
    if (base.type == NODE_IF) {
        let branch -> IfNode = node;
        return has_loop_break(branch.body) ||
               has_loop_break(branch.else_body);
    }
    if (base.type == NODE_CATCH) {
        let caught -> CatchNode = node;
        return has_loop_break(caught.stmt) ||
               has_loop_break(caught.body);
    }
    return false;
}

func compile_func_def(c -> Compiler, node -> FunctionDefNode) -> CompileResult {
    if (node.type_params is !null && node.type_params.length() > 0 && 
        c.generic_func_key.length() == 0) {
        return void_result();
    }
    let raw_name -> String = node.name_tok.value;

    let func_name -> String = raw_name;
    if (c.generic_func_key.length() > 0) {
        func_name = c.generic_func_key;
    } else if (raw_name != "main") {
        func_name = c.current_package_prefix + raw_name;
    }

    if (raw_name == "main") {
        c.has_main = true;
    }

    let f_info -> FuncInfo = c.func_table.get(func_name);
    if (f_info is null) {
        return void_result();
    }
    if (f_info.compiler_link_name == "dict_key_hash" || f_info.compiler_link_name == "dict_keys_equal") { return void_result(); }
    if ((f_info.ann_flags & FLAG_ANN_INTRINSIC) != 0) { return void_result(); }
    let ret_type_id -> Int = f_info.ret_type;
    let llvm_ret_type -> String = get_llvm_type_str(c, ret_type_id);

    c.current_ret_type = ret_type_id;

    let params_str -> String = "";
    let params -> Vector(Struct) = node.params;
    let p_len -> Int = 0;
    if (params is !null) { p_len = params.length(); }
    let arg_idx -> Int = 0;
    
    while (arg_idx < p_len) {
        let p -> ParamNode = params[arg_idx];
        let p_type_id -> Int = resolve_type(c, p.type_tok);
        let p_llvm_type -> String = get_llvm_type_str(c, p_type_id);
        if (arg_idx > 0) { params_str = params_str + ", "; }
        params_str += p_llvm_type + " %arg" + arg_idx;
        arg_idx += 1;
    }

    let linkage -> String = "internal ";
    if (raw_name == "main" || (f_info.ann_flags & FLAG_ANN_EXPORT) != 0) {
        linkage = "";
        if (c.is_shared && (f_info.ann_flags & FLAG_ANN_EXPORT) != 0 && get_target_os() == sys.Os.Windows) {
            linkage = "dllexport ";
        }
    }

    // keep compiler-link hooks out of line to avoid cloning their loops at call sites
    let func_attrs -> String = "";
    if ((f_info.ann_flags & FLAG_ANN_COMP_LINK) != 0) {
        func_attrs = "noinline ";
    }

    c.output_file.write("define " + linkage + llvm_ret_type + " @" + f_info.name + "(" + params_str + ") " + func_attrs + "{\n");
    c.output_file.write("entry:\n");

    let old_sym -> Scope = c.symbol_table;
    c.symbol_table = Scope(table=Dict(32), parent=null, gc_vars=[], depth=0);
    
    c.reg_count = 0; 
    c.scope_depth = 1;
    c.curr_func = f_info;
    arg_idx = 0;
    while (arg_idx < p_len) {
        let p -> ParamNode = params[arg_idx];
        let p_name -> String = p.name_tok.value;
        
        let target_type_id -> Int = resolve_type(c, p.type_tok);
        let llvm_ty -> String = get_llvm_type_str(c, target_type_id);
        let addr_reg -> String = next_reg(c); 
        c.output_file.write(c.indent + addr_reg + " = alloca " + llvm_ty + "\n");
        c.output_file.write(c.indent + "store " + llvm_ty + " %arg" + arg_idx + ", " + llvm_ty + "* " + addr_reg + "\n");
        let curr_scope -> Scope = c.symbol_table;
        curr_scope.table.put(p_name, SymbolInfo(reg=addr_reg, type=target_type_id, origin_type=target_type_id));
        if (needs_drop(c, target_type_id)) {
            emit_retain_slot(c, addr_reg, target_type_id);
            curr_scope.gc_vars.append(GCTracker(reg=addr_reg, type=target_type_id));
        }
        
        arg_idx += 1;
    }

    c.hoist_scope = Scope(parent=null, table=Dict(32), gc_vars=[], depth=0);
    c.alloc_regs = [];
    hoist_allocas(c, node.body);
    check_local_init(c, node.body);

    compile_node(c, node.body);

    let has_term -> Bool = must_terminate(c, node.body);

    if (!has_term) {
        cleanup_all_scopes(c);
        if (ret_type_id == TYPE_VOID) {
            c.output_file.write(c.indent + "ret void\n");
        } else if (is_fallible_type(c, ret_type_id) &&
                   get_inner_fallible_type(c, ret_type_id) == TYPE_VOID) {
            c.output_file.write(c.indent + "ret " + llvm_ret_type + " zeroinitializer\n");
        } else {
            throw_type_error(node.pos, "Missing return. ");
            c.output_file.write(c.indent + "ret " + llvm_ret_type + " undef\n");
        }
    }
    
    c.output_file.write("}\n\n");

    // restore scope
    c.symbol_table = old_sym;
    c.scope_depth = 0;
    
    c.curr_func = null;
    
    return void_result();
}

func compile_method_def(c -> Compiler, class_name -> String, node -> MethodDefNode) -> CompileResult {
    let raw_name -> String = method_base_name(c, node);
    let m_name -> String = class_name + "_" + raw_name;
    if (c.generic_method_key.length() > 0) {
        m_name = c.generic_method_key;
    }
    
    let f_info -> FuncInfo = c.func_table.get(m_name);
    if (f_info is null) {
        return void_result();
    }
    f_info.mutates_self = method_mutates_self(node.body);
    if (f_info.compiler_link_name == "typed_dict_hash" || f_info.compiler_link_name == "typed_dict_equal" || 
        f_info.compiler_link_name == "typed_dict_zero") {
        return void_result();
    }
    let ret_type_id -> Int = f_info.ret_type;
    let llvm_ret_type -> String = get_llvm_type_str(c, ret_type_id);

    c.current_ret_type = ret_type_id;

    let c_info -> StructInfo = c.struct_table.get(class_name);
    let class_type_id -> Int = c_info.type_id;
    let class_ptr_llvm -> String = get_llvm_type_str(c, class_type_id); 

    let params_str -> String = class_ptr_llvm + " %arg0";
    
    let params -> Vector(Struct) = node.params;
    let p_len -> Int = 0; if (params is !null) { p_len = params.length(); }
    let arg_idx -> Int = 0;
    
    while (arg_idx < p_len) {
        let p -> ParamNode = params[arg_idx];
        let p_type_id -> Int = resolve_type(c, p.type_tok);
        let p_llvm_type -> String = get_llvm_type_str(c, p_type_id);
        let arg_num -> Int = arg_idx + 1;
        params_str = params_str + ", " + p_llvm_type + " %arg" + arg_num;
        arg_idx += 1;
    }

    c.output_file.write("define internal " + llvm_ret_type + " @" + f_info.name + "(" + params_str + ") {\n");
    c.output_file.write("entry:\n");

    let old_sym -> Scope = c.symbol_table;
    c.symbol_table = Scope(table=Dict(32), parent=null, gc_vars=[], depth=0);
    
    c.reg_count = 0; 
    c.scope_depth = 1;
    c.curr_func = f_info;
    
    let self_addr -> String = next_reg(c);
    c.output_file.write(c.indent + self_addr + " = alloca " + class_ptr_llvm + "\n");
    c.output_file.write(c.indent + "store " + class_ptr_llvm + " %arg0, " + class_ptr_llvm + "* " + self_addr + "\n");
    let curr_scope -> Scope = c.symbol_table;
    curr_scope.table.put("self", SymbolInfo(reg=self_addr, type=class_type_id, origin_type=class_type_id, is_const=false));

    arg_idx = 0;
    while (arg_idx < p_len) {
        let p -> ParamNode = params[arg_idx];
        let p_name -> String = p.name_tok.value;
        let target_type_id -> Int = resolve_type(c, p.type_tok);
        let llvm_ty -> String = get_llvm_type_str(c, target_type_id);
        let addr_reg -> String = next_reg(c); 
        c.output_file.write(c.indent + addr_reg + " = alloca " + llvm_ty + "\n");
        let arg_num -> Int = arg_idx + 1;
        c.output_file.write(c.indent + "store " + llvm_ty + " %arg" + arg_num + ", " + llvm_ty + "* " + addr_reg + "\n");
        curr_scope.table.put(p_name, SymbolInfo(reg=addr_reg, type=target_type_id, origin_type=target_type_id, is_const=false));
        if (needs_drop(c, target_type_id)) {
            emit_retain_slot(c, addr_reg, target_type_id);
            curr_scope.gc_vars.append(GCTracker(reg=addr_reg, type=target_type_id));
        }
        arg_idx += 1;
    }

    c.hoist_scope = Scope(parent=null, table=Dict(32), gc_vars=[], depth=0);
    c.alloc_regs = [];
    hoist_allocas(c, node.body);
    check_local_init(c, node.body);
    compile_node(c, node.body);

    let has_term -> Bool = must_terminate(c, node.body);

    if (!has_term) {
        cleanup_all_scopes(c);
        if (ret_type_id == TYPE_VOID) {
            c.output_file.write(c.indent + "ret void\n");
        } else if (is_fallible_type(c, ret_type_id) &&
                   get_inner_fallible_type(c, ret_type_id) == TYPE_VOID) {
            c.output_file.write(c.indent + "ret " + llvm_ret_type + " zeroinitializer\n");
        } else {
            throw_type_error(node.pos, "Missing return. ");
            c.output_file.write(c.indent + "ret " + llvm_ret_type + " undef\n");
        }
    }
    
    c.output_file.write("}\n\n");
    c.symbol_table = old_sym;
    c.scope_depth = 0;
    c.curr_func = null;
    
    return void_result();
}

func emit_method_nullcheck(c -> Compiler, obj_ptr -> String, class_llvm_ty -> String, method_name -> String, pos -> Position) -> Void {
    let is_null -> String = next_reg(c);
    c.output_file.write(c.indent + is_null + " = icmp eq " + class_llvm_ty + "* " + obj_ptr + ", null\n");
    let panic_lbl -> String = next_label(c);
    let cont_lbl -> String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + is_null + ", label %" + panic_lbl + ", label %" + cont_lbl + "\n");
    
    c.output_file.write("\n" + panic_lbl + ":\n");
    let msg -> String = "Cannot call method '" + method_name + "' on null object.";
    emit_runtime_error(c, pos, msg);
    
    c.output_file.write("\n" + cont_lbl + ":\n");
}

func compile_class_method_call(c -> Compiler, s_info -> StructInfo, obj_res -> CompileResult, method_name -> String, n_call -> CallNode) -> CompileResult {
    if (method_name.starts_with("__")) {
        let class_prefix -> String = "";
        let dot_idx -> Int = s_info.name.length() - 1;
        while (dot_idx >= 0) {
            if (s_info.name[dot_idx] == '.') { // '.'
                class_prefix = s_info.name.slice(0, dot_idx + 1);
                break;
            }
            dot_idx -= 1;
        }
        if (c.current_package_prefix != class_prefix) {
            throw_name_error(n_call.pos, "Method '" + method_name + "' is private to class '" + s_info.name + "'.");
            return void_result();
        }
    }

    let vtable_vec -> Vector(Struct) = s_info.vtable;
    let v_len -> Int = 0; if (vtable_vec is !null) { v_len = vtable_vec.length(); }
    
    let m_idx -> Int = 0;
    let found -> Bool = false;
    let f_info -> FuncInfo = null;
    let m_node -> MethodDefNode = null;
    let generic_method -> Bool = false;
    let method_template -> GenericTemplate = c.generic_methods.get(s_info.name + "_" + method_name);

    if (method_template is !null) {
        if (s_info.is_interface) {
            throw_type_error(n_call.pos, "Generic methods cannot be called through an interface value.");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        let types -> Vector(Struct) = resolve_generic_method_args(c, method_template, n_call.type_args, n_call.args, n_call.pos);
        if (types is null) { return CompileResult(reg="poison", type=TYPE_POISON); }
        f_info = register_generic_method(c, method_template, s_info, types, n_call.pos);
        if (f_info is null) { return CompileResult(reg="poison", type=TYPE_POISON); }
        found = true;
        generic_method = true;
    }
    
    while (!found && m_idx < v_len) {
        if (s_info.is_interface) {
            let m -> MethodDefNode = vtable_vec[m_idx];
            if (m.name_tok.value == method_name) {
                m_node = m;
                found = true;
                break;
            }
        } else {
            let m -> FuncInfo = vtable_vec[m_idx];
            if (m.base_name == method_name) {
                f_info = m;
                found = true;
                break;
            }
        }
        m_idx += 1;
    }

    if (!found && !s_info.is_interface) {
        let direct -> FuncInfo = c.func_table.get(s_info.name + "_" + method_name);
        if (direct is !null && direct.compiler_link_name is !null && 
            direct.compiler_link_name.length() > 0) {
            f_info = direct; found = true;
        }
    }
    
    if (!found) { 
        throw_name_error(n_call.pos, "Method '" + method_name + "' not found in '" + s_info.name + "'.");
        return void_result();
    }
    if (!generic_method && n_call.type_args is !null) {
        throw_type_error(n_call.pos, "Method '" + method_name + "' is not generic.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    if (f_info is !null && (f_info.compiler_link_name == "typed_dict_hash" || f_info.compiler_link_name == "typed_dict_equal")) {
        let args -> Vector(Struct) = n_call.args;
        let expected_count -> Int = 1;
        if (f_info.compiler_link_name == "typed_dict_equal") {
            expected_count = 2;
        }

        let actual_count -> Int = 0;
        if (args is !null) {
            actual_count = args.length();
        }
        if (actual_count != expected_count) { throw_type_error(n_call.pos, "Argument count mismatch. Expected " + expected_count + ", got " + actual_count); return CompileResult(reg="poison", type=TYPE_POISON); }

        let key_type_node -> TypeListNode = f_info.arg_types[1];
        let key_type -> Int = key_type_node.type;
        let llvm_type -> String = get_llvm_type_str(c, key_type);
        let values -> Vector(Struct) = [];

        let index -> Int = 0;
        while (index < actual_count) {
            let arg -> ArgNode = args[index];
            let value -> CompileResult = emit_implicit_cast(c, compile_node(c, arg.val), key_type, n_call.pos);
            values.append(value);
            index++;
        }

        let result -> String = next_reg(c);
        if (f_info.compiler_link_name == "typed_dict_hash") {
            let value -> CompileResult = values[0];
            c.output_file.write(c.indent + result + " = call i32 @__wl_typed_dict_hash_" + key_type + "(" + llvm_type + " " + value.reg + ")\n");
            emit_release_owned(c, value);
        } else {
            let left -> CompileResult = values[0];
            let right -> CompileResult = values[1];
            c.output_file.write(c.indent + result + " = call i1 @__wl_typed_dict_equal_" + key_type + "(" + llvm_type + " " + left.reg + ", " + llvm_type + " " + right.reg + ")\n");
            emit_release_owned(c, left); emit_release_owned(c, right);
        }

        emit_release_owned(c, obj_res);
        return CompileResult(reg=result, type=f_info.ret_type);
    }

    if (f_info is !null && f_info.compiler_link_name == "typed_dict_zero") {
        let result -> CompileResult = typed_dict_zero(c, f_info, n_call);
        emit_release_owned(c, obj_res);
        return result;
    }
    if (obj_res.is_const_access && (s_info.is_interface || (f_info is !null && f_info.mutates_self))) {
        throw_type_error(n_call.pos, "Cannot call mutating method '" + method_name + "' through const value");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    
    let func_ptr -> String = "";
    let sig -> String = "";
    let args_str -> String = "";
    let expected_types -> Vector(Struct) = null;
    let ret_type -> Int = 0;
    
    if (s_info.is_interface) {
        sig = interface_method_sig(c, s_info, m_node);
        ret_type = interface_method_type(c, s_info, m_node.return_type);
        expected_types = m_node.params;
        
        let obj_box -> String = obj_res.reg;
        let obj_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + obj_ptr + " = extractvalue { i8*, i8* } " + obj_box + ", 0\n");
        let itable_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + itable_ptr + " = extractvalue { i8*, i8* } " + obj_box + ", 1\n");
        
        emit_method_nullcheck(c, obj_ptr, "i8", method_name, n_call.pos);
        
        let itable_typed_ptr -> String = next_reg(c);
        let itable_type -> String = "[ " + v_len + " x i8* ]";
        c.output_file.write(c.indent + itable_typed_ptr + " = bitcast i8* " + itable_ptr + " to " + itable_type + "*\n");
        
        let method_i8ptr_addr -> String = next_reg(c);
        c.output_file.write(c.indent + method_i8ptr_addr + " = getelementptr inbounds " + itable_type + ", " + itable_type + "* " + itable_typed_ptr + ", i32 0, i32 " + m_idx + "\n");
        
        let method_i8ptr -> String = next_reg(c);
        c.output_file.write(c.indent + method_i8ptr + " = load i8*, i8** " + method_i8ptr_addr + "\n");
        
        func_ptr = next_reg(c);
        c.output_file.write(c.indent + func_ptr + " = bitcast i8* " + method_i8ptr + " to " + sig + "\n");
        
        args_str = "i8* " + obj_ptr;
    } else {
        sig = get_func_sig_str(c, f_info);
        ret_type = f_info.ret_type;
        expected_types = f_info.arg_types;
        
        let class_llvm_ty -> String = s_info.llvm_name;
        let obj_ptr -> String = obj_res.reg;
        
        emit_method_nullcheck(c, obj_ptr, class_llvm_ty, method_name, n_call.pos);
        if (is_generic_class(c, s_info) || generic_method) {
            func_ptr = "@" + f_info.name;
        } else {
            let vptr_addr -> String = next_reg(c);
            c.output_file.write(c.indent + vptr_addr + " = getelementptr inbounds " + class_llvm_ty + ", " + class_llvm_ty + "* " + obj_ptr + ", i32 0, i32 0\n");
        
            let vtable_i8ptr -> String = next_reg(c);
            c.output_file.write(c.indent + vtable_i8ptr + " = load i8*, i8** " + vptr_addr + "\n");

            let vtable_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + vtable_ptr + " = bitcast i8* " + vtable_i8ptr + " to " + class_vtable_type(c, s_info) + "*\n");

            let method_i8ptr_addr -> String = next_reg(c);
            c.output_file.write(c.indent + method_i8ptr_addr + " = getelementptr inbounds " + class_vtable_type(c, s_info) + ", " + class_vtable_type(c, s_info) + "* " + vtable_ptr + ", i32 0, i32 " + m_idx + "\n");

            let method_i8ptr -> String = next_reg(c);
            c.output_file.write(c.indent + method_i8ptr + " = load i8*, i8** " + method_i8ptr_addr + "\n");

            func_ptr = next_reg(c);
            c.output_file.write(c.indent + func_ptr + " = bitcast i8* " + method_i8ptr + " to " + sig + "\n");
        }
        
        let self_type_node -> TypeListNode = expected_types[0];
        let self_expected_type -> Int = self_type_node.type;
        
        c.expected_type = self_expected_type;
        let casted_obj -> CompileResult = emit_implicit_cast(c, obj_res, self_expected_type, n_call.pos);
        c.expected_type = 0;
        
        args_str = get_llvm_type_str(c, self_expected_type) + " " + casted_obj.reg;
    }

    if (!validate_fallible_call(c, ret_type, n_call.preserve_fallible, method_name, n_call.pos)) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    
    let args -> Vector(Struct) = n_call.args;
    let a_len -> Int = 0; if (args is !null) { a_len = args.length(); }
    let owned_args -> Vector(Struct) = [];
    
    let exp_len -> Int = 0;
    if (expected_types is !null) { exp_len = expected_types.length(); }
    if (!s_info.is_interface && exp_len > 0) { exp_len -= 1; }
    
    if (a_len != exp_len) {
        throw_type_error(n_call.pos, "Argument count mismatch in method call. Expected " + exp_len + ", got " + a_len);
        return CompileResult(reg="0", type=ret_type, origin_type=0);
    }
    if (!s_info.is_interface && f_info is !null) {
        args = bind_call_args(args, f_info.arg_names, 1, n_call.pos);
        if (args is null && exp_len > 0) { return CompileResult(reg="poison", type=TYPE_POISON); }
    } else if (s_info.is_interface) {
        let interface_names -> Vector(String) = [];
        let name_index -> Int = 0;
        while (m_node.params is !null && name_index < m_node.params.length()) { let param -> ParamNode = m_node.params[name_index]; interface_names.append(param.name_tok.value); name_index += 1; }
        args = bind_call_args(args, interface_names, 0, n_call.pos);
        if (args is null && exp_len > 0) { return CompileResult(reg="poison", type=TYPE_POISON); }
    }

    let arg_idx -> Int = 0;
    while (arg_idx < a_len) {
        let arg_node_curr -> ArgNode = args[arg_idx];
        let expected_type -> Int = 0;
        
        if (s_info.is_interface) {
            let p_node -> ParamNode = expected_types[arg_idx];
            expected_type = interface_method_type(c, s_info, p_node.type_tok);
        } else {
            let expected_type_node -> TypeListNode = expected_types[arg_idx + 1];
            expected_type = expected_type_node.type;
        }
        
        c.expected_type = expected_type;
        let arg_val -> CompileResult = compile_node(c, arg_node_curr.val);
        c.expected_type = 0;
        if (arg_val is !null && arg_val.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
        let dynamic_key_arg -> Bool = arg_idx == 0 && is_dynamic_dict(s_info) && is_dict_key_method(method_name);
        if (dynamic_key_arg && arg_val is !null && arg_val.type != expected_type && !is_dict_key_type(c, arg_val.type)) {
            throw_type_error(n_call.pos, "Type " + get_type_name(c, arg_val.type) + " cannot be used as a Dict key");
            emit_release_owned(c, arg_val);
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        arg_val = emit_implicit_cast(c, arg_val, expected_type, n_call.pos);
        
        let ty_str -> String = get_llvm_type_str(c, arg_val.type);
        args_str = args_str + ", " + ty_str + " " + arg_val.reg;
        if (arg_val.owns_ref) { owned_args.append(arg_val); }
        
        arg_idx += 1;
    }
    
    let llvm_ret_type -> String = get_llvm_type_str(c, ret_type);
    if (ret_type == TYPE_VOID) {
        c.output_file.write(c.indent + "call " + llvm_ret_type + " " + func_ptr + "(" + args_str + ")\n");
        emit_release_owned_args(c, owned_args);
        emit_release_owned(c, obj_res);
        return CompileResult(reg="", type=TYPE_VOID, origin_type=0);
    } else {
        let call_res -> String = next_reg(c);
        c.output_file.write(c.indent + call_res + " = call " + llvm_ret_type + " " + func_ptr + "(" + args_str + ")\n");
        emit_release_owned_args(c, owned_args);
        emit_release_owned(c, obj_res);
        return CompileResult(reg=call_res, type=ret_type, origin_type=0, owns_ref=result_owns_value(c, ret_type), is_const_access=obj_res.is_const_access);
    }
}

func compile_dict_intrinsic(c -> Compiler, info -> FuncInfo, node -> CallNode) -> CompileResult {
    let args -> Vector(Struct) = node.args;
    let count -> Int = 0;
    if (args is !null) { count = args.length(); }
    let expected -> Int = 1;
    if (info.compiler_link_name == "dict_keys_equal") { expected = 2; }
    if (count != expected) {
        throw_type_error(node.pos, "Argument count mismatch. Expected " + expected + ", got " + count);
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    if (reject_named_args(args, node.pos, "a compiler intrinsic")) { return CompileResult(reg="poison", type=TYPE_POISON); }

    let variant_info -> StructInfo = c.struct_table.get("$Variant");
    if (variant_info is null) {
        throw_internal_compiler_error(node.pos, "Variant is not registered.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let values -> Vector(Struct) = [];
    let i -> Int = 0;
    while (i < count) {
        let arg -> ArgNode = args[i];
        let old_expected -> Int = c.expected_type;
        c.expected_type = variant_info.type_id;
        let value -> CompileResult = compile_node(c, arg.val);
        c.expected_type = old_expected;
        if (value is null || value.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
        value = emit_implicit_cast(c, value, variant_info.type_id, node.pos);
        values.append(value);
        i++;
    }

    let result -> String = next_reg(c);
    if (info.compiler_link_name == "dict_key_hash") {
        let value -> CompileResult = values[0];
        c.output_file.write(c.indent + result + " = call i32 @__wl_dict_key_hash(%struct.$Variant* " + value.reg + ")\n");
        emit_release_owned(c, value);
        return CompileResult(reg=result, type=TYPE_INT);
    }

    let left -> CompileResult = values[0];
    let right -> CompileResult = values[1];
    c.output_file.write(c.indent + result + " = call i1 @__wl_dict_keys_equal(%struct.$Variant* " + left.reg + ", %struct.$Variant* " + right.reg + ")\n");
    emit_release_owned(c, left);
    emit_release_owned(c, right);
    return CompileResult(reg=result, type=TYPE_BOOL);
}

func compile_local_closure(c -> Compiler, func_def -> FunctionDefNode) -> CompileResult {
    let scope -> CaptureScope = CaptureScope(local_vars=Dict(32), captured_vars=Dict(32), captured_list=[]);
    let params -> Vector(Struct) = func_def.params;
    let p_len -> Int = 0; if (params is !null) { p_len = params.length(); }
    let p_i -> Int = 0;
    while (p_i < p_len) {
        let p_node -> ParamNode = params[p_i];
        scope.local_vars.put(p_node.name_tok.value, TypeListNode(type=1));
        p_i += 1;
    }
    if (func_def.name_tok.value.length() > 0) { scope.local_vars.put(func_def.name_tok.value, TypeListNode(type=1)); }

    analyze_captures(func_def.body, scope);
    
    let captures -> Vector(String) = [];
    let capture_types -> Vector(Struct) = [];
    
    let c_i -> Int = 0;
    let cap_len -> Int = scope.captured_list.length();
    while (c_i < cap_len) {
        let v_name -> String = scope.captured_list[c_i];
        let is_global -> Bool = false;
        if (c.global_symbol_table.get(v_name) is !null) { is_global = true; }
        if (c.func_table.get(v_name) is !null) { is_global = true; }
        if (c.struct_table.get(v_name) is !null) { is_global = true; }
        if (c.current_file_global_aliases.get(v_name) is !null) { is_global = true; }
        if (c.current_file_func_aliases.get(v_name) is !null) { is_global = true; }
        if (c.current_file_type_aliases.get(v_name) is !null) { is_global = true; }
        if (c.current_package_prefix != "") {
            if (c.global_symbol_table.get(c.current_package_prefix + v_name) is !null) { is_global = true; }
            if (c.func_table.get(c.current_package_prefix + v_name) is !null) { is_global = true; }
            if (c.struct_table.get(c.current_package_prefix + v_name) is !null) { is_global = true; }
        }
        if (is_visible_namespace(c, v_name)) { is_global = true; }

        if (!is_global) {
            let info -> SymbolInfo = find_symbol(c, v_name);
            if (info is null) {
                throw_name_error(func_def.pos, "Cannot capture undefined variable '" + v_name + "'.");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            captures.append(v_name); 
            capture_types.append(TypeListNode(type=info.type));
        }
        c_i += 1;
    }

    let env_id -> Int = c.type_counter;
    c.type_counter += 1;

    let t_len -> Int = captures.length();
    let env_struct_name -> String = "env." + env_id;
    let env_body -> String = "";
    let env_fields -> Vector(Struct) = [];
    let t_i -> Int = 0;
    while (t_i < t_len) {
        let t_node -> TypeListNode = capture_types[t_i];
        let f_llvm -> String = get_llvm_type_str(c, t_node.type);
        if (t_i > 0) { env_body += ", "; }
        env_body += f_llvm;
        env_fields.append(FieldInfo(name=captures[t_i], type=t_node.type, llvm_type=f_llvm, offset=t_i));
        t_i += 1;
    }
    let llvm_env_name -> String = "{ " + env_body + " }";

    let env_info -> StructInfo = StructInfo(name=env_struct_name, type_id=env_id, fields=env_fields, llvm_name=llvm_env_name, init_body=null, is_class=false, vtable_name="", parent_id=0, vtable=null, is_enum=false, is_error=false, is_interface=false, interfaces=null, ann_flags=0, compiler_link_name="");
    c.struct_id_map.put("" + env_id, env_info);
    c.type_drop_list.append(TypeListNode(type=env_id));

    let size_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr " + llvm_env_name + ", " + llvm_env_name + "* null, i32 1\n");
    let env_size -> String = next_reg(c);
    c.output_file.write(c.indent + env_size + " = ptrtoint " + llvm_env_name + "* " + size_ptr + " to " + get_size_llvm_type() + "\n");
    let env_payload -> String = emit_alloc_obj(c, env_size, "" + env_id, llvm_env_name + "*");

    let env_payload_i8 -> String = next_reg(c);
    c.output_file.write(c.indent + env_payload_i8 + " = bitcast " + llvm_env_name + "* " + env_payload + " to i8*\n");

    t_i = 0;
    while (t_i < t_len) {
        let v_name -> String = captures[t_i];
        let t_node -> TypeListNode = capture_types[t_i];
        let v_type -> Int = t_node.type;
        let llvm_ty -> String = get_llvm_type_str(c, v_type);
        let info -> SymbolInfo = find_symbol(c, v_name);
        
        let val_reg -> String = next_reg(c);
        c.output_file.write(c.indent + val_reg + " = load " + llvm_ty + ", " + llvm_ty + "* " + info.reg + "\n");
        
        let slot_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + llvm_env_name + ", " + llvm_env_name + "* " + env_payload + ", i32 0, i32 " + t_i + "\n");
        c.output_file.write(c.indent + "store " + llvm_ty + " " + val_reg + ", " + llvm_ty + "* " + slot_ptr + "\n");
        if (needs_drop(c, v_type)) { emit_retain_slot(c, slot_ptr, v_type); }
        t_i += 1;
    }

    let old_file -> file.File = c.output_file;

    let temp_dir -> String = "";
    if (get_target_os() == sys.Os.Windows) {
        temp_dir = sys.env.get_env("TMP");
        if (temp_dir is null) { temp_dir = sys.env.get_env("TEMP"); }
        if (temp_dir is null) { temp_dir = "."; }
        if (!temp_dir.ends_with("\\") && !temp_dir.ends_with("/")) {
            temp_dir += "\\";
        }
    } else {
        temp_dir = "/tmp/";
    }

    let tmp_name -> String = temp_dir + "wl_lambda_tmp_" + process.id() + "_" + env_id + ".ll";
    
    c.output_file = file.create(tmp_name)?;
    catch(err) {
        throw_internal_compiler_error(func_def.pos, "Cannot create closure IR file '" + tmp_name + "' (error " + Int(err) + ").");
        return void_result();
    }
    
    let lambda_name -> String = "lambda." + func_def.name_tok.value + "." + env_id;
    let ret_type_id -> Int = resolve_type(c, func_def.ret_type_tok);
    if (ret_type_id == TYPE_AUTO) { throw_type_error(func_def.pos, "Auto return type deduction is not supported in closures."); return void_result(); }
    let ret_ty_str -> String = get_llvm_type_str(c, ret_type_id);
    let arg_types -> Vector(Struct) = [];
    p_i = 0;
    while (p_i < p_len) {
        let p_node -> ParamNode = params[p_i];
        arg_types.append(TypeListNode(type=resolve_type(c, p_node.type_tok)));
        p_i += 1;
    }
    let specific_type_id -> Int = get_func_type_id(c, arg_types, ret_type_id);
    let sig_def -> String = "i8* %raw_env";
    let sig_ty -> String = "i8*";
    p_i = 0;
    while (p_i < p_len) {
        let p_node -> ParamNode = params[p_i];
        let p_ty -> String = get_llvm_type_str(c, resolve_type(c, p_node.type_tok));
        sig_def = sig_def + ", " + p_ty + " %arg" + p_i;
        sig_ty = sig_ty + ", " + p_ty;
        p_i += 1;
    }
    
    c.output_file.write("define internal " + ret_ty_str + " @" + lambda_name + "(" + sig_def + ") {\nentry:\n");
    let old_sym -> Scope = c.symbol_table;
    let old_depth -> Int = c.scope_depth;
    let old_reg -> Int = c.reg_count;
    let old_ret -> Int = c.current_ret_type;
    let old_alloc_regs -> Vector(String) = c.alloc_regs;
    let old_hoist_scope -> Scope = c.hoist_scope;
    
    c.symbol_table = Scope(table=Dict(32), parent=null, gc_vars=[], depth=0);
    c.scope_depth = 1;
    c.reg_count = 1;
    c.current_ret_type = ret_type_id;

    if (func_def.name_tok.value.length() > 0) {
        let self_storage -> String = next_reg(c);
        let self_function_slot -> String = next_reg(c);
        let self_environment_slot -> String = next_reg(c);
        let self_function -> String = next_reg(c);
        let self_closure -> String = next_reg(c);
        let self_address -> String = next_reg(c);
        c.output_file.write("  " + self_storage + " = alloca [2 x i8*]\n");
        c.output_file.write("  " + self_function_slot + " = getelementptr inbounds [2 x i8*], [2 x i8*]* " + self_storage + ", i32 0, i32 0\n");
        c.output_file.write("  " + self_environment_slot + " = getelementptr inbounds [2 x i8*], [2 x i8*]* " + self_storage + ", i32 0, i32 1\n");
        c.output_file.write("  " + self_function + " = bitcast " + ret_ty_str + " (" + sig_ty + ")* @" + lambda_name + " to i8*\n");
        c.output_file.write("  store i8* " + self_function + ", i8** " + self_function_slot + "\n");
        c.output_file.write("  store i8* %raw_env, i8** " + self_environment_slot + "\n");
        c.output_file.write("  " + self_closure + " = bitcast [2 x i8*]* " + self_storage + " to i8*\n");
        c.output_file.write("  " + self_address + " = alloca i8*\n");
        c.output_file.write("  store i8* " + self_closure + ", i8** " + self_address + "\n");
        c.symbol_table.table.put(func_def.name_tok.value, SymbolInfo(reg=self_address, type=specific_type_id, origin_type=ret_type_id, is_const=true));
    }

    let lambda_env_ptr -> String = "%lambda_env_ptr";
    c.output_file.write("  " + lambda_env_ptr + " = bitcast i8* %raw_env to " + llvm_env_name + "*\n");

    t_i = 0;
    while (t_i < t_len) {
        let v_name -> String = captures[t_i];
        let t_node -> TypeListNode = capture_types[t_i];
        let v_type -> Int = t_node.type;
        let llvm_ty -> String = get_llvm_type_str(c, v_type);

        let slot_ptr -> String = "%env.slot." + t_i;
        c.output_file.write("  " + slot_ptr + " = getelementptr inbounds " + llvm_env_name + ", " + llvm_env_name + "* " + lambda_env_ptr + ", i32 0, i32 " + t_i + "\n");

        c.symbol_table.table.put(v_name, SymbolInfo(reg=slot_ptr, type=v_type, origin_type=v_type, is_const=false));
        t_i += 1;
    }
    
    p_i = 0;
    while (p_i < p_len) {
        let p_node -> ParamNode = params[p_i];
        let p_ty_id -> Int = resolve_type(c, p_node.type_tok);
        let p_ty -> String = get_llvm_type_str(c, p_ty_id);
        let addr_reg -> String = next_reg(c);
        c.output_file.write("  " + addr_reg + " = alloca " + p_ty + "\n");
        c.output_file.write("  store " + p_ty + " %arg" + p_i + ", " + p_ty + "* " + addr_reg + "\n");
        c.symbol_table.table.put(p_node.name_tok.value, SymbolInfo(reg=addr_reg, type=p_ty_id, origin_type=p_ty_id, is_const=false));
        if (needs_drop(c, p_ty_id)) {
            emit_retain_slot(c, addr_reg, p_ty_id);
            c.symbol_table.gc_vars.append(GCTracker(reg=addr_reg, type=p_ty_id));
        }
        p_i += 1;
    }
    
    c.hoist_scope = Scope(parent=null, table=Dict(32), gc_vars=[], depth=0);
    c.alloc_regs = [];
    hoist_allocas(c, func_def.body);
    check_local_init(c, func_def.body);
    let lambda_terminates -> Bool = must_terminate(c, func_def.body);
    compile_node(c, func_def.body);
    
    if (!lambda_terminates) {
        cleanup_all_scopes(c);
        if (ret_type_id == TYPE_VOID) {
            c.output_file.write("  ret void\n");
        } else {
            let zero_val -> String = "0";
            if (ret_type_id == TYPE_FLOAT) { zero_val = "0.0"; }
            else if (is_nullable_reference_type(c, ret_type_id)) { zero_val = "null"; }
            c.output_file.write("  ret " + ret_ty_str + " " + zero_val + "\n");
        }
    }
    c.output_file.write("}\n\n");
    
    c.symbol_table = old_sym;
    c.scope_depth = old_depth;
    c.reg_count = old_reg;
    c.current_ret_type = old_ret;
    c.alloc_regs = old_alloc_regs;
    c.hoist_scope = old_hoist_scope;
    
    c.output_file.close();
    c.output_file = old_file;
    let tmp_read -> file.File = file.open(tmp_name)?;
    catch(err) {
        throw_internal_compiler_error(func_def.pos, "Cannot reopen closure IR file '" + tmp_name + "' (error " + Int(err) + ").");
        return void_result();
    }
    let lambda_ir -> String = tmp_read.read_all()?;
    catch(err) {
        throw_internal_compiler_error(func_def.pos, "Cannot read closure IR file '" + tmp_name + "' (error " + Int(err) + ").");
        return void_result();
    }
    tmp_read.close();
    file.remove(tmp_name)?;
    catch(err) { }

    c.global_buffer = c.global_buffer + lambda_ir;

    let clo_payload -> String = emit_alloc_closure(c, specific_type_id);

    let clo_func_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + clo_func_ptr + " = bitcast i8* " + clo_payload + " to i8**\n");
    
    let lambda_casted -> String = next_reg(c);
    c.output_file.write(c.indent + lambda_casted + " = bitcast " + ret_ty_str + " (" + sig_ty + ")* @" + lambda_name + " to i8*\n");
    c.output_file.write(c.indent + "store i8* " + lambda_casted + ", i8** " + clo_func_ptr + "\n");

    let clo_env_ptr_i8 -> String = next_reg(c);
    c.output_file.write(c.indent + clo_env_ptr_i8 + " = getelementptr inbounds i8, i8* " + clo_payload + ", i32 " + closure_env_offset() + "\n");
    let clo_env_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + clo_env_ptr + " = bitcast i8* " + clo_env_ptr_i8 + " to i8**\n");
    c.output_file.write(c.indent + "store i8* " + env_payload_i8 + ", i8** " + clo_env_ptr + "\n");
    c.output_file.write(c.indent + "call void @__wl_retain(i8* " + env_payload_i8 + ")\n");

    emit_retain(c, clo_payload, specific_type_id);
    return CompileResult(reg=clo_payload, type=specific_type_id, origin_type=ret_type_id);
}

func compile_return(c -> Compiler, node -> ReturnNode) -> CompileResult {
    if (node.value is !null) {
        // return void check
        if (c.current_ret_type == TYPE_VOID) {
            throw_type_error(node.pos, "Void function cannot return a value. ");
            return void_result();
        }

        c.expected_type = c.current_ret_type;
        let res -> CompileResult = compile_node(c, node.value);
        c.expected_type = 0;

        if (res.type == TYPE_NULLPTR) {
            if (!is_pointer_type(c, c.current_ret_type)) {
                throw_type_error(node.pos, "'nullptr' can only be returned for explicit pointer types.");
                return void_result();
            }
            res.type = c.current_ret_type;
        } else if (res.type == TYPE_NULL) {
            if (is_pointer_type(c, c.current_ret_type)) {
                throw_type_error(node.pos, "'null' cannot be returned for explicit pointer types. Use 'nullptr'.");
                return void_result();
            }
            if (is_primitive_type(c.current_ret_type)) {
                throw_type_error(node.pos, "Primitive types cannot be null.");
                return void_result();
            }
            res.type = c.current_ret_type;
        }

        let is_ret_fallible -> Bool = is_fallible_type(c, c.current_ret_type);
        let inner_ret_type -> Int = c.current_ret_type;
        if is_ret_fallible {
            inner_ret_type = get_inner_fallible_type(c, c.current_ret_type);
        }

        if is_ret_fallible {
            res = emit_implicit_cast(c, res, inner_ret_type, node.pos);
        } else {
            res = emit_implicit_cast(c, res, c.current_ret_type, node.pos);
        }

        let ret_val_reg -> String = res.reg;
        let target_ty -> String = get_llvm_type_str(c, c.current_ret_type);

        if is_ret_fallible {
            let ret_val_1 -> String = next_reg(c);
            c.output_file.write(c.indent + ret_val_1 + " = insertvalue " + target_ty + " undef, i1 false, 0\n");
            let ret_val_2 -> String = next_reg(c);
            c.output_file.write(c.indent + ret_val_2 + " = insertvalue " + target_ty + " " + ret_val_1 + ", { i64, i32 } zeroinitializer, 1\n");
            
            if (inner_ret_type != TYPE_VOID) {
                let ret_val_3 -> String = next_reg(c);
                let inner_llvm_ty -> String = get_llvm_type_str(c, inner_ret_type);
                c.output_file.write(c.indent + ret_val_3 + " = insertvalue " + target_ty + " " + ret_val_2 + ", " + inner_llvm_ty + " " + ret_val_reg + ", 2\n");
                ret_val_reg = ret_val_3;
            } else {
                ret_val_reg = ret_val_2;
            }
        }

        if (needs_drop(c, inner_ret_type) && !res.owns_ref) {
            emit_retain_value(c, res.reg, inner_ret_type);
        }

        cleanup_all_scopes(c);

        c.output_file.write(c.indent + "ret " + target_ty + " " + ret_val_reg + "\n");
    } else {
        if (c.current_ret_type != TYPE_VOID) {
            if (is_fallible_type(c, c.current_ret_type)) {
                let inner -> Int = get_inner_fallible_type(c, c.current_ret_type);
                if (inner == TYPE_VOID) {
                    let target_ty -> String = get_llvm_type_str(c, c.current_ret_type);
                    let ret_val_1 -> String = next_reg(c);
                    c.output_file.write(c.indent + ret_val_1 + " = insertvalue " + target_ty + " undef, i1 false, 0\n");
                    let ret_val_2 -> String = next_reg(c);
                    c.output_file.write(c.indent + ret_val_2 + " = insertvalue " + target_ty + " " + ret_val_1 + ", { i64, i32 } zeroinitializer, 1\n");
                    cleanup_all_scopes(c);
                    c.output_file.write(c.indent + "ret " + target_ty + " " + ret_val_2 + "\n");
                    return void_result();
                }
            }
            throw_type_error(node.pos, "Non-void function must return a value. ");
            return void_result();
        }
        cleanup_all_scopes(c);
        c.output_file.write(c.indent + "ret void\n");
    }
    
    return void_result();
}

func compile_struct_def(c -> Compiler, node -> StructDefNode) -> CompileResult {
    if (node.type_params is !null && node.type_params.length() > 0) { return void_result(); }

    let raw_name -> String = node.name_tok.value;
    let struct_name -> String = c.current_package_prefix + raw_name;

    let info -> StructInfo = c.struct_table.get(struct_name);
    if (info is null) {
        throw_type_error(node.pos, "Struct info missing for '" + struct_name + "'.");
        return void_result();
    }

    if ((info.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
        return void_result();
    }

    let full_name -> String = "struct." + struct_name;
    if (c.struct_table.get(full_name) is !null) {
        throw_import_error(node.pos, "Struct '" + struct_name + "' is already defined in another module.");
        return void_result();
    }

    let llvm_body -> String = "";
    let fields_vec -> Vector(Struct) = [];
    
    let fields -> Vector(Struct) = node.fields;
    let f_len -> Int = 0; if (fields is !null) { f_len = fields.length(); }
    let idx -> Int = 0;
    let field_names -> Dict = Dict(8);
    
    while (idx < f_len) {
        let p -> ParamNode = fields[idx];
        let f_name -> String = p.name_tok.value;
        if (field_names.contains_key(f_name)) { throw_name_error(p.pos, "field '" + f_name + "' is already defined in struct '" + struct_name + "'"); return void_result(); }
        field_names.put(f_name, StringConstant(id=0, value=f_name));
        let f_type_id -> Int = resolve_type(c, p.type_tok);
        if (f_type_id == TYPE_AUTO) {
            throw_type_error(node.pos, "struct fields cannot use 'Auto' because they lack initializers for static deduction.");
            return void_result();
        }

        let f_llvm_type -> String = get_llvm_type_str(c, f_type_id);
        if (idx > 0) { llvm_body = llvm_body + ", "; }
        llvm_body += f_llvm_type;
        
        fields_vec.append(FieldInfo(name=f_name, type=f_type_id, llvm_type=f_llvm_type, offset=idx, is_const=false));
        idx += 1;
    }

    info.fields = fields_vec;

    // %struct.Test = type { i32, i32 }
    let def_str -> String = info.llvm_name + " = type { " + llvm_body + " }\n\n";
    c.output_file.write(def_str);
    
    return void_result();
}

func compile_struct_init(c -> Compiler, s_info -> StructInfo, n_call -> CallNode) -> CompileResult {
    let size_ty -> String = get_size_llvm_type();
    let size_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr " + s_info.llvm_name + ", " + s_info.llvm_name + "* null, " + size_ty + " 1\n");
    let object_size -> String = next_reg(c);
    c.output_file.write(c.indent + object_size + " = ptrtoint " + s_info.llvm_name + "* " + size_ptr + " to " + size_ty + "\n");
    let obj_ptr -> String = emit_alloc_obj(c, object_size, "" + s_info.type_id, s_info.llvm_name + "*");

    let fields_vec -> Vector(Struct) = s_info.fields;
    let f_len -> Int = 0;
    if (fields_vec is !null) { f_len = fields_vec.length(); }
    let f_idx -> Int = 0;
    
    while (f_idx < f_len) {
        let f_curr -> FieldInfo = fields_vec[f_idx];
        let f_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + obj_ptr + ", i32 0, i32 " + f_curr.offset + "\n");
        let zero_val -> String = "0";
        if (f_curr.type == TYPE_FLOAT) { zero_val = "0.0"; }
        else {
            let field_info -> StructInfo = c.struct_id_map.get("" + f_curr.type);
            let field_array -> ArrayInfo = c.array_info_map.get("" + f_curr.type);
            if (is_fallible_type(c, f_curr.type) ||
                (field_info is !null && field_info.is_interface) ||
                (field_array is !null && field_array.size >= 0)) {
                zero_val = "zeroinitializer";
            } else if (is_nullable_reference_type(c, f_curr.type)) {
                zero_val = "null";
            }
        }
        
        c.output_file.write(c.indent + "store " + f_curr.llvm_type + " " + zero_val + ", " + f_curr.llvm_type + "* " + f_ptr + "\n");
        
        f_idx += 1;
    }

    if (s_info.init_body is !null) {
        let template -> GenericTemplate = c.generic_instance_templates.get("" + s_info.type_id);
        let previous_bindings -> Dict = c.generic_bindings;
        let previous -> GenericTemplate = null;
        if (template is !null) {
            let bindings -> Dict = c.generic_instance_bindings.get("" + s_info.type_id);
            previous = use_generic_context(c, template, bindings);
        }
        enter_scope(c);
        let this_ptr_addr -> String = next_reg(c);
        let struct_ptr_ty -> String = s_info.llvm_name + "*";
        
        c.output_file.write(c.indent + this_ptr_addr + " = alloca " + struct_ptr_ty + "\n");
        c.output_file.write(c.indent + "store " + struct_ptr_ty + " " + obj_ptr + ", " + struct_ptr_ty + "* " + this_ptr_addr + "\n");
        c.symbol_table.table.put("this", SymbolInfo(reg=this_ptr_addr, type=s_info.type_id, origin_type=s_info.type_id));
        compile_node(c, s_info.init_body);
        exit_scope(c);
        if (template is !null) {
            restore_generic_context(c, previous, previous_bindings);
        }
    }

    let args -> Vector(Struct) = n_call.args;
    let a_len -> Int = 0;
    if (args is !null) { a_len = args.length(); }
    if (a_len > f_len) {
        throw_type_error(n_call.pos, "struct '" + s_info.name + "' accepts at most " + f_len + " arguments, got " + a_len);
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    let arg_idx -> Int = 0;
    let assigned_fields -> Dict = Dict(8);
    let saw_named -> Bool = false;
    
    while (arg_idx < a_len) {
        let arg_curr -> ArgNode = args[arg_idx];

        let target_f -> FieldInfo = null;
        if (arg_curr.name is !null) {
            saw_named = true;
            target_f = find_field(s_info, arg_curr.name);
            if (target_f is null) { throw_name_error(n_call.pos, "struct '" + s_info.name + "' has no field '" + arg_curr.name + "'"); return CompileResult(reg="poison", type=TYPE_POISON); }
        } else {
            if (saw_named) { throw_invalid_syntax(n_call.pos, "Positional argument cannot follow a named argument"); return CompileResult(reg="poison", type=TYPE_POISON); }
            target_f = get_field_by_index(s_info, arg_idx);
        }
        if (target_f is null) { throw_type_error(n_call.pos, "Too many arguments for struct '" + s_info.name + "'"); return CompileResult(reg="poison", type=TYPE_POISON); }
        if (assigned_fields.contains_key(target_f.name)) { throw_name_error(n_call.pos, "Field '" + target_f.name + "' is initialized more than once"); return CompileResult(reg="poison", type=TYPE_POISON); }
        assigned_fields.put(target_f.name, StringConstant(id=0, value=target_f.name));

        if (target_f is !null) { c.expected_type = target_f.type; }
        let val_res -> CompileResult = compile_node(c, arg_curr.val);
        c.expected_type = 0;

        if (target_f is !null) {
            val_res = emit_implicit_cast(c, val_res, target_f.type, n_call.pos);
            if (val_res.type != TYPE_POISON) {
                let f_ptr -> String = next_reg(c);
                c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + obj_ptr + ", i32 0, i32 " + target_f.offset + "\n");
                if (result_owns_value(c, target_f.type) && !val_res.owns_ref) {
                    emit_retain_value(c, val_res.reg, target_f.type);
                }
                c.output_file.write(c.indent + "store " + target_f.llvm_type + " " + val_res.reg + ", " + target_f.llvm_type + "* " + f_ptr + "\n");
            }
        }
        arg_idx += 1;
    }
    return CompileResult(reg=obj_ptr, type=s_info.type_id);
}

struct InitFlow(
    initialized -> Vector(String),
    terminates  -> Bool
)

struct LocalInitScope(
    table -> Dict,
    parent -> Struct,
    declarations -> Vector(Struct)
)

func init_has(initialized -> Vector(String), name -> String) -> Bool {
    let i -> Int = 0;
    while (i < initialized.length()) {
        if (initialized[i] == name) { return true; }
        i += 1;
    }
    return false;
}

func init_add(initialized -> Vector(String), name -> String) -> Void {
    if (!init_has(initialized, name)) { initialized.append(name); }
}

func init_copy(initialized -> Vector(String)) -> Vector(String) {
    let copy -> Vector(String) = [];
    let i -> Int = 0;
    while (i < initialized.length()) {
        copy.append(initialized[i]);
        i += 1;
    }
    return copy;
}

func init_intersection(left -> Vector(String), right -> Vector(String)) -> Vector(String) {
    let result -> Vector(String) = [];
    let i -> Int = 0;
    while (i < left.length()) {
        if (init_has(right, left[i])) { result.append(left[i]); }
        i += 1;
    }
    return result;
}

func init_without(initialized -> Vector(String), removed -> Vector(String)) -> Vector(String) {
    let result -> Vector(String) = [];
    let i -> Int = 0;
    while (i < initialized.length()) {
        if (!init_has(removed, initialized[i])) { result.append(initialized[i]); }
        i += 1;
    }
    return result;
}

func local_init_key(node -> VarDeclareNode) -> String {
    return "" + node.alloc_id;
}

func bind_local_init(scope -> LocalInitScope, node -> VarDeclareNode) -> Void {
    scope.table.put(node.name_tok.value, SymbolInfo(reg="", type=node.alloc_id + 1, origin_type=0, is_const=node.is_const));
    scope.declarations.append(node);
}

func lookup_local_init(scope -> LocalInitScope, name -> String) -> String {
    let current -> LocalInitScope = scope;
    while (current is !null) {
        let info -> SymbolInfo = current.table.get(name);
        if (info is !null) {
            if (info.type <= 0) { return ""; }
            return "" + (info.type - 1);
        }
        current = current.parent;
    }
    return "";
}

func read_local_init(scope -> LocalInitScope, initialized -> Vector(String), name -> String, pos -> Position) -> Void {
    let key -> String = lookup_local_init(scope, name);
    if (key.length() == 0 || init_has(initialized, key)) { return; }
    throw_missing_initializer(pos, "Variable '" + name + "' may be used before initialization.");
    init_add(initialized, key);
}

func merge_local_init(before -> Vector(String), success -> InitFlow, failure -> InitFlow) -> InitFlow {
    if (success.terminates && failure.terminates) { return InitFlow(before, true); }
    if (success.terminates) { return InitFlow(failure.initialized, false); }
    if (failure.terminates) { return InitFlow(success.initialized, false); }
    return InitFlow(init_intersection(success.initialized, failure.initialized), false);
}

func check_local_init_block(c -> Compiler, node -> BlockNode, parent -> LocalInitScope, initialized -> Vector(String)) -> InitFlow {
    let scope -> LocalInitScope = LocalInitScope(table=Dict(32), parent=parent, declarations=[]);
    let state -> Vector(String) = initialized;
    let terminates -> Bool = false;
    let i -> Int = 0;
    while (node.stmts is !null && i < node.stmts.length()) {
        let flow -> InitFlow = check_local_init_node(c, node.stmts[i], scope, state);
        state = flow.initialized;
        if (flow.terminates) { terminates = true; break; }
        i += 1;
    }

    let local_keys -> Vector(String) = [];
    i = 0;
    while (i < scope.declarations.length()) {
        let declaration -> VarDeclareNode = scope.declarations[i];
        let key -> String = local_init_key(declaration);
        local_keys.append(key);
        if (!terminates && !init_has(state, key)) {
            throw_missing_initializer(declaration.pos, "Local variable '" + declaration.name_tok.value + "' is not initialized on every path.");
            init_add(state, key);
        }
        i += 1;
    }
    return InitFlow(init_without(state, local_keys), terminates);
}

func check_local_init_node(c -> Compiler, node -> Struct, scope -> LocalInitScope, initialized -> Vector(String)) -> InitFlow {
    if (node is null) { return InitFlow(initialized, false); }
    let base -> BaseNode = node;

    if (base.type == NODE_BLOCK) { return check_local_init_block(c, node, scope, initialized); }
    if (base.type == NODE_VAR_ACCESS) {
        let access -> VarAccessNode = node;
        read_local_init(scope, initialized, access.name_tok.value, access.pos);
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_VAR_DECL) {
        let declaration -> VarDeclareNode = node;
        let value_flow -> InitFlow = check_local_init_node(c, declaration.value, scope, initialized);
        bind_local_init(scope, declaration);
        init_add(value_flow.initialized, local_init_key(declaration));
        return InitFlow(value_flow.initialized, false);
    }
    if (base.type == NODE_VAR_ASSIGN) {
        let assignment -> VarAssignNode = node;
        let value_flow -> InitFlow = check_local_init_node(c, assignment.value, scope, initialized);
        let key -> String = lookup_local_init(scope, assignment.name_tok.value);
        if (key.length() > 0) { init_add(value_flow.initialized, key); }
        return InitFlow(value_flow.initialized, false);
    }
    if (base.type == NODE_CATCH) {
        let caught -> CatchNode = node;
        let before -> Vector(String) = init_copy(initialized);
        let success -> InitFlow = check_local_init_node(c, caught.stmt, scope, init_copy(initialized));
        let failure -> InitFlow = check_local_init_block(c, caught.body, scope, init_copy(before));
        return merge_local_init(before, success, failure);
    }
    if (base.type == NODE_IF) {
        let branch -> IfNode = node;
        let condition_flow -> InitFlow = check_local_init_node(c, branch.condition, scope, initialized);
        let selected -> Int = fold_target_cond(c, branch.condition);
        let condition -> BaseNode = branch.condition;
        if (condition is !null && condition.type == NODE_BOOL) {
            let boolean -> BooleanNode = branch.condition;
            selected = boolean.value;
        }
        if (selected == 1) { return check_local_init_node(c, branch.body, scope, condition_flow.initialized); }
        if (selected == 0) { return check_local_init_node(c, branch.else_body, scope, condition_flow.initialized); }
        let then_flow -> InitFlow = check_local_init_node(c, branch.body, scope, init_copy(condition_flow.initialized));
        let else_flow -> InitFlow = InitFlow(init_copy(condition_flow.initialized), false);
        if (branch.else_body is !null) { else_flow = check_local_init_node(c, branch.else_body, scope, init_copy(condition_flow.initialized)); }
        return merge_local_init(condition_flow.initialized, then_flow, else_flow);
    }
    if (base.type == NODE_WHILE) {
        let loop -> WhileNode = node;
        let condition_flow -> InitFlow = check_local_init_node(c, loop.condition, scope, initialized);
        check_local_init_node(c, loop.body, scope, init_copy(condition_flow.initialized));
        return InitFlow(condition_flow.initialized, must_terminate(c, node));
    }
    if (base.type == NODE_FOR) {
        let loop -> ForNode = node;
        let state -> Vector(String) = initialized;
        if (loop.init is !null) { state = check_local_init_node(c, loop.init, scope, state).initialized; }
        state = check_local_init_node(c, loop.cond, scope, state).initialized;
        let body_flow -> InitFlow = check_local_init_node(c, loop.body, scope, init_copy(state));
        if (!body_flow.terminates) { check_local_init_node(c, loop.step, scope, body_flow.initialized); }
        return InitFlow(state, must_terminate(c, node));
    }
    if (base.type == NODE_RETURN) {
        let statement -> ReturnNode = node;
        check_local_init_node(c, statement.value, scope, initialized);
        return InitFlow(initialized, true);
    }
    if (base.type == NODE_THROW) {
        let statement -> ThrowNode = node;
        check_local_init_node(c, statement.value, scope, initialized);
        return InitFlow(initialized, true);
    }
    if (base.type == NODE_BREAK || base.type == NODE_CONTINUE) { return InitFlow(initialized, true); }
    if (base.type == NODE_BINOP || base.type == NODE_IS || base.type == NODE_IS_NOT) {
        let binary -> BinOpNode = node;
        let left_flow -> InitFlow = check_local_init_node(c, binary.left, scope, initialized);
        return check_local_init_node(c, binary.right, scope, left_flow.initialized);
    }
    if (base.type == NODE_UNARYOP) {
        let unary -> UnaryOpNode = node;
        return check_local_init_node(c, unary.node, scope, initialized);
    }
    if (base.type == NODE_POSTFIX) {
        let postfix -> PostfixOpNode = node;
        return check_local_init_node(c, postfix.node, scope, initialized);
    }
    if (base.type == NODE_REF) {
        let reference -> RefNode = node;
        return check_local_init_node(c, reference.node, scope, initialized);
    }
    if (base.type == NODE_DEREF) {
        let dereference -> DerefNode = node;
        return check_local_init_node(c, dereference.node, scope, initialized);
    }
    if (base.type == NODE_TRY_UNWRAP) {
        let unwrap -> TryUnwrapNode = node;
        return check_local_init_node(c, unwrap.expr, scope, initialized);
    }
    if (base.type == NODE_CALL) {
        let call -> CallNode = node;
        let state -> Vector(String) = check_local_init_node(c, call.callee, scope, initialized).initialized;
        let i -> Int = 0;
        while (call.args is !null && i < call.args.length()) {
            let arg -> ArgNode = call.args[i];
            state = check_local_init_node(c, arg.val, scope, state).initialized;
            i += 1;
        }
        return InitFlow(state, false);
    }
    if (base.type == NODE_FIELD_ACCESS) {
        let access -> FieldAccessNode = node;
        return check_local_init_node(c, access.obj, scope, initialized);
    }
    if (base.type == NODE_FIELD_ASSIGN) {
        let assignment -> FieldAssignNode = node;
        let object_flow -> InitFlow = check_local_init_node(c, assignment.obj, scope, initialized);
        return check_local_init_node(c, assignment.value, scope, object_flow.initialized);
    }
    if (base.type == NODE_PTR_ASSIGN) {
        let assignment -> PtrAssignNode = node;
        let pointer_flow -> InitFlow = check_local_init_node(c, assignment.pointer, scope, initialized);
        return check_local_init_node(c, assignment.value, scope, pointer_flow.initialized);
    }
    if (base.type == NODE_INDEX_ACCESS) {
        let access -> IndexAccessNode = node;
        let target_flow -> InitFlow = check_local_init_node(c, access.target, scope, initialized);
        return check_local_init_node(c, access.index_node, scope, target_flow.initialized);
    }
    if (base.type == NODE_INDEX_ASSIGN) {
        let assignment -> IndexAssignNode = node;
        let target_flow -> InitFlow = check_local_init_node(c, assignment.target, scope, initialized);
        let index_flow -> InitFlow = check_local_init_node(c, assignment.index_node, scope, target_flow.initialized);
        return check_local_init_node(c, assignment.value, scope, index_flow.initialized);
    }
    if (base.type == NODE_SLICE_ACCESS) {
        let access -> SliceAccessNode = node;
        let state -> Vector(String) = check_local_init_node(c, access.target, scope, initialized).initialized;
        state = check_local_init_node(c, access.start_idx, scope, state).initialized;
        return check_local_init_node(c, access.end_idx, scope, state);
    }
    if (base.type == NODE_VECTOR_LIT) {
        let vector -> VectorLitNode = node;
        let state -> Vector(String) = initialized;
        let i -> Int = 0;
        while (vector.elements is !null && i < vector.elements.length()) {
            state = check_local_init_node(c, vector.elements[i], scope, state).initialized;
            i += 1;
        }
        return InitFlow(state, false);
    }
    if (base.type == NODE_MAP_LIT) {
        let map -> MapLitNode = node;
        let state -> Vector(String) = initialized;
        let i -> Int = 0;
        while (map.pairs is !null && i < map.pairs.length()) {
            let pair -> MapPairNode = map.pairs[i];
            state = check_local_init_node(c, pair.key, scope, state).initialized;
            state = check_local_init_node(c, pair.value, scope, state).initialized;
            i += 1;
        }
        return InitFlow(state, false);
    }
    if (base.type == NODE_FUNC_DEF) {
        let function -> FunctionDefNode = node;
        let captures -> CaptureScope = CaptureScope(local_vars=Dict(32), captured_vars=Dict(32), captured_list=[]);
        let i -> Int = 0;
        while (function.params is !null && i < function.params.length()) {
            let param -> ParamNode = function.params[i];
            captures.local_vars.put(param.name_tok.value, TypeListNode(type=1));
            i += 1;
        }
        analyze_captures(function.body, captures);
        i = 0;
        while (i < captures.captured_list.length()) {
            read_local_init(scope, initialized, captures.captured_list[i], function.pos);
            i += 1;
        }
        return InitFlow(initialized, false);
    }
    return InitFlow(initialized, false);
}

func check_local_init(c -> Compiler, body -> Struct) -> Void {
    if (body is null) { return; }
    let root -> LocalInitScope = LocalInitScope(table=Dict(32), parent=null, declarations=[]);
    check_local_init_block(c, body, root, []);
}

func init_complete(required -> Vector(String), initialized -> Vector(String)) -> Bool {
    let i -> Int = 0;
    while (i < required.length()) {
        if (!init_has(initialized, required[i])) { return false; }
        i += 1;
    }
    return true;
}

func init_require_complete(class_name -> String, required -> Vector(String), initialized -> Vector(String), pos -> Position) -> Bool {
    let i -> Int = 0;
    while (i < required.length()) {
        let name -> String = required[i];
        if (!init_has(initialized, name)) {
            if (name == "$super") {
                throw_missing_initializer(
                    pos,
                    "Constructor for class '" + class_name +
                    "' must call super.init(...) before returning."
                );
            } else {
                throw_missing_initializer(
                    pos,
                    "Field '" + name + "' is not initialized on every path through '" +
                    class_name + ".init'."
                );
            }
            return false;
        }
        i += 1;
    }
    return true;
}

func init_is_self(node -> Struct) -> Bool {
    if (node is null) { return false; }
    let base -> BaseNode = node;
    if (base.type != NODE_VAR_ACCESS) { return false; }
    let access -> VarAccessNode = node;
    return access.name_tok.value == "self";
}

func class_requires_initialization(c -> Compiler, info -> StructInfo) -> Bool {
    if (info is null || !info.is_class || info.init_body is null) {
        return false;
    }

    let class_node -> ClassDefNode = info.init_body;
    let fields -> Vector(Struct) = class_node.fields;
    let i -> Int = 0;
    while (fields is !null && i < fields.length()) {
        let field -> VarDeclareNode = fields[i];
        if (field.value is null) { return true; }
        i += 1;
    }

    if (info.parent_id != 0) {
        let parent -> StructInfo = c.struct_id_map.get("" + info.parent_id);
        return class_requires_initialization(c, parent);
    }
    return false;
}

func check_init_node(c -> Compiler, class_name -> String, node -> Struct, required -> Vector(String), known_fields -> Vector(String), initialized -> Vector(String)) -> InitFlow {
    if (node is null) { return InitFlow(initialized, false); }
    let base -> BaseNode = node;

    if (base.type == NODE_BLOCK) {
        let block -> BlockNode = node;
        let state -> Vector(String) = initialized;
        let i -> Int = 0;
        while (block.stmts is !null && i < block.stmts.length()) {
            let flow -> InitFlow = check_init_node(
                c, class_name, block.stmts[i], required, known_fields, state
            );
            state = flow.initialized;
            if (flow.terminates) { return InitFlow(state, true); }
            i += 1;
        }
        return InitFlow(state, false);
    }

    if (base.type == NODE_IF) {
        let branch -> IfNode = node;
        check_init_node(
            c, class_name, branch.condition, required, known_fields, initialized
        );

        let selected -> Int = fold_target_cond(c, branch.condition);
        let condition -> BaseNode = branch.condition;
        if (condition is !null && condition.type == NODE_BOOL) {
            let boolean -> BooleanNode = branch.condition;
            selected = boolean.value;
        }
        if (selected == 1) {
            return check_init_node(
                c,
                class_name,
                branch.body,
                required,
                known_fields,
                initialized
            );
        }
        if (selected == 0) {
            return check_init_node(
                c,
                class_name,
                branch.else_body,
                required,
                known_fields,
                initialized
            );
        }

        let then_flow -> InitFlow = check_init_node(
            c,
            class_name,
            branch.body,
            required,
            known_fields,
            init_copy(initialized)
        );
        let else_flow -> InitFlow = InitFlow(init_copy(initialized), false);
        if (branch.else_body is !null) {
            else_flow = check_init_node(
                c,
                class_name,
                branch.else_body,
                required,
                known_fields,
                init_copy(initialized)
            );
        }

        if (then_flow.terminates && else_flow.terminates) {
            return InitFlow(initialized, true);
        }
        if (then_flow.terminates) {
            return InitFlow(else_flow.initialized, false);
        }
        if (else_flow.terminates) {
            return InitFlow(then_flow.initialized, false);
        }
        return InitFlow(
            init_intersection(then_flow.initialized, else_flow.initialized),
            false
        );
    }

    if (base.type == NODE_WHILE) {
        let loop -> WhileNode = node;
        check_init_node(
            c, class_name, loop.condition, required, known_fields, initialized
        );
        check_init_node(
            c,
            class_name,
            loop.body,
            required,
            known_fields,
            init_copy(initialized)
        );
        return InitFlow(initialized, must_terminate(c, node));
    }

    if (base.type == NODE_FOR) {
        let loop -> ForNode = node;
        let state -> Vector(String) = initialized;
        if (loop.init is !null) {
            let init_flow -> InitFlow = check_init_node(
                c, class_name, loop.init, required, known_fields, state
            );
            state = init_flow.initialized;
        }
        check_init_node(c, class_name, loop.cond, required, known_fields, state);
        check_init_node(
            c,
            class_name,
            loop.body,
            required,
            known_fields,
            init_copy(state)
        );
        check_init_node(
            c,
            class_name,
            loop.step,
            required,
            known_fields,
            init_copy(state)
        );
        return InitFlow(state, must_terminate(c, node));
    }

    if (base.type == NODE_CATCH) {
        let caught -> CatchNode = node;
        let success -> InitFlow = check_init_node(
            c,
            class_name,
            caught.stmt,
            required,
            known_fields,
            init_copy(initialized)
        );
        let failure -> InitFlow = check_init_node(
            c,
            class_name,
            caught.body,
            required,
            known_fields,
            init_copy(initialized)
        );
        if (success.terminates && failure.terminates) {
            return InitFlow(initialized, true);
        }
        if (success.terminates) { return InitFlow(failure.initialized, false); }
        if (failure.terminates) { return InitFlow(success.initialized, false); }
        return InitFlow(
            init_intersection(success.initialized, failure.initialized),
            false
        );
    }

    if (base.type == NODE_RETURN) {
        let return_node -> ReturnNode = node;
        check_init_node(
            c, class_name, return_node.value, required, known_fields, initialized
        );
        init_require_complete(class_name, required, initialized, return_node.pos);
        return InitFlow(initialized, true);
    }

    if (base.type == NODE_THROW) {
        let thrown -> ThrowNode = node;
        check_init_node(
            c, class_name, thrown.value, required, known_fields, initialized
        );
        return InitFlow(initialized, true);
    }

    if (base.type == NODE_BREAK || base.type == NODE_CONTINUE) {
        return InitFlow(initialized, true);
    }

    if (base.type == NODE_FIELD_ASSIGN) {
        let assignment -> FieldAssignNode = node;
        check_init_node(
            c, class_name, assignment.value, required, known_fields, initialized
        );
        if (init_is_self(assignment.obj)) {
            if (init_has(required, "$super") &&
                !init_has(initialized, "$super")) {
                throw_missing_initializer(
                    assignment.pos,
                    "Call super.init(...) before initializing fields of '" +
                    class_name + "'."
                );
                init_add(initialized, "$super");
            }
            if (init_has(known_fields, assignment.field_name)) {
                init_add(initialized, assignment.field_name);
            }
            return InitFlow(initialized, false);
        }
        check_init_node(
            c, class_name, assignment.obj, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }

    if (base.type == NODE_FIELD_ACCESS) {
        let access -> FieldAccessNode = node;
        if (init_is_self(access.obj)) {
            if (init_has(known_fields, access.field_name)) {
                if (!init_has(initialized, access.field_name)) {
                    throw_missing_initializer(
                        access.pos,
                        "Field '" + access.field_name +
                        "' is read before it is initialized."
                    );
                }
            } else if (!init_complete(required, initialized)) {
                throw_missing_initializer(
                    access.pos,
                    "Cannot use 'self' before all fields of '" +
                    class_name + "' are initialized."
                );
            }
            return InitFlow(initialized, false);
        }
        check_init_node(
            c, class_name, access.obj, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }

    if (base.type == NODE_CALL) {
        let call -> CallNode = node;
        let is_super_init -> Bool = false;
        if (call.callee is !null) {
            let callee_base -> BaseNode = call.callee;
            if (callee_base.type == NODE_FIELD_ACCESS) {
                let member -> FieldAccessNode = call.callee;
                if (member.field_name == "init" && member.obj is !null) {
                    let owner -> BaseNode = member.obj;
                    is_super_init = owner.type == NODE_SUPER;
                }
            }
        }

        let i -> Int = 0;
        while (call.args is !null && i < call.args.length()) {
            let arg -> ArgNode = call.args[i];
            check_init_node(
                c, class_name, arg.val, required, known_fields, initialized
            );
            i += 1;
        }

        if (is_super_init) {
            init_add(initialized, "$super");
        } else {
            check_init_node(
                c, class_name, call.callee, required, known_fields, initialized
            );
        }
        return InitFlow(initialized, false);
    }

    if (base.type == NODE_VAR_ACCESS) {
        let access -> VarAccessNode = node;
        if (access.name_tok.value == "self" &&
            !init_complete(required, initialized)) {
            throw_missing_initializer(
                access.pos,
                "Cannot use 'self' before all fields of '" +
                class_name + "' are initialized."
            );
        }
        return InitFlow(initialized, false);
    }

    if (base.type == NODE_BINOP ||
        base.type == NODE_IS ||
        base.type == NODE_IS_NOT) {
        let binary -> BinOpNode = node;
        check_init_node(
            c, class_name, binary.left, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, binary.right, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }

    if (base.type == NODE_UNARYOP) {
        let unary -> UnaryOpNode = node;
        return check_init_node(
            c, class_name, unary.node, required, known_fields, initialized
        );
    }
    if (base.type == NODE_POSTFIX) {
        let postfix -> PostfixOpNode = node;
        return check_init_node(
            c, class_name, postfix.node, required, known_fields, initialized
        );
    }
    if (base.type == NODE_REF) {
        let reference -> RefNode = node;
        return check_init_node(
            c, class_name, reference.node, required, known_fields, initialized
        );
    }
    if (base.type == NODE_DEREF) {
        let dereference -> DerefNode = node;
        return check_init_node(
            c, class_name, dereference.node, required, known_fields, initialized
        );
    }
    if (base.type == NODE_TRY_UNWRAP) {
        let unwrap -> TryUnwrapNode = node;
        return check_init_node(
            c, class_name, unwrap.expr, required, known_fields, initialized
        );
    }

    if (base.type == NODE_VAR_DECL) {
        let declaration -> VarDeclareNode = node;
        check_init_node(
            c, class_name, declaration.value, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_VAR_ASSIGN) {
        let assignment -> VarAssignNode = node;
        check_init_node(
            c, class_name, assignment.value, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_PTR_ASSIGN) {
        let assignment -> PtrAssignNode = node;
        check_init_node(
            c, class_name, assignment.pointer, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, assignment.value, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_INDEX_ACCESS) {
        let access -> IndexAccessNode = node;
        check_init_node(
            c, class_name, access.target, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, access.index_node, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_INDEX_ASSIGN) {
        let assignment -> IndexAssignNode = node;
        check_init_node(
            c, class_name, assignment.target, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, assignment.index_node, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, assignment.value, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_SLICE_ACCESS) {
        let access -> SliceAccessNode = node;
        check_init_node(
            c, class_name, access.target, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, access.start_idx, required, known_fields, initialized
        );
        check_init_node(
            c, class_name, access.end_idx, required, known_fields, initialized
        );
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_VECTOR_LIT) {
        let vector -> VectorLitNode = node;
        let i -> Int = 0;
        while (vector.elements is !null && i < vector.elements.length()) {
            check_init_node(
                c, class_name, vector.elements[i], required, known_fields, initialized
            );
            i += 1;
        }
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_MAP_LIT) {
        let map -> MapLitNode = node;
        let i -> Int = 0;
        while (map.pairs is !null && i < map.pairs.length()) {
            let pair -> MapPairNode = map.pairs[i];
            check_init_node(
                c, class_name, pair.key, required, known_fields, initialized
            );
            check_init_node(
                c, class_name, pair.value, required, known_fields, initialized
            );
            i += 1;
        }
        return InitFlow(initialized, false);
    }
    if (base.type == NODE_SUPER &&
        init_has(required, "$super") &&
        !init_has(initialized, "$super")) {
        let super_node -> SuperNode = node;
        throw_missing_initializer(
            super_node.pos,
            "Call super.init(...) before using the parent part of '" +
            class_name + "'."
        );
    }

    return InitFlow(initialized, false);
}

func check_class_initialization(c -> Compiler, class_name -> String, node -> ClassDefNode, parent -> StructInfo) -> Void {
    let required -> Vector(String) = [];
    let known_fields -> Vector(String) = [];
    let initialized -> Vector(String) = [];

    let fields -> Vector(Struct) = node.fields;
    let i -> Int = 0;
    while (fields is !null && i < fields.length()) {
        let field -> VarDeclareNode = fields[i];
        let name -> String = field.name_tok.value;
        known_fields.append(name);
        if (field.value is null) {
            required.append(name);
        } else {
            initialized.append(name);
        }
        i += 1;
    }

    let parent_requires_init -> Bool =
        class_requires_initialization(c, parent);
    if (parent_requires_init) {
        required.append("$super");
    } else {
        initialized.append("$super");
    }

    let default_required -> Vector(String) = init_copy(known_fields);
    if (parent_requires_init) { default_required.append("$super"); }
    let default_state -> Vector(String) = [];
    if (!parent_requires_init) { default_state.append("$super"); }
    i = 0;
    while (fields is !null && i < fields.length()) {
        let field -> VarDeclareNode = fields[i];
        if (field.value is !null) {
            check_init_node(
                c,
                class_name,
                field.value,
                default_required,
                known_fields,
                default_state
            );
            init_add(default_state, field.name_tok.value);
        }
        i += 1;
    }

    if (required.length() == 0) { return; }

    let initializer -> MethodDefNode = null;
    let methods -> Vector(Struct) = node.methods;
    i = 0;
    while (methods is !null && i < methods.length()) {
        let method_node -> MethodDefNode = methods[i];
        if (method_node.name_tok.value == "$init") {
            initializer = method_node;
            break;
        }
        i += 1;
    }

    if (initializer is null) {
        let missing -> String = required[0];
        if (missing == "$super") {
            throw_missing_initializer(
                node.pos,
                "Class '" + class_name +
                "' must define init and call super.init(...)."
            );
        } else {
            throw_missing_initializer(
                node.pos,
                "Field '" + missing + "' has no initializer, but class '" +
                class_name + "' does not define init."
            );
        }
        return;
    }

    let flow -> InitFlow = check_init_node(
        c,
        class_name,
        initializer.body,
        required,
        known_fields,
        initialized
    );
    if (!flow.terminates) {
        init_require_complete(
            class_name,
            required,
            flow.initialized,
            initializer.pos
        );
    }
}

func emit_class_field_initializers(c -> Compiler, class_info -> StructInfo, object_reg -> String, object_llvm_type -> String) -> Void {
    if (class_info is null) { return; }

    if (class_info.parent_id != 0) {
        let parent -> StructInfo =
            c.struct_id_map.get("" + class_info.parent_id);
        emit_class_field_initializers(
            c,
            parent,
            object_reg,
            object_llvm_type
        );
    }

    let initializer -> FuncInfo =
        c.func_table.get(class_info.name + "_$field_init");
    if (initializer is null) { return; }

    let target_reg -> String = object_reg;
    if (class_info.llvm_name != object_llvm_type) {
        target_reg = next_reg(c);
        c.output_file.write(
            c.indent + target_reg + " = bitcast " +
            object_llvm_type + "* " + object_reg + " to " +
            class_info.llvm_name + "*\n"
        );
    }
    c.output_file.write(
        c.indent + "call void @" + initializer.name + "(" +
        class_info.llvm_name + "* " + target_reg + ")\n"
    );
}

func typed_dict_zero(c -> Compiler, info -> FuncInfo, node -> CallNode) -> CompileResult {
    if (node.args is !null && node.args.length() != 0) { throw_type_error(node.pos, "Argument count mismatch. Expected 0, got " + node.args.length()); return CompileResult(reg="poison", type=TYPE_POISON); }

    let type_id -> Int = info.ret_type;
    let value -> String = "0";
    if (type_id == TYPE_FLOAT || type_id == TYPE_FLOAT32) {
        value = "0.0";
    } else if (is_nullable_reference_type(c, type_id) || is_pointer_type(c, type_id)) {
        value = "null";
    } else {
        let type_info -> StructInfo = c.struct_id_map.get("" + type_id);
        let array_info -> ArrayInfo = c.array_info_map.get("" + type_id);
        if ((type_info is !null && type_info.is_interface) || 
            (array_info is !null && array_info.size >= 0) || 
            is_fallible_type(c, type_id)) {
            value = "zeroinitializer";
        }
    }
    return CompileResult(reg=value, type=type_id);
}

func emit_typed_dict_helpers(c -> Compiler) -> Void {
    let slot -> Int = 0;
    while (slot < c.typed_dict_keys.capacity) {
        if (c.typed_dict_keys.hashes[slot] >= 2) {
            let entry -> StringConstant = c.typed_dict_keys.values[slot];
            let type_id -> Int = entry.id;
            let llvm_type -> String = get_llvm_type_str(c, type_id);
            let hash_name -> String = "@__wl_typed_dict_hash_" + type_id;
            let equal_name -> String = "@__wl_typed_dict_equal_" + type_id;
            if (type_id == TYPE_STRING) {
                c.output_file.write("define internal i32 " + hash_name + "(%struct.$String* %key) {\n");
                c.output_file.write("entry:\n");
                c.output_file.write("  %is.null = icmp eq %struct.$String* %key, null\n");
                c.output_file.write("  br i1 %is.null, label %invalid, label %read\n");
                c.output_file.write("read:\n");
                c.output_file.write("  %buf.addr = getelementptr inbounds %struct.$String, %struct.$String* %key, i32 0, i32 0\n");
                c.output_file.write("  %len.addr = getelementptr inbounds %struct.$String, %struct.$String* %key, i32 0, i32 1\n");
                c.output_file.write("  %buf = load i8*, i8** %buf.addr\n");
                c.output_file.write("  %len = load i32, i32* %len.addr\n");
                c.output_file.write("  br label %loop\n");
                c.output_file.write("loop:\n");
                c.output_file.write("  %index = phi i32 [ 0, %read ], [ %next, %body ]\n");
                c.output_file.write("  %state = phi i64 [ 14695981039346656037, %read ], [ %next.state, %body ]\n");
                c.output_file.write("  %done = icmp uge i32 %index, %len\n");
                c.output_file.write("  br i1 %done, label %finish, label %body\n");
                c.output_file.write("body:\n");
                c.output_file.write("  %byte.addr = getelementptr inbounds i8, i8* %buf, i32 %index\n");
                c.output_file.write("  %byte = load i8, i8* %byte.addr\n");
                c.output_file.write("  %wide = zext i8 %byte to i64\n");
                c.output_file.write("  %mixed = xor i64 %state, %wide\n");
                c.output_file.write("  %next.state = mul i64 %mixed, 1099511628211\n");
                c.output_file.write("  %next = add i32 %index, 1\n");
                c.output_file.write("  br label %loop\n");
                c.output_file.write("finish:\n");
                c.output_file.write("  %len.wide = zext i32 %len to i64\n");
                c.output_file.write("  %hash = call i32 @__wl_dict_hash_bits(i64 " + type_fingerprint(c, type_id) + ", i64 %state, i64 %len.wide)\n");
                c.output_file.write("  ret i32 %hash\n");
                c.output_file.write("invalid:\n");
                c.output_file.write("  ret i32 0\n");
                c.output_file.write("}\n\n");
                c.output_file.write("define internal i1 " + equal_name + "(%struct.$String* %left, %struct.$String* %right) {\nentry:\n  %result = call i1 @__wl_dict_string_equal(%struct.$String* %left, %struct.$String* %right)\n  ret i1 %result\n}\n\n");
            } else {
                c.output_file.write("define internal i32 " + hash_name + "(" + llvm_type + " %key) {\nentry:\n");
                let bits -> String = "%bits";
                let key_info -> StructInfo = c.struct_id_map.get("" + type_id);
                if (is_pointer_type(c, type_id) || type_id == TYPE_ANYPTR || 
                    c.func_ret_map.get("" + type_id) is !null || 
                    c.method_ret_map.get("" + type_id) is !null || 
                    (key_info is !null && key_info.is_class)) {

                    c.output_file.write("  " + bits + " = ptrtoint " + llvm_type + " %key to i64\n");
                }
                else if (type_id == TYPE_INT128 || type_id == TYPE_UINT128) {
                    c.output_file.write("  %low = trunc i128 %key to i64\n  %shift = lshr i128 %key, 64\n  %high = trunc i128 %shift to i64\n  %result = call i32 @__wl_dict_hash_bits(i64 " + type_fingerprint(c, type_id) + ", i64 %low, i64 %high)\n  ret i32 %result\n}\n\n");
                    bits = "";
                }
                else if (type_id == TYPE_FLOAT) {
                    c.output_file.write("  %is.nan = fcmp uno double %key, %key\n  br i1 %is.nan, label %invalid, label %float.valid\nfloat.valid:\n  %is.zero = fcmp oeq double %key, 0.0\n  %raw = bitcast double %key to i64\n  " + bits + " = select i1 %is.zero, i64 0, i64 %raw\n");
                }
                else if (type_id == TYPE_FLOAT32) {
                    c.output_file.write("  %is.nan = fcmp uno float %key, %key\n  br i1 %is.nan, label %invalid, label %float.valid\nfloat.valid:\n  %is.zero = fcmp oeq float %key, 0.0\n  %raw = bitcast float %key to i32\n  %wide = zext i32 %raw to i64\n  " + bits + " = select i1 %is.zero, i64 0, i64 %wide\n");
                }
                else if (key_info is !null && key_info.is_enum) {
                    c.output_file.write("  " + bits + " = zext i32 %key to i64\n");
                }
                else {
                    let width -> Int = get_type_bitwidth(type_id);
                    if (width < 64) {
                        c.output_file.write("  " + bits + " = zext " + llvm_type + " %key to i64\n");
                    } else {
                        c.output_file.write("  " + bits + " = add i64 %key, 0\n");
                    }
                }

                if (bits.length() > 0) {
                    c.output_file.write("  %result = call i32 @__wl_dict_hash_bits(i64 " + type_fingerprint(c, type_id) + ", i64 " + bits + ", i64 0)\n  ret i32 %result\n");
                }
                if (type_id == TYPE_FLOAT || type_id == TYPE_FLOAT32) {
                    c.output_file.write("invalid:\n  ret i32 0\n");
                }
                if (bits.length() > 0) {
                    c.output_file.write("}\n\n");
                }
                c.output_file.write("define internal i1 " + equal_name + "(" + llvm_type + " %left, " + llvm_type + " %right) {\nentry:\n");
                if (type_id == TYPE_FLOAT || type_id == TYPE_FLOAT32) {
                    c.output_file.write("  %result = fcmp oeq " + llvm_type + " %left, %right\n");
                } else {
                    c.output_file.write("  %result = icmp eq " + llvm_type + " %left, %right\n");
                }
                c.output_file.write("  ret i1 %result\n}\n\n");
            }
        }
        slot += 1;
    }
}

func emit_erased_check_helpers(c -> Compiler) -> Void {
    let slot -> Int = 0;
    while (slot < c.erased_checks.capacity) {
        if (c.erased_checks.hashes[slot] >= 2) {
            let entry -> StringConstant = c.erased_checks.values[slot];
            let expected -> Int = entry.id;
            c.output_file.write("define internal i1 " + entry.value + "(i32 %tag) {\n");
            c.output_file.write("entry:\n");
            c.output_file.write("  switch i32 %tag, label %reject [\n");

            let candidate -> Int = 100;
            while (candidate < c.type_counter) {
                let accepted -> Bool = candidate == expected;
                let expected_info -> StructInfo = c.struct_id_map.get("" + expected);
                if (!accepted && expected_info is !null && expected_info.is_class) {
                    accepted = is_subclass(c, candidate, expected);
                }
                if (!accepted && expected_info is !null && !expected_info.is_class) {
                    accepted = erased_struct_compatible(c, candidate, expected);
                }
                if accepted {
                    c.output_file.write("    i32 " + candidate + ", label %accept\n");
                }
                candidate += 1;
            }
            c.output_file.write("  ]\n");
            c.output_file.write("accept:\n");
            c.output_file.write("  ret i1 true\n");
            c.output_file.write("reject:\n");
            c.output_file.write("  ret i1 false\n");
            c.output_file.write("}\n\n");
        }
        slot += 1;
    }
}

func class_vtable_type(c -> Compiler, info -> StructInfo) -> String {
    if (c.generic_instance_templates.get("" + info.type_id) is !null) {
        return generic_llvm_name("%vtable_type.__generic.", info.type_id);
    }
    return "%vtable_type." + info.name;
}

func compile_class_init(c -> Compiler, s_info -> StructInfo, n_call -> CallNode) -> CompileResult {
    let size_ty -> String = get_size_llvm_type();
    let size_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr " + s_info.llvm_name + ", " + s_info.llvm_name + "* null, " + size_ty + " 1\n");
    let object_size -> String = next_reg(c);
    c.output_file.write(c.indent + object_size + " = ptrtoint " + s_info.llvm_name + "* " + size_ptr + " to " + size_ty + "\n");
    let obj_ptr -> String = emit_alloc_obj(c, object_size, "" + s_info.type_id, s_info.llvm_name + "*");

    let fields_vec -> Vector(Struct) = s_info.fields;
    let f_len -> Int = 0;
    if (fields_vec is !null) { f_len = fields_vec.length(); }
    let f_idx -> Int = 0;

    while (f_idx < f_len) {
        let f_curr -> FieldInfo = fields_vec[f_idx];
        let f_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + obj_ptr + ", i32 0, i32 " + f_curr.offset + "\n");
        
        if (f_curr.name == "_vptr") {
            let vtable_cast -> String = next_reg(c);
            c.output_file.write(c.indent + vtable_cast + " = bitcast " + class_vtable_type(c, s_info) + "* " + s_info.vtable_name + " to i8*\n");
            c.output_file.write(c.indent + "store i8* " + vtable_cast + ", i8** " + f_ptr + "\n");
        } else {
            let zero_val -> String = "0";
            if (f_curr.type == TYPE_FLOAT) { zero_val = "0.0"; }
            else {
                let field_info -> StructInfo = c.struct_id_map.get("" + f_curr.type);
                let field_array -> ArrayInfo = c.array_info_map.get("" + f_curr.type);
                if (is_fallible_type(c, f_curr.type) ||
                    (field_info is !null && field_info.is_interface) ||
                    (field_array is !null && field_array.size >= 0)) {
                    zero_val = "zeroinitializer";
                } else if (is_nullable_reference_type(c, f_curr.type)) {
                    zero_val = "null";
                }
            }
            
            c.output_file.write(c.indent + "store " + f_curr.llvm_type + " " + zero_val + ", " + f_curr.llvm_type + "* " + f_ptr + "\n");
        }
        f_idx += 1;
    }

    emit_class_field_initializers(
        c,
        s_info,
        obj_ptr,
        s_info.llvm_name
    );

    let init_name -> String = s_info.name + "_$init";
    let init_func -> FuncInfo = c.func_table.get(init_name);
    
    if (init_func is !null) {
        let args_str -> String = s_info.llvm_name + "* " + obj_ptr;
        let args -> Vector(Struct) = n_call.args;
        let a_len -> Int = 0; if (args is !null) { a_len = args.length(); }
        let arg_idx -> Int = 0;
        let owned_args -> Vector(Struct) = [];
        let arg_types -> Vector(Struct) = init_func.arg_types;
        
        let expected_arg_count -> Int = 0;
        if (arg_types is !null) { expected_arg_count = arg_types.length() - 1; }
        
        if (a_len != expected_arg_count) {
            throw_type_error(n_call.pos, "Class init expects " + expected_arg_count + " arguments, got " + a_len + ".");
            return void_result();
        }

        args = bind_call_args(args, init_func.arg_names, 1, n_call.pos);
        if (args is null && expected_arg_count > 0) { return CompileResult(reg="poison", type=TYPE_POISON); }

        while (arg_idx < a_len) {
            let arg_node_curr -> ArgNode = args[arg_idx];
            let type_node_curr -> TypeListNode = arg_types[arg_idx + 1]; // +1 skip self
            let expected_type -> Int = type_node_curr.type;

            c.expected_type = expected_type;
            let arg_val -> CompileResult = compile_node(c, arg_node_curr.val);
            c.expected_type = 0;
            arg_val = emit_implicit_cast(c, arg_val, expected_type, n_call.pos);

            let ty_str -> String = get_llvm_type_str(c, arg_val.type);
            if (arg_val.type != TYPE_POISON) {
                args_str = args_str + ", " + ty_str + " " + arg_val.reg;
                if (arg_val.owns_ref) { owned_args.append(arg_val); }
            } else {
                args_str = args_str + ", " + ty_str + " poison";
            }
            arg_idx += 1;
        }

        c.output_file.write(c.indent + "call void @" + init_func.name + "(" + args_str + ")\n");
        emit_release_owned_args(c, owned_args);
    } else {
        let args -> Vector(Struct) = n_call.args;
        let a_len -> Int = 0; if (args is !null) { a_len = args.length(); }
        if (a_len > 0) {
            throw_type_error(n_call.pos, "Class '" + s_info.name + "' has no init method, but arguments were provided.");
            return void_result();
        }
    }

    return CompileResult(reg=obj_ptr, type=s_info.type_id);
}

func register_class_methods(c -> Compiler, class_name -> String, class_type_id -> Int, methods -> Vector(Struct)) -> Bool {
    let index -> Int = 0;
    while (methods is !null && index < methods.length()) {
        let method_node -> MethodDefNode = methods[index];
        let method_name -> String = method_base_name(c, method_node);

        let ret_type -> Int = resolve_type(c, method_node.return_type);
        if (ret_type == TYPE_AUTO) {
            throw_type_error(method_node.pos, "Auto return type deduction is not supported in methods.");
            return false;
        }
        if (method_node.name_tok.value == "$type") {
            let target -> Int = ret_type;
            if (is_fallible_type(c, target)) {
                target = get_inner_fallible_type(c, target);
            }
            if (!is_conversion_target(target)) {
                throw_type_error(method_node.pos, "Conversion target " + get_type_name(c, target) + " is not a built-in value type");
                return false;
            }
        }

        let arg_types -> Vector(Struct) = [TypeListNode(type=class_type_id)];
        let arg_names -> Vector(String) = ["self"];
        if (!check_duplicate_params(method_node.params, "method '" + method_name + "'", method_node.pos)) {
            return false;
        }

        let param_index -> Int = 0;
        while (method_node.params is !null && param_index < method_node.params.length()) {
            let param -> ParamNode = method_node.params[param_index];
            let param_type -> Int = resolve_type(c, param.type_tok);
            if (param_type == TYPE_AUTO) {
                throw_type_error(param.pos, "Auto cannot be used in method parameters.");
                return false;
            }

            arg_types.append(TypeListNode(type=param_type));
            arg_names.append(param.name_tok.value);
            param_index += 1;
        }

        let key -> String = class_name + "_" + method_name;
        if (c.func_table.get(key) is !null) { throw_name_error(method_node.pos, "Method '" + key + "' is already defined."); return false; }
        let symbol -> String = mangle_wl_name(c, class_name + ".", method_name, arg_types);
        c.func_table.put(key, FuncInfo(name=symbol, base_name=method_name, ret_type=ret_type, arg_types=arg_types, arg_names=arg_names, is_varargs=false, mutates_self=method_mutates_self(method_node.body)));
        index += 1;
    }
    return true;
}

func compile_class_def(c -> Compiler, node -> ClassDefNode) -> CompileResult {
    if (node.type_params is !null && 
        node.type_params.length() > 0 && 
        c.generic_class_type == 0) {
        return void_result();
    }

    let raw_name -> String = node.name_tok.value;
    let class_name -> String = c.current_package_prefix + raw_name;
    if (c.generic_class_type != 0) {
        let generic_info -> StructInfo = c.struct_id_map.get("" + c.generic_class_type);
        class_name = generic_info.name;
    }

    let full_name -> String = "class." + class_name;
    if (c.struct_table.get(full_name) is !null) {
        throw_import_error(node.pos, "Class '" + class_name + "' is already defined.");
        return void_result();
    }

    let info -> StructInfo = c.struct_table.get(class_name);
    let parent_info -> StructInfo = null;
    if (node.parent_tok is !null) {
        let parent_type -> Int = resolve_type(c, node.parent_tok);
        parent_info = c.struct_id_map.get("" + parent_type);
        if (parent_info is null || !parent_info.is_class) {
            throw_type_error(node.pos, "Type " + get_type_name(c, parent_type) + " is not a class.");
            return void_result();
        }
        info.parent_id = parent_info.type_id;
    }

    let effective_interfaces -> Vector(Struct) = [];
    if (parent_info is !null) {
        let inherited_idx -> Int = 0;
        while (parent_info.interfaces is !null && inherited_idx < parent_info.interfaces.length()) {
            let inherited -> TypeListNode = parent_info.interfaces[inherited_idx];
            if (!add_interface_type(c, effective_interfaces, inherited.type, node.pos)) { return void_result(); }
            inherited_idx += 1;
        }
    }
    let declared_idx -> Int = 0;
    while (node.interfaces is !null && declared_idx < node.interfaces.length()) {
        let declared -> Struct = node.interfaces[declared_idx];
        if (!add_interface(c, effective_interfaces, declared, node.pos)) { return void_result(); }
        declared_idx += 1;
    }
    info.interfaces = effective_interfaces;

    check_class_initialization(c, class_name, node, parent_info);

    let llvm_body -> String = "";
    let fields_vec -> Vector(Struct) = [];
    let vtable_vec -> Vector(Struct) = [];
    let current_offset -> Int = 0;

    if (parent_info is !null) {
        let p_fields -> Vector(Struct) = parent_info.fields;
        let pf_len -> Int = p_fields.length();
        let pf_i -> Int = 0;
        while (pf_i < pf_len) {
            let pf -> FieldInfo = p_fields[pf_i];
            fields_vec.append(FieldInfo(name=pf.name, type=pf.type, llvm_type=pf.llvm_type, offset=pf.offset, is_const=pf.is_const));
            if (pf_i > 0) { llvm_body += ", "; }
            llvm_body += pf.llvm_type;
            current_offset += 1;
            pf_i += 1;
        }

        let p_vt -> Vector(Struct) = parent_info.vtable;
        let pvt_len -> Int = p_vt.length();
        let pvt_i -> Int = 0;
        while (pvt_i < pvt_len) {
            vtable_vec.append(p_vt[pvt_i]);
            pvt_i += 1;
        }
    } else {
        fields_vec.append(FieldInfo(name="_vptr", type=TYPE_VOID, llvm_type="i8*", offset=0, is_const=true));
        llvm_body = "i8*";
        current_offset = 1;
    }

    let my_fields -> Vector(Struct) = node.fields;
    let mf_len -> Int = 0; if (my_fields is !null) { mf_len = my_fields.length(); }
    let mf_idx -> Int = 0;
    let class_field_names -> Dict = Dict(8);
    let inherited_field_idx -> Int = 0;
    while (inherited_field_idx < fields_vec.length()) { let inherited_field -> FieldInfo = fields_vec[inherited_field_idx]; class_field_names.put(inherited_field.name, StringConstant(id=0, value=inherited_field.name)); inherited_field_idx += 1; }
    while (mf_idx < mf_len) {
        let p -> VarDeclareNode = my_fields[mf_idx];
        let f_name -> String = p.name_tok.value;
        if (class_field_names.contains_key(f_name)) { throw_name_error(p.pos, "field '" + f_name + "' is already defined in class '" + class_name + "'"); return void_result(); }
        class_field_names.put(f_name, StringConstant(id=0, value=f_name));
        let f_type_id -> Int = resolve_type(c, p.type_node);

        if (f_type_id == TYPE_AUTO) {
            if (p.value is null) {
                throw_type_error(p.pos, "field '" + f_name + "' needs an explicit type when it has no initializer.");
                return void_result();
            }
            f_type_id = get_expr_type(c, p.value);
            if (f_type_id == 0 || f_type_id == TYPE_AUTO) {
                throw_type_error(p.pos, "Failed to statically infer type for 'Auto' in class field '" + f_name + "'.");
                return void_result();
            }
        }

        let f_llvm_type -> String = get_llvm_type_str(c, f_type_id);
        
        if (current_offset > 0) { llvm_body += ", "; }
        llvm_body += f_llvm_type;
        fields_vec.append(FieldInfo(name=f_name, type=f_type_id, llvm_type=f_llvm_type, offset=current_offset, is_const=p.is_const));
        current_offset += 1;
        mf_idx += 1;
    }
    info.fields = fields_vec;

    let def_str -> String = info.llvm_name + " = type { " + llvm_body + " }\n";
    if (c.generic_class_type != 0) { c.generic_type_defs += def_str; }
    else { c.output_file.write(def_str); }

    let my_methods -> Vector(Struct) = node.methods;
    let mm_len -> Int = 0; if (my_methods is !null) { mm_len = my_methods.length(); }
    let mm_idx -> Int = 0;
    while (mm_idx < mm_len) {
        let m_node -> MethodDefNode = my_methods[mm_idx];
        let raw_m_name -> String = method_base_name(c, m_node);

        if (m_node.type_params is !null && m_node.type_params.length() > 0) {
            mm_idx++;
            continue;
        }
        
        if (raw_m_name != "$init" && raw_m_name != "$field_init") {
            let m_name -> String = class_name + "_" + raw_m_name;
            let f_info -> FuncInfo = c.func_table.get(m_name);

            if (f_info is null) {
                throw_name_error(m_node.pos, "Compiler internal error: Method '" + m_name + "' was not properly registered.");
                return void_result();
            }
            f_info.mutates_self = method_mutates_self(m_node.body);
            
            if (f_info.compiler_link_name is !null && 
                f_info.compiler_link_name.length() > 0) {
                mm_idx += 1;
                continue;
            }
            let vt_len -> Int = vtable_vec.length();
            let vt_i -> Int = 0;
            let is_override -> Bool = false;
            while (vt_i < vt_len) {
                let p_func -> FuncInfo = vtable_vec[vt_i];
                if (p_func.base_name == raw_m_name) {
                    if (!same_method_signature(p_func, f_info)) {
                        throw_type_error(m_node.pos, "Override of '" + raw_m_name + "' does not match the parent method signature");
                        return void_result();
                    }
                    vtable_vec[vt_i] = f_info;
                    is_override = true;
                    break;
                }
                vt_i += 1;
            }
            if (!is_override) {
                vtable_vec.append(f_info);
            }
        }
        mm_idx += 1;
    }
    info.vtable = vtable_vec;

    let vt_final_len -> Int = vtable_vec.length();
    let vtable_type -> String = "%vtable_type." + class_name;
    if (c.generic_class_type != 0) {
        vtable_type = generic_llvm_name("%vtable_type.__generic.", info.type_id);
        c.generic_type_defs += vtable_type + " = type [ " + vt_final_len + " x i8* ]\n";
    } else {
        c.output_file.write(vtable_type + " = type [ " + vt_final_len + " x i8* ]\n");
    }

    let vt_str -> String = info.vtable_name + " = global " + vtable_type;
    if (vt_final_len == 0) {
        vt_str += " zeroinitializer\n\n";
    } else {
        vt_str += " [ ";
        let vt_i -> Int = 0;
        while (vt_i < vt_final_len) {
            let f_info -> FuncInfo = vtable_vec[vt_i];
            let sig -> String = get_func_sig_str(c, f_info);
            if (vt_i > 0) { vt_str += ", "; }
            vt_str += "i8* bitcast (" + sig + " @" + f_info.name + " to i8*)";
            vt_i += 1;
        }
        vt_str += " ]\n\n";
    }
    c.output_file.write(vt_str);

    if (info.interfaces is !null) {
        let i_len -> Int = info.interfaces.length();
        let i_idx -> Int = 0;
        while (i_idx < i_len) {
            let interface_type -> TypeListNode = info.interfaces[i_idx];
            let i_info -> StructInfo = c.struct_id_map.get("" + interface_type.type);
            let raw_i_name -> String = get_type_name(c, interface_type.type);
            if (i_info is null || !i_info.is_interface) {
                throw_name_error(node.pos, "Interface '" + raw_i_name + "' is not defined or is not an interface.");
                return void_result();
            }
            let i_name -> String = i_info.name;
            
            let im_methods -> Vector(Struct) = i_info.vtable;
            let im_len -> Int = 0; if (im_methods is !null) { im_len = im_methods.length(); }
            
            let itable_name -> String = "@itable." + class_name + "." + i_name;
            c.output_file.write("%itable_type." + class_name + "." + i_name + " = type [ " + im_len + " x i8* ]\n");
            let it_str -> String = itable_name + " = global %itable_type." + class_name + "." + i_name;
            
            if (im_len == 0) {
                it_str += " zeroinitializer\n\n";
            } else {
                it_str += " [ ";
                let im_idx -> Int = 0;
                while (im_idx < im_len) {
                    let req_m -> MethodDefNode = im_methods[im_idx];
                    let req_name -> String = req_m.name_tok.value;
                    
                    let found_impl -> FuncInfo = null;
                    let vt_idx -> Int = 0;
                    while (vt_idx < vt_final_len) {
                        let f -> FuncInfo = vtable_vec[vt_idx];
                        if (f.base_name == req_name) {
                            let match -> Bool = true;
                            let req_ret_type -> Int = interface_method_type(c, i_info, req_m.return_type);
                            if (f.ret_type != req_ret_type) {
                                match = false;
                            } else {
                                let req_params -> Vector(Struct) = req_m.params;
                                let req_p_len -> Int = 0;
                                if (req_params is !null) { req_p_len = req_params.length(); }
                                
                                let f_p_len -> Int = 0;
                                if (f.arg_types is !null) { f_p_len = f.arg_types.length(); }
                                
                                if (f_p_len != req_p_len + 1) {
                                    match = false;
                                } else {
                                    let p_idx -> Int = 0;
                                    while (p_idx < req_p_len) {
                                        let req_p -> ParamNode = req_params[p_idx];
                                        let req_p_type -> Int = interface_method_type(c, i_info, req_p.type_tok);
                                        let f_p -> TypeListNode = f.arg_types[p_idx + 1];
                                        
                                        if (f_p.type != req_p_type) {
                                            match = false;
                                            break;
                                        }
                                        p_idx += 1;
                                    }
                                }
                            }
                            
                            if match {
                                found_impl = f;
                                break;
                            }
                        }
                        vt_idx += 1;
                    }
                    
                    if (found_impl is null) {
                        throw_name_error(node.pos, "Class '" + raw_name + "' does not implement interface method '" + req_name + "'.");
                        return void_result();
                    }
                    
                    let sig -> String = get_func_sig_str(c, found_impl);
                    if (im_idx > 0) { it_str += ", "; }
                    it_str += "i8* bitcast (" + sig + " @" + found_impl.name + " to i8*)";
                    im_idx += 1;
                }
                it_str += " ]\n\n";
            }
            c.output_file.write(it_str);
            i_idx += 1;
        }
    }

    mm_idx = 0;
    while (mm_idx < mm_len) {
        let m_node -> MethodDefNode = my_methods[mm_idx];
        if (m_node.type_params is null || m_node.type_params.length() == 0) {
            compile_method_def(c, class_name, m_node);
        }
        mm_idx += 1;
    }
    
    return void_result();
}

func compile_field_access(c -> Compiler, node -> FieldAccessNode) -> CompileResult {
    let obj_base -> BaseNode = node.obj;

    let is_module -> Bool = false;
    let full_name -> String = "";
    let owner_type -> StructInfo = null;
    let owner_name -> String = "";
    
    let path_parts -> Vector(String) = [];
    let curr_obj -> Struct = node.obj;
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
            let module_prefix -> String = c.current_file_visible_prefixes.get(root_name);
            if (module_prefix is !null) {
                full_name = module_member_name(module_prefix, path_parts, node.field_name);
                is_module = true;
            } else {
                let source_name -> String = module_member_name(root_name + ".", path_parts, node.field_name);
                let mapped_global -> String = c.current_file_global_aliases.get(source_name);
                if (mapped_global is !null) {
                    full_name = mapped_global;
                    is_module = true;
                }
                if (!is_module) {
                    let mapped_root -> String = null;
                    let local_type_name -> String = c.current_package_prefix + root_name;
                    if (c.struct_table.get(local_type_name) is !null) {
                        mapped_root = local_type_name;
                    } else {
                        mapped_root = c.current_file_type_aliases.get(root_name);
                    }
                    if (mapped_root is !null) {
                        owner_type = c.struct_table.get(mapped_root);
                        owner_name = root_name;
                        full_name = module_member_name(mapped_root + ".", path_parts, node.field_name);
                        if (owner_type is !null || c.global_symbol_table.get(full_name) is !null) { is_module = true; }
                    }
                }
            }
        }
    }

    if is_module {
        let g_alias_var -> String = c.global_var_aliases.get(full_name);
        if (g_alias_var is !null) { full_name = g_alias_var; }

        if (node.field_name.starts_with("__")) {
            throw_name_error(node.pos, "Undefined module variable '" + full_name + "'.");
            return void_result();
        }

        let g_info -> SymbolInfo = c.global_symbol_table.get(full_name);
        if (g_info is null) {
            let len_full -> Int = full_name.length();
            let len_field -> Int = node.field_name.length();
            if (len_full > len_field + 1) {
                let type_part -> String = full_name.slice(0, len_full - len_field - 1);
                
                let real_type_name -> String = type_part;
                let c_alias -> String = c.current_file_type_aliases.get(type_part);
                if (c_alias is !null) { real_type_name = c_alias; }
                else {
                    let g_alias -> String = c.global_type_aliases.get(type_part);
                    if (g_alias is !null) { real_type_name = g_alias; }
                }
                
                let resolved_enum_field -> String = real_type_name + "." + node.field_name;
                g_info = c.global_symbol_table.get(resolved_enum_field);
            }
        }

        if (g_info is !null) {
            if (g_info.reg.starts_with("$intrinsic.")) { return emit_target_intrinsic(c, g_info); }
            let llvm_ty_str -> String = get_llvm_type_str(c, g_info.type);
            let val_reg -> String = next_reg(c);
            c.output_file.write(c.indent + val_reg + " = load " + llvm_ty_str + ", " + llvm_ty_str + "* " + g_info.reg + "\n");
            return CompileResult(reg=val_reg, type=g_info.type, origin_type=g_info.origin_type);
        } else {
            if (owner_type is !null) {
                let owner_kind -> String = "Type";
                if (owner_type.is_enum) { owner_kind = "Enum"; }
                throw_name_error(node.pos, owner_kind + " '" + owner_name + "' has no member '" + node.field_name + "'.");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            let mod_name -> String = format_ast_path(node.obj);
            throw_name_error(node.pos, "Undefined field, function or enum variant '" + node.field_name + "' in module '" + mod_name + "'.");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
    }

    let obj_res -> CompileResult = compile_node(c, node.obj);
    if (obj_res is !null && obj_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

    if (is_pointer_type(c, obj_res.type)) {
        let base_info -> SymbolInfo = c.ptr_base_map.get("" + obj_res.type);
        if (base_info is !null) {
            let s_check -> StructInfo = c.struct_id_map.get("" + base_info.type);
            if (s_check is !null) {
                let ptr_is_null -> String = next_reg(c);
                let ptr_ty_str -> String = get_llvm_type_str(c, obj_res.type);
                c.output_file.write(c.indent + ptr_is_null + " = icmp eq " + ptr_ty_str + " " + obj_res.reg + ", null\n");
                
                let label_ok -> String = "ptr_ok_" + c.reg_count;
                let label_fail -> String = "ptr_fail_" + c.reg_count;
                c.reg_count += 1;
                
                c.output_file.write(c.indent + "br i1 " + ptr_is_null + ", label %" + label_fail + ", label %" + label_ok + "\n");
                c.output_file.write("\n" + label_fail + ":\n");
                emit_runtime_error(c, node.pos, "Null pointer dereference");
                
                c.output_file.write("\n" + label_ok + ":\n");

                let loaded_reg -> String = next_reg(c);
                let base_ty_str -> String = get_llvm_type_str(c, base_info.type);
                c.output_file.write(c.indent + loaded_reg + " = load " + base_ty_str + ", " + base_ty_str + "* " + obj_res.reg + "\n");

                obj_res.reg = loaded_reg;
                obj_res.type = base_info.type;
            }
        }
    }

    let type_id -> Int = obj_res.type;
    let obj_reg -> String = obj_res.reg;


    let is_null -> String = next_reg(c);
    let obj_llvm_ty -> String = get_llvm_type_str(c, obj_res.type);
    let null_check_reg -> String = obj_reg;
    let null_check_type -> String = obj_llvm_ty;
    let null_info -> StructInfo = c.struct_id_map.get("" + obj_res.type);
    if (null_info is !null && null_info.is_interface) {
        null_check_reg = next_reg(c);
        null_check_type = "i8*";
        c.output_file.write(c.indent + null_check_reg + " = extractvalue { i8*, i8* } " + obj_reg + ", 0\n");
    }
    c.output_file.write(c.indent + is_null + " = icmp eq " + null_check_type + " " + null_check_reg + ", null\n");
    let label_ok -> String = "access_ok_" + c.reg_count;
    let label_fail -> String = "access_fail_" + c.reg_count;
    c.reg_count += 1;
    c.output_file.write(c.indent + "br i1 " + is_null + ", label %" + label_fail + ", label %" + label_ok + "\n");
    
    c.output_file.write("\n" + label_fail + ":\n");
    emit_runtime_error(c, node.pos, "Null pointer dereference");
    
    c.output_file.write("\n" + label_ok + ":\n");


    if (type_id == TYPE_GENERIC_STRUCT || type_id == TYPE_GENERIC_CLASS) {
        let base_obj -> BaseNode = node.obj;
        if (base_obj.type == NODE_VAR_ACCESS) {
            let v_node -> VarAccessNode = node.obj;
            let info -> SymbolInfo = find_symbol(c, v_node.name_tok.value);
            if (info is !null && info.origin_type >= 100) {
                type_id = info.origin_type;
                
                // i8* -> %struct.Test*
                let s_info_temp -> StructInfo = c.struct_id_map.get("" + type_id);
                if (s_info_temp is !null) {
                    let cast_reg -> String = next_reg(c);
                    c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + obj_reg + " to " + s_info_temp.llvm_name + "*\n");
                    obj_reg = cast_reg;
                }
            }
        }
    }
    let s_info -> StructInfo = c.struct_id_map.get("" + type_id);
    if (s_info is null) {
        throw_type_error(node.pos, "Cannot access field on non-struct type (or generic Struct/Class without origin inference).");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    if (node.field_name.starts_with("__")) {
        let class_prefix -> String = "";
        let dot_idx -> Int = s_info.name.length() - 1;
        while (dot_idx >= 0) {
            if (s_info.name[dot_idx] == '.') {
                class_prefix = s_info.name.slice(0, dot_idx + 1);
                break;
            }
            dot_idx -= 1;
        }
        if (c.current_package_prefix != class_prefix) {
            throw_name_error(node.pos, "Member '" + node.field_name + "' is private to '" + s_info.name + "'.");
            return void_result();
        }
    }
    
    let field -> FieldInfo = find_field(s_info, node.field_name);
    
    if (field is !null) {
        let f_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + obj_reg + ", i32 0, i32 " + field.offset + "\n");

        let arr_check -> ArrayInfo = c.array_info_map.get("" + field.type);
        if (arr_check is !null) {
            if (arr_check.size != -1) {
                return CompileResult(reg=f_ptr, type=field.type, is_const_access=obj_res.is_const_access);
            }
        }

        let val_reg -> String = next_reg(c);
        c.output_file.write(c.indent + val_reg + " = load " + field.llvm_type + ", " + field.llvm_type + "* " + f_ptr + "\n");
        return CompileResult(reg=val_reg, type=field.type, is_const_access=obj_res.is_const_access);
    }

    if (s_info.is_interface) {
        let methods -> Vector(Struct) = s_info.vtable;
        let method_count -> Int = 0; if (methods is !null) { method_count = methods.length(); }
        let method_index -> Int = 0;
        let method_node -> MethodDefNode = null;
        while (method_index < method_count) { let candidate -> MethodDefNode = methods[method_index]; if (candidate.name_tok.value == node.field_name) { method_node = candidate; break; } method_index += 1; }
        if (method_node is !null) {
            if (obj_res.is_const_access) {
                throw_type_error(node.pos, "Cannot bind a method through const value");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            let object_ptr -> String = next_reg(c);
            let table_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + object_ptr + " = extractvalue { i8*, i8* } " + obj_reg + ", 0\n");
            c.output_file.write(c.indent + table_ptr + " = extractvalue { i8*, i8* } " + obj_reg + ", 1\n");

            let table_type -> String = "[ " + method_count + " x i8* ]";
            let typed_table -> String = next_reg(c);
            c.output_file.write(c.indent + typed_table + " = bitcast i8* " + table_ptr + " to " + table_type + "*\n");

            let method_addr -> String = next_reg(c);
            let method_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + method_addr + " = getelementptr inbounds " + table_type + ", " + table_type + "* " + typed_table + ", i32 0, i32 " + method_index + "\n");
            c.output_file.write(c.indent + method_ptr + " = load i8*, i8** " + method_addr + "\n");

            let bound_args -> Vector(Struct) = [];
            let param_index -> Int = 0;
            while (method_node.params is !null && param_index < method_node.params.length()) {
                let param -> ParamNode = method_node.params[param_index];
                bound_args.append(TypeListNode(type=resolve_type(c, param.type_tok)));
                param_index += 1;
            }
            let return_type -> Int = resolve_type(c, method_node.return_type);
            let specific_type_id -> Int = get_method_type_id(c, bound_args, return_type);
            let closure -> String = emit_alloc_closure(c, specific_type_id);
            let function_slot -> String = next_reg(c);
            c.output_file.write(c.indent + function_slot + " = bitcast i8* " + closure + " to i8**\n");
            c.output_file.write(c.indent + "store i8* " + method_ptr + ", i8** " + function_slot + "\n");

            let environment_bytes -> String = next_reg(c);
            let environment_slot -> String = next_reg(c);
            c.output_file.write(c.indent + environment_bytes + " = getelementptr inbounds i8, i8* " + closure + ", i32 " + closure_env_offset() + "\n");
            c.output_file.write(c.indent + environment_slot + " = bitcast i8* " + environment_bytes + " to i8**\n");
            c.output_file.write(c.indent + "store i8* " + object_ptr + ", i8** " + environment_slot + "\n");

            emit_retain(c, obj_reg, type_id);
            emit_retain(c, closure, specific_type_id);

            return CompileResult(reg=closure, type=specific_type_id, origin_type=return_type);
        }
    }

    if (s_info.is_class) {
        let vtable_vec -> Vector(Struct) = s_info.vtable;
        let v_len -> Int = 0; if (vtable_vec is !null) { v_len = vtable_vec.length(); }
        let m_idx -> Int = 0;
        let target_func -> FuncInfo = null;
        
        while (m_idx < v_len) {
            let m -> FuncInfo = vtable_vec[m_idx];
            if (m.base_name == node.field_name) {
                target_func = m;
                break;
            }
            m_idx += 1;
        }
        
        if (target_func is !null) {
            if (obj_res.is_const_access) {
                throw_type_error(node.pos, "Cannot bind a method through const value");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            let class_llvm_ty -> String = s_info.llvm_name;
            let vptr_addr -> String = next_reg(c);
            c.output_file.write(c.indent + vptr_addr + " = getelementptr inbounds " + class_llvm_ty + ", " + class_llvm_ty + "* " + obj_reg + ", i32 0, i32 0\n");
            let vtable_i8ptr -> String = next_reg(c);
            c.output_file.write(c.indent + vtable_i8ptr + " = load i8*, i8** " + vptr_addr + "\n");
            let vtable_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + vtable_ptr + " = bitcast i8* " + vtable_i8ptr + " to " + class_vtable_type(c, s_info) + "*\n");
            let method_i8ptr_addr -> String = next_reg(c);
            c.output_file.write(c.indent + method_i8ptr_addr + " = getelementptr inbounds " + class_vtable_type(c, s_info) + ", " + class_vtable_type(c, s_info) + "* " + vtable_ptr + ", i32 0, i32 " + m_idx + "\n");
            let method_i8ptr -> String = next_reg(c);
            c.output_file.write(c.indent + method_i8ptr + " = load i8*, i8** " + method_i8ptr_addr + "\n");

            let bound_args -> Vector(Struct) = [];
            let ba_idx -> Int = 1;
            while (ba_idx < target_func.arg_types.length()) {
                bound_args.append(target_func.arg_types[ba_idx]);
                ba_idx += 1;
            }
            let specific_type_id -> Int = get_method_type_id(c, bound_args, target_func.ret_type);
            let clo_payload -> String = emit_alloc_closure(c, specific_type_id);
            
            let clo_func_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + clo_func_ptr + " = bitcast i8* " + clo_payload + " to i8**\n");
            c.output_file.write(c.indent + "store i8* " + method_i8ptr + ", i8** " + clo_func_ptr + "\n");
            
            let clo_env_ptr_i8 -> String = next_reg(c);
            c.output_file.write(c.indent + clo_env_ptr_i8 + " = getelementptr inbounds i8, i8* " + clo_payload + ", i32 " + closure_env_offset() + "\n");
            let clo_env_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + clo_env_ptr + " = bitcast i8* " + clo_env_ptr_i8 + " to i8**\n");
            let obj_i8_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + obj_i8_ptr + " = bitcast " + class_llvm_ty + "* " + obj_reg + " to i8*\n");
            c.output_file.write(c.indent + "store i8* " + obj_i8_ptr + ", i8** " + clo_env_ptr + "\n");
            
            emit_retain(c, obj_reg, type_id);
            
            return CompileResult(reg=clo_payload, type=specific_type_id, origin_type=target_func.ret_type);
        }
    }

    throw_name_error(node.pos, "Field '" + node.field_name + "' not found in struct '" + s_info.name + "'.");
    return CompileResult(reg="poison", type=TYPE_POISON);
}

func compile_field_assign(c -> Compiler, node -> FieldAssignNode) -> CompileResult {
    if (reject_const_write(c, node.obj, node.pos)) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    let obj_base -> BaseNode = node.obj;

    let is_module -> Bool = false;
    let full_name -> String = "";
    let path_parts -> Vector(String) = [];
    let curr_obj -> Struct = node.obj;
    let curr_base -> BaseNode = curr_obj;
    while (curr_base.type == NODE_FIELD_ACCESS) {
        let inner_f -> FieldAccessNode = curr_obj;
        path_parts.append(inner_f.field_name);
        curr_obj = inner_f.obj;
        curr_base = curr_obj;
    }
    if (curr_base.type == NODE_VAR_ACCESS) {
        let root_node -> VarAccessNode = curr_obj;
        let root_name -> String = root_node.name_tok.value;
        if (find_symbol(c, root_name) is null) {
            let module_prefix -> String = c.current_file_visible_prefixes.get(root_name);
            if (module_prefix is !null) {
                full_name = module_member_name(module_prefix, path_parts, node.field_name);
                is_module = true;
            } else {
                let source_name -> String = module_member_name(root_name + ".", path_parts, node.field_name);
                let mapped_global -> String = c.current_file_global_aliases.get(source_name);
                if (mapped_global is !null) {
                    full_name = mapped_global;
                    is_module = true;
                }
            }
        }
    }

    if is_module {
        let g_alias_var -> String = c.global_var_aliases.get(full_name);
        if (g_alias_var is !null) { full_name = g_alias_var; }

        let g_info -> SymbolInfo = c.global_symbol_table.get(full_name);
        if (node.field_name.starts_with("__")) {
            throw_name_error(node.pos, "Undefined module variable '" + full_name + "'.");
            return void_result();
        }
        if (g_info is null) {
            throw_name_error(node.pos, "Undefined module variable '" + full_name + "'.");
            return void_result();
        }
        if (g_info.is_const) {
            throw_type_error(node.pos, "Cannot assign to constant module variable '" + full_name + "'.");
            return void_result();
        }
        
        c.expected_type = g_info.type;
        let val_res -> CompileResult = compile_node(c, node.value);
        c.expected_type = 0;
        
        val_res = emit_implicit_cast(c, val_res, g_info.type, node.pos);
        
        let f_ptr -> String = g_info.reg;

        if (result_owns_value(c, g_info.type)) {
            if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, g_info.type); }
            emit_drop_slot(c, f_ptr, g_info.type);
        }
        
        let store_ty -> String = get_llvm_type_str(c, g_info.type);
        c.output_file.write(c.indent + "store " + store_ty + " " + val_res.reg + ", " + store_ty + "* " + f_ptr + "\n");
        return val_res;
    }

    if (obj_base.type == NODE_CALL || obj_base.type == NODE_VECTOR_LIT || obj_base.type == NODE_STRING) {
        throw_invalid_syntax(node.pos, "Cannot assign to a field of a temporary right-value object. Assign it to a variable first.");
        return void_result();
    }
    
    let obj_res -> CompileResult = compile_node(c, node.obj);
    if (obj_res is !null && obj_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let struct_type_id -> Int = obj_res.type;
    let struct_ptr_reg -> String = obj_res.reg;

    if ((struct_type_id == TYPE_GENERIC_STRUCT || struct_type_id == TYPE_GENERIC_CLASS) && obj_res.origin_type >= 100) {
        struct_type_id = obj_res.origin_type;
        let s_info_temp -> StructInfo = c.struct_id_map.get("" + struct_type_id);
        if (s_info_temp is !null) {
            let cast_reg -> String = next_reg(c);
            c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + struct_ptr_reg + " to " + s_info_temp.llvm_name + "*\n");
            struct_ptr_reg = cast_reg;
        }
    }

    let s_info -> StructInfo = c.struct_id_map.get("" + struct_type_id);
    if (s_info is null) {
        throw_type_error(node.pos, "Cannot assign field to non-struct type.");
        return void_result();
    }

    if (node.field_name.starts_with("__")) {
        let class_prefix -> String = "";
        let dot_idx -> Int = s_info.name.length() - 1;
        while (dot_idx >= 0) {
            if (s_info.name[dot_idx] == '.') {
                class_prefix = s_info.name.slice(0, dot_idx + 1);
                break;
            }
            dot_idx -= 1;
        }
        if (c.current_package_prefix != class_prefix) {
            throw_name_error(node.pos, "Member '" + node.field_name + "' is private to '" + s_info.name + "'.");
            return void_result();
        }
    }

    let field -> FieldInfo = find_field(s_info, node.field_name);
    if (field is null) {
        throw_name_error(node.pos, "Field '" + node.field_name + "' not found in struct '" + s_info.name + "'.");
        return void_result();
    }

    c.expected_type = field.type;
    let val_res -> CompileResult = compile_node(c, node.value);
    c.expected_type = 0;

    val_res = emit_implicit_cast(c, val_res, field.type, node.pos);
    
    let f_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + struct_ptr_reg + ", i32 0, i32 " + field.offset + "\n");

    if (result_owns_value(c, field.type)) {
        if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, field.type); }
        emit_drop_slot(c, f_ptr, field.type);
    }

    let store_ty -> String = get_llvm_type_str(c, field.type);
    c.output_file.write(c.indent + "store " + store_ty + " " + val_res.reg + ", " + store_ty + "* " + f_ptr + "\n");
    return val_res;
}

// TODO: Add whitelang abi
func normalize_extern_abi(name -> String, pos -> Position) -> String {
    if (name == "C" || name == "c") { return "C"; }
    if (name == "system" || name == "System" || name == "SYSTEM") { return "system"; }
    throw_extern_error(pos, "Unsupported extern ABI '" + name + "'. Expected 'C' or 'system'.");
    return "C";
}
func extern_callconv(abi_name -> String) -> String {
    if (abi_name == "system" && get_target_os() == sys.Os.Windows) {
        if (get_target_arch() == sys.Arch.X86) { return "x86_stdcallcc "; }
        if (get_target_arch() == sys.Arch.X86_64) { return "win64cc "; }
    }
    return "ccc ";
}
func func_callconv(info -> FuncInfo) -> String {
    if (info is null || info.abi_name is null || info.abi_name.length() == 0) { return ""; }
    return extern_callconv(info.abi_name);
}
func register_extern_library(c -> Compiler, name -> String, pos -> Position) -> Void {
    if (name is null || name.length() == 0) { return; }

    let i -> Int = 0;
    while (i < name.length()) {
        let ch -> Char = name[i];
        let valid -> Bool = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                            (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' ||
                            ch == '+' || ch == '.';
        if (!valid) {
            throw_extern_error(pos, "Invalid extern library name '" + name + "'. Use a linker library name without paths or flags.");
            return;
        }
        i += 1;
    }

    i = 0;
    while (i < c.extra_libs.length()) {
        if (c.extra_libs[i] == name) { return; }
        i += 1;
    }
    c.extra_libs.append(name);
}

func vector_capacity_limit(elem_size -> Int) -> Long {
    let limit -> Long = 2147483647L;
    if (get_target_pointer_bits() == 32) {
        let address_limit -> Long = 4294967295L / Long(elem_size);
        if (address_limit < limit) { limit = address_limit; }
    }
    return limit;
}
func backend_symbol_signature(name -> String) -> String {
    if (get_target_os() != sys.Os.Windows) { return ""; }
    let size_ty -> String = get_size_llvm_type();
    if (name == "memcpy" || name == "memmove") { return "ccc i8* (i8*, i8*, " + size_ty + ")"; }
    if (name == "memset") { return "ccc i8* (i8*, i32, " + size_ty + ")"; }
    return "";
}
func compile_extern_func(c -> Compiler, node -> ExternFuncNode) -> CompileResult {
    let func_name -> String = node.name_tok.value;
    let abi_name -> String = normalize_extern_abi(node.abi_name, node.pos);
    let ret_type_id -> Int = resolve_type(c, node.ret_type_tok);
    if (ret_type_id == TYPE_AUTO) {
        throw_extern_error(node.pos, "Extern functions cannot use Auto as a return type.");
        return void_result();
    }
    if (node.is_varargs && abi_name != "C") {
        throw_extern_error(node.pos, "Variadic extern functions require the C ABI.");
        return void_result();
    }

    let arg_types -> Vector(Struct) = [];
    let arg_names -> Vector(String) = [];
    let params -> Vector(Struct) = node.params;
    if (!check_duplicate_params(params, "extern function '" + func_name + "'", node.pos)) {
        return void_result();
    }
    let p_len -> Int = 0; if (params is !null) { p_len = params.length(); }
    let p_idx -> Int = 0;
    let params_str -> String = "";

    while (p_idx < p_len) {
        let p -> ParamNode = params[p_idx];
        let p_id -> Int = resolve_type(c, p.type_tok);
        if (p_id == TYPE_AUTO) {
            throw_type_error(p.pos, "Extern functions cannot use Auto parameters.");
            return void_result();
        }

        arg_types.append(TypeListNode(type=p_id));
        arg_names.append(p.name_tok.value);
        if (p_idx > 0) { params_str += ", "; }
        params_str += get_llvm_type_str(c, p_id);
        p_idx += 1;
    }

    if (node.is_varargs) {
        if (p_len > 0) { params_str += ", "; }
        params_str += "...";
    }

    let full_func_name -> String = func_name;
    if (c.current_package_prefix.length() > 0) { full_func_name = c.current_package_prefix + func_name; }

    let existing_func -> FuncInfo = c.func_table.get(full_func_name);
    if (existing_func is !null) {
        throw_name_error(node.pos, "Function '" + full_func_name + "' is already defined.");
        return void_result();
    }

    let callconv -> String = extern_callconv(abi_name);
    let ret_llvm -> String = get_llvm_type_str(c, ret_type_id);
    let signature -> String = callconv + ret_llvm + " (" + params_str + ")";
    let backend_signature -> String = backend_symbol_signature(func_name);
    if (backend_signature.length() > 0 && signature != backend_signature) {
        throw_extern_error(node.pos, "Extern declaration for compiler-provided symbol '" + func_name + "' has an incompatible signature.");
        return void_result();
    }
    let existing_decl -> StringConstant = c.declared_externs.get(func_name);
    if (existing_decl is null) {
        if (backend_signature.length() == 0) { c.output_file.write("declare " + callconv + ret_llvm + " @" + func_name + "(" + params_str + ")\n"); }
        c.declared_externs.put(func_name, StringConstant(id=0, value=signature));
    } else if (existing_decl.value.length() > 0 && existing_decl.value != signature) {
        throw_extern_error(node.pos, "Conflicting extern declaration for symbol '" + func_name + "'.");
        return void_result();
    }

    c.func_table.put(full_func_name, FuncInfo(name=func_name, base_name=func_name, ret_type=ret_type_id, arg_types=arg_types, arg_names=arg_names, is_varargs=node.is_varargs, abi_name=abi_name, mutates_self=false));
    register_extern_library(c, node.link_name, node.pos);
    return void_result();
}
func compile_extern_block(c -> Compiler, node -> ExternBlockNode) -> CompileResult {
    let funcs -> Vector(Struct) = node.funcs;
    let len -> Int = 0; if (funcs is !null) { len = funcs.length(); }
    let i -> Int = 0;
    while (i < len) {
        let f_node -> ExternFuncNode = funcs[i];
        compile_extern_func(c, f_node);
        i += 1;
    }
    return void_result();
}


func compile_array_literal(c -> Compiler, lit_node -> VectorLitNode, target_arr_id -> Int, ptr_reg -> String) -> Void {
    let target_arr -> ArrayInfo = c.array_info_map.get("" + target_arr_id);
    if (target_arr is null) { return; }
    
    if (lit_node.count > target_arr.size) {
        throw_type_error(lit_node.pos, "Array literal too large: expected " + target_arr.size + " elements, got " + lit_node.count);
        return;
    }
    
    let lit_i -> Int = 0;
    let elem_ty_str -> String = get_llvm_type_str(c, target_arr.base_type);
    c.output_file.write(c.indent + "store " + target_arr.llvm_name + " zeroinitializer, " + target_arr.llvm_name + "* " + ptr_reg + "\n");
    
    while (lit_i < lit_node.count) {
        let elem_node -> ArgNode = lit_node.elements[lit_i];
        let elem_base -> BaseNode = elem_node.val;
        
        let elem_ptr_reg -> String = next_reg(c);
        c.output_file.write(c.indent + elem_ptr_reg + " = getelementptr inbounds " + target_arr.llvm_name + ", " + target_arr.llvm_name + "* " + ptr_reg + ", i32 0, i32 " + lit_i + "\n");
        
        let is_nested -> Bool = false;
        if (elem_base.type == NODE_VECTOR_LIT) {
            let inner_arr_info -> ArrayInfo = c.array_info_map.get("" + target_arr.base_type);
            if (inner_arr_info is !null) {
                is_nested = true;
                let inner_lit -> VectorLitNode = elem_node.val;
                compile_array_literal(c, inner_lit, target_arr.base_type, elem_ptr_reg);
            }
        }
        
        if (!is_nested) {
            c.expected_type = target_arr.base_type;
            let elem_res -> CompileResult = compile_node(c, elem_node.val);
            c.expected_type = 0;
            
            let casted_res -> CompileResult = emit_implicit_cast(c, elem_res, target_arr.base_type, lit_node.pos);
            c.output_file.write(c.indent + "store " + elem_ty_str + " " + casted_res.reg + ", " + elem_ty_str + "* " + elem_ptr_reg + "\n");
            
            if (c.scope_depth > 0 && result_owns_value(c, target_arr.base_type) && !casted_res.owns_ref) {
                emit_retain_value(c, casted_res.reg, target_arr.base_type);
            }
        }
        
        lit_i += 1;
    }
}

func compile_vector_append(c -> Compiler, vec_node -> Struct, call_node -> CallNode) -> CompileResult {
    if (reject_const_write(c, vec_node, call_node.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let args -> Vector(Struct) = call_node.args;
    let a_len -> Int = 0;
    if (args is !null) { a_len = args.length(); }
    if (a_len != 1) { throw_type_error(call_node.pos, "'append' expects exactly 1 argument."); return void_result(); }
    let append_names -> Vector(String) = ["value"];
    args = bind_call_args(args, append_names, 0, call_node.pos);
    if (args is null) { return CompileResult(reg="poison", type=TYPE_POISON); }
    
    let arg_node -> ArgNode = args[0];
    let vec_res -> CompileResult = compile_node(c, vec_node);
    if (vec_res is !null && vec_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

    let v_info -> SymbolInfo = c.vector_base_map.get("" + vec_res.type);
    if (v_info is null) { throw_type_error(call_node.pos, "'append' is only for Vectors."); return void_result(); }
    
    let elem_type -> Int = v_info.type;

    c.expected_type = elem_type;
    let arg_res -> CompileResult = compile_node(c, arg_node.val);
    c.expected_type = 0;

    arg_res = emit_implicit_cast(c, arg_res, elem_type, call_node.pos);
    let elem_ty_str -> String = get_llvm_type_str(c, elem_type);
    let struct_ty -> String = get_vector_llvm_type(c, elem_type);
    let size_ty -> String = get_size_llvm_type();

    let size_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_res.reg + ", i32 0, i32 0\n");
    let size_val -> String = next_reg(c);
    c.output_file.write(c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");
    
    let cap_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + cap_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_res.reg + ", i32 0, i32 1\n");
    let cap_val -> String = next_reg(c);
    c.output_file.write(c.indent + cap_val + " = load " + size_ty + ", " + size_ty + "* " + cap_ptr + "\n");

    let cmp_reg -> String = next_reg(c);
    c.output_file.write(c.indent + cmp_reg + " = icmp uge " + size_ty + " " + size_val + ", " + cap_val + "\n");
    
    let grow_label -> String = next_label(c);
    let push_label -> String = next_label(c);
    
    c.output_file.write(c.indent + "br i1 " + cmp_reg + ", label %" + grow_label + ", label %" + push_label + "\n");

    c.output_file.write("\n" + grow_label + ":\n");
    
    let is_zero_cap -> String = next_reg(c);
    c.output_file.write(c.indent + is_zero_cap + " = icmp eq " + size_ty + " " + cap_val + ", 0\n");
    let cap_overflow -> String = next_reg(c);
    let elem_size -> Int = get_type_size_bytes(c, elem_type);
    let max_capacity -> Long = vector_capacity_limit(elem_size);
    let growth_limit -> Long = max_capacity / 2;
    c.output_file.write(c.indent + cap_overflow + " = icmp ugt " + size_ty + " " + cap_val + ", " + growth_limit + "\n");
    let grow_fail -> String = next_label(c);
    let grow_calc -> String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + cap_overflow + ", label %" + grow_fail + ", label %" + grow_calc + "\n");

    c.output_file.write("\n" + grow_fail + ":\n");
    c.output_file.write(c.indent + "call void @__wl_oom()\n");
    c.output_file.write(c.indent + "unreachable\n");

    c.output_file.write("\n" + grow_calc + ":\n");
    let dbl_cap -> String = next_reg(c);
    c.output_file.write(c.indent + dbl_cap + " = mul " + size_ty + " " + cap_val + ", 2\n");
    let new_cap -> String = next_reg(c);
    c.output_file.write(c.indent + new_cap + " = select i1 " + is_zero_cap + ", " + size_ty + " 4, " + size_ty + " " + dbl_cap + "\n");

    let data_field_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + data_field_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_res.reg + ", i32 0, i32 2\n");
    let old_data -> String = next_reg(c);
    c.output_file.write(c.indent + old_data + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_field_ptr + "\n");
    
    let old_data_i8 -> String = next_reg(c);
    c.output_file.write(c.indent + old_data_i8 + " = bitcast " + elem_ty_str + "* " + old_data + " to i8*\n");

    let bytes_overflow -> String = next_reg(c);
    c.output_file.write(c.indent + bytes_overflow + " = icmp ugt " + size_ty + " " + new_cap + ", " + max_capacity + "\n");
    let bytes_fail -> String = next_label(c);
    let resize_label -> String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + bytes_overflow + ", label %" + bytes_fail + ", label %" + resize_label + "\n");

    c.output_file.write("\n" + bytes_fail + ":\n");
    c.output_file.write(c.indent + "call void @__wl_oom()\n");
    c.output_file.write(c.indent + "unreachable\n");

    c.output_file.write("\n" + resize_label + ":\n");
    
    let new_bytes -> String = next_reg(c);
    c.output_file.write(c.indent + new_bytes + " = mul " + size_ty + " " + new_cap + ", " + elem_size + "\n");
    
    let resize_hook -> String = get_mangled_symbol(c, "memory_resize", call_node.pos);
    let new_data_i8 -> String = next_reg(c);
    c.output_file.write(c.indent + new_data_i8 + " = call i8* @" + resize_hook + "(i8* " + old_data_i8 + ", " + size_ty + " " + new_bytes + ")\n");
    emit_alloc_check(c, new_data_i8);
    
    let new_data_typed -> String = next_reg(c);
    c.output_file.write(c.indent + new_data_typed + " = bitcast i8* " + new_data_i8 + " to " + elem_ty_str + "*\n");
    c.output_file.write(c.indent + "store " + elem_ty_str + "* " + new_data_typed + ", " + elem_ty_str + "** " + data_field_ptr + "\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + new_cap + ", " + size_ty + "* " + cap_ptr + "\n");
    
    c.output_file.write(c.indent + "br label %" + push_label + "\n");
    c.output_file.write("\n" + push_label + ":\n");
    
    let final_data_field_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + final_data_field_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_res.reg + ", i32 0, i32 2\n");
    let final_data -> String = next_reg(c);
    c.output_file.write(c.indent + final_data + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + final_data_field_ptr + "\n");
    
    let slot_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + final_data + ", " + size_ty + " " + size_val + "\n");
    
    if (result_owns_value(c, elem_type) && !arg_res.owns_ref) {
        emit_retain_value(c, arg_res.reg, elem_type);
    }
    c.output_file.write(c.indent + "store " + elem_ty_str + " " + arg_res.reg + ", " + elem_ty_str + "* " + slot_ptr + "\n");
    
    let new_size -> String = next_reg(c);
    c.output_file.write(c.indent + new_size + " = add " + size_ty + " " + size_val + ", 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + new_size + ", " + size_ty + "* " + size_ptr + "\n");
    
    return void_result();
}
func compile_vector_drop(c -> Compiler, vec_node -> Struct, call_node -> CallNode) -> CompileResult {
    if (reject_const_write(c, vec_node, call_node.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let args -> Vector(Struct) = call_node.args;
    let a_len -> Int = 0;
    if (args is !null) { a_len = args.length(); }
    if (a_len > 0) { throw_type_error(call_node.pos, "'drop' expects 0 arguments."); return void_result(); }
    
    let vec_res -> CompileResult = compile_node(c, vec_node);
    if (vec_res is !null && vec_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let v_info -> SymbolInfo = c.vector_base_map.get("" + vec_res.type);
    let elem_type -> Int = v_info.type;
    let elem_ty_str -> String = get_llvm_type_str(c, elem_type);
    let struct_ty -> String = get_vector_llvm_type(c, elem_type);
    let size_ty -> String = get_size_llvm_type();

    let size_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_res.reg + ", i32 0, i32 0\n");
    let size_val -> String = next_reg(c);
    c.output_file.write(c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");

    let cmp_reg -> String = next_reg(c);
    c.output_file.write(c.indent + cmp_reg + " = icmp ugt " + size_ty + " " + size_val + ", 0\n");
    
    let pop_label -> String = next_label(c);
    let empty_label -> String = next_label(c);
    let end_label -> String = next_label(c);
    
    c.output_file.write(c.indent + "br i1 " + cmp_reg + ", label %" + pop_label + ", label %" + empty_label + "\n");

    c.output_file.write("\n" + empty_label + ":\n");

    emit_runtime_error(c, call_node.pos, "drop from empty vector");

    c.output_file.write("\n" + pop_label + ":\n");
    
    // size--
    let new_size -> String = next_reg(c);
    c.output_file.write(c.indent + new_size + " = sub " + size_ty + " " + size_val + ", 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + new_size + ", " + size_ty + "* " + size_ptr + "\n");

    let data_field_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + data_field_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_res.reg + ", i32 0, i32 2\n");
    let data_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + data_ptr + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_field_ptr + "\n");
    
    let slot_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", " + size_ty + " " + new_size + "\n");
    
    let ret_val -> String = next_reg(c);
    c.output_file.write(c.indent + ret_val + " = load " + elem_ty_str + ", " + elem_ty_str + "* " + slot_ptr + "\n");
    
    if (is_ref_type(c, elem_type)) {
        c.output_file.write(c.indent + "store " + elem_ty_str + " null, " + elem_ty_str + "* " + slot_ptr + "\n");
    } else if (is_fallible_type(c, elem_type)) {
        c.output_file.write(c.indent + "store " + elem_ty_str + " zeroinitializer, " + elem_ty_str + "* " + slot_ptr + "\n");
    }
    c.output_file.write(c.indent + "br label %" + end_label + "\n");
    
    c.output_file.write("\n" + end_label + ":\n");
    return CompileResult(reg=ret_val, type=elem_type, owns_ref=result_owns_value(c, elem_type));
}
func compile_vector_lit(c -> Compiler, node -> VectorLitNode) -> CompileResult {
    let count -> Int = node.count;
    let elem_type_id -> Int = TYPE_INT; 
    let elements -> Vector(Struct) = node.elements;
    let e_len -> Int = 0;
    if (elements is !null) { e_len = elements.length(); }
    
    let has_expected -> Bool = false;
    if (c.expected_type > 0) {
        let v_info -> SymbolInfo = c.vector_base_map.get("" + c.expected_type);
        if (v_info is !null) {
            elem_type_id = v_info.type;
            has_expected = true;
        } else {
            elem_type_id = c.expected_type;
            has_expected = true;
        }
    }
    
    if (!has_expected && e_len > 0) {
        let first_arg -> ArgNode = elements[0];
        let old_exp -> Int = c.expected_type;
        c.expected_type = 0;
        let first_res -> CompileResult = compile_node(c, first_arg.val);
        c.expected_type = old_exp;
        elem_type_id = first_res.type;
    }
    
    let vec_type_id -> Int = get_vector_type_id(c, elem_type_id);
    let elem_ty_str -> String = get_llvm_type_str(c, elem_type_id);
    let struct_name -> String = get_vector_llvm_type(c, elem_type_id);
    let size_ty -> String = get_size_llvm_type();

    let struct_size_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + struct_size_ptr + " = getelementptr " + struct_name + ", " + struct_name + "* null, i32 1\n");
    let struct_size -> String = next_reg(c);
    c.output_file.write(c.indent + struct_size + " = ptrtoint " + struct_name + "* " + struct_size_ptr + " to " + size_ty + "\n");
    let vec_ptr -> String = emit_alloc_obj(c, struct_size, "" + vec_type_id, struct_name + "*");
    
    let arr_size_ptr -> String = next_reg(c);
    let alloc_count -> Int = count;
    if (alloc_count == 0) { alloc_count = 1; }
    c.output_file.write(c.indent + arr_size_ptr + " = getelementptr " + elem_ty_str + ", " + elem_ty_str + "* null, " + size_ty + " " + alloc_count + "\n");
    let arr_bytes -> String = next_reg(c);
    c.output_file.write(c.indent + arr_bytes + " = ptrtoint " + elem_ty_str + "* " + arr_size_ptr + " to " + size_ty + "\n");
    
    let alloc_hook -> String = get_mangled_symbol(c, "memory_alloc", node.pos);
    let raw_data -> String = next_reg(c);
    c.output_file.write(c.indent + raw_data + " = call i8* @" + alloc_hook + "(" + size_ty + " " + arr_bytes + ")\n");
    emit_alloc_check(c, raw_data);
    let data_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + data_ptr + " = bitcast i8* " + raw_data + " to " + elem_ty_str + "*\n");

    // vector length and capacity follow the target pointer width
    let size_ptr -> String = next_reg(c); 
    c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + struct_name + ", " + struct_name + "* " + vec_ptr + ", i32 0, i32 0\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + count + ", " + size_ty + "* " + size_ptr + "\n");
    
    // capacity
    let cap_ptr -> String = next_reg(c); 
    c.output_file.write(c.indent + cap_ptr + " = getelementptr inbounds " + struct_name + ", " + struct_name + "* " + vec_ptr + ", i32 0, i32 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + count + ", " + size_ty + "* " + cap_ptr + "\n"); 
    
    // data pointer
    let data_field_ptr -> String = next_reg(c); 
    c.output_file.write(c.indent + data_field_ptr + " = getelementptr inbounds " + struct_name + ", " + struct_name + "* " + vec_ptr + ", i32 0, i32 2\n");
    c.output_file.write(c.indent + "store " + elem_ty_str + "* " + data_ptr + ", " + elem_ty_str + "** " + data_field_ptr + "\n");
    
    let idx -> Int = 0;
    while (idx < e_len) {
        let curr -> ArgNode = elements[idx];

        let old_exp -> Int = c.expected_type;
        c.expected_type = elem_type_id;
        let val_res -> CompileResult = compile_node(c, curr.val);
        c.expected_type = old_exp;

        val_res = emit_implicit_cast(c, val_res, elem_type_id, node.pos);
        
        let slot_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", " + size_ty + " " + idx + "\n");

        if (result_owns_value(c, elem_type_id) && !val_res.owns_ref) {
            emit_retain_value(c, val_res.reg, elem_type_id);
        }
        
        c.output_file.write(c.indent + "store " + elem_ty_str + " " + val_res.reg + ", " + elem_ty_str + "* " + slot_ptr + "\n");

        idx += 1;
    }
    
    return CompileResult(reg=vec_ptr, type=vec_type_id);
}

func compile_length_method(c -> Compiler, obj_node -> Struct, call_node -> CallNode) -> CompileResult {
    let args -> Vector(Struct) = call_node.args;
    let a_len -> Int = 0;
    if (args is !null) { a_len = args.length(); }
    if (a_len > 0) {
        throw_type_error(call_node.pos, "Method 'length' does not accept arguments.");
        return void_result();
    }

    let obj_res -> CompileResult = compile_node(c, obj_node);
    if (obj_res is !null && obj_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let type_id -> Int = obj_res.type;

    // String.length()
    if (type_id == TYPE_STRING) {
        // read len directly from struct field 1
        let len_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + len_ptr + " = getelementptr inbounds %struct.$String, %struct.$String* " + obj_res.reg + ", i32 0, i32 1\n");
        let len_val -> String = next_reg(c);
        c.output_file.write(c.indent + len_val + " = load i32, i32* " + len_ptr + "\n");
        return CompileResult(reg=len_val, type=TYPE_INT);
    }

    // Vector.length()
    let is_vec -> Bool = false;
    if (type_id >= 100) {
        let v_info -> SymbolInfo = c.vector_base_map.get("" + type_id);
        if (v_info is !null) { is_vec = true; }
    }

    let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
        if (arr_info is !null) {
            if (arr_info.size == -1) {
                let parts -> SliceParts = emit_slice_parts(c, obj_res.reg, type_id, call_node.pos);
                let trunc_reg -> String = emit_size_to_int(c, parts.length);
                return CompileResult(reg=trunc_reg, type=TYPE_INT);
            } else {
                return CompileResult(reg="" + arr_info.size, type=TYPE_INT);
            }
        }

    if is_vec {
        let v_info -> SymbolInfo = c.vector_base_map.get("" + type_id);
        let struct_ty -> String = get_vector_llvm_type(c, v_info.type);
        let size_ty -> String = get_size_llvm_type();
        
        let size_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + obj_res.reg + ", i32 0, i32 0\n");
        
        let size_val -> String = next_reg(c);
        c.output_file.write(c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");

        let trunc_reg -> String = emit_size_to_int(c, size_val);
        
        return CompileResult(reg=trunc_reg, type=TYPE_INT);
    }

    throw_type_error(call_node.pos, "Method 'length' is not defined for type " + get_type_name(c, type_id));
    return void_result();
}

func compile_index_access(c -> Compiler, node -> IndexAccessNode, handled -> Bool) -> CompileResult {
    check_out_index(c, node.target, node.index_node, node.pos);
    let target_res -> CompileResult = compile_node(c, node.target);
    if (target_res is !null && target_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

    let s_info -> StructInfo = c.struct_id_map.get("" + target_res.type);
    if (s_info is !null && s_info.is_class) {
        let has_get -> Bool = false;
        let v_len -> Int = 0; if (s_info.vtable is !null) { v_len = s_info.vtable.length(); }
        let m_idx -> Int = 0;
        while (m_idx < v_len) {
            let m -> FuncInfo = s_info.vtable[m_idx];
            if (m.base_name == "get") { has_get = true; break; }
            m_idx += 1;
        }

        if has_get {
            let fake_args -> Vector(Struct) = [];
            fake_args.append(ArgNode(val=node.index_node, name=null));
            let fake_call -> CallNode = CallNode(type=NODE_CALL, callee=null, args=fake_args, type_args=null, pos=node.pos, preserve_fallible=handled);
            return compile_class_method_call(c, s_info, target_res, "get", fake_call);
        }
    }

    let old_exp -> Int = c.expected_type;
    c.expected_type = TYPE_INT;
    let index_res -> CompileResult = compile_node(c, node.index_node);
    c.expected_type = old_exp;
    if (index_res is !null && index_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    
    if (index_res.type != TYPE_INT) {
        throw_type_error(node.pos, "Index must be an Integer.");
        return void_result();
    }

    // String index access
    if (target_res.type == TYPE_STRING) {
        let src_buf -> String = next_reg(c);
        let src_struct_buf -> String = next_reg(c);
        c.output_file.write(c.indent + src_struct_buf + " = getelementptr inbounds %struct.$String, %struct.$String* " + target_res.reg + ", i32 0, i32 0\n");
        c.output_file.write(c.indent + src_buf + " = load i8*, i8** " + src_struct_buf + "\n");
        
        let src_len -> String = next_reg(c);
        let src_struct_len -> String = next_reg(c);
        c.output_file.write(c.indent + src_struct_len + " = getelementptr inbounds %struct.$String, %struct.$String* " + target_res.reg + ", i32 0, i32 1\n");
        c.output_file.write(c.indent + src_len + " = load i32, i32* " + src_struct_len + "\n");
        
        // emit bounds check
        emit_array_bounds_check(c, index_res.reg, src_len, node.pos);
        
        let addr_reg -> String = next_reg(c);
        c.output_file.write(c.indent + addr_reg + " = getelementptr inbounds i8, i8* " + src_buf + ", i32 " + index_res.reg + "\n");
        
        let load_reg -> String = next_reg(c);
        c.output_file.write(c.indent + load_reg + " = load i8, i8* " + addr_reg + "\n");
        
        return CompileResult(reg=load_reg, type=TYPE_BYTE, origin_type=0);
    }

    if (is_pointer_type(c, target_res.type)) {
        let base_info -> SymbolInfo = c.ptr_base_map.get("" + target_res.type);
        if (base_info is !null) {
            let elem_type -> Int = base_info.type;
            
            if (elem_type == TYPE_VOID) {
                throw_type_error(node.pos, "Cannot index 'ptr Void'. Cast it to a specific pointer type first.");
                return void_result();
            }
            emit_pointer_null_check(c, target_res.reg, target_res.type, node.pos);
            
            let elem_ty_str -> String = get_llvm_type_str(c, elem_type);
            
            let addr_reg -> String = next_reg(c);
            c.output_file.write(c.indent + addr_reg + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + target_res.reg + ", i32 " + index_res.reg + "\n");
            
            let load_reg -> String = next_reg(c);
            c.output_file.write(c.indent + load_reg + " = load " + elem_ty_str + ", " + elem_ty_str + "* " + addr_reg + "\n");
            
            return CompileResult(reg=load_reg, type=elem_type, origin_type=elem_type);
        }
    }

    // Array / Slice access
    let arr_info -> ArrayInfo = c.array_info_map.get("" + target_res.type);
    if (arr_info is !null) {
        let elem_type -> Int = arr_info.base_type;
        let elem_ty_str -> String = get_llvm_type_str(c, elem_type);
        
        let idx_i32 -> String = index_res.reg;

        let curr_len -> String = "";
        let data_ptr -> String = "";
        if (arr_info.size == -1) {
            let parts -> SliceParts = emit_slice_parts(c, target_res.reg, target_res.type, node.pos);
            curr_len = emit_size_to_int(c, parts.length);
            data_ptr = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + parts.data + ", " + get_size_llvm_type() + " " + parts.start + "\n");
        } else {
            curr_len = "" + arr_info.size;
            data_ptr = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + target_res.reg + ", i32 0, i32 0\n");
        }

        emit_array_bounds_check(c, idx_i32, curr_len, node.pos);

        let ptr_reg -> String = next_reg(c);
        c.output_file.write(c.indent + ptr_reg + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", i32 " + idx_i32 + "\n");

        if (c.array_info_map.get("" + elem_type) is !null) {
            return CompileResult(reg=ptr_reg, type=elem_type, origin_type=elem_type, is_const_access=target_res.is_const_access);
        }
        
        let val_reg -> String = next_reg(c);
        c.output_file.write(c.indent + val_reg + " = load " + elem_ty_str + ", " + elem_ty_str + "* " + ptr_reg + "\n");
        return CompileResult(reg=val_reg, type=elem_type, origin_type=elem_type, is_const_access=target_res.is_const_access);
    }
    
    // Vector access
    let is_vec -> Bool = false;
    if (target_res.type >= 100) {
        if (c.vector_base_map.get("" + target_res.type) is !null) { is_vec = true; }
    }
    
    if is_vec {
        let v_info -> SymbolInfo = c.vector_base_map.get("" + target_res.type);
        let elem_type -> Int = v_info.type;
        let elem_ty_str -> String = get_llvm_type_str(c, elem_type);
        
        let struct_ty -> String = get_vector_llvm_type(c, elem_type);

        emit_vector_bounds_check(c, target_res.reg, index_res.reg, struct_ty, node.pos);

        let data_field_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + data_field_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + target_res.reg + ", i32 0, i32 2\n");
        
        let data_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + data_ptr + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_field_ptr + "\n");

        let slot_ptr -> String = next_reg(c);
        
        let size_index -> String = emit_int_to_size(c, index_res.reg, true);
        c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", " + get_size_llvm_type() + " " + size_index + "\n");
        
        let val_reg -> String = next_reg(c);
        c.output_file.write(c.indent + val_reg + " = load " + elem_ty_str + ", " + elem_ty_str + "* " + slot_ptr + "\n");
        
        return CompileResult(reg=val_reg, type=elem_type, is_const_access=target_res.is_const_access);
    }

    throw_type_error(node.pos, "Type " + get_type_name(c, target_res.type) + " is not indexable.");
    return void_result();
}

func compile_index_assign(c -> Compiler, node -> IndexAssignNode) -> CompileResult {
    if (reject_const_write(c, node.target, node.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }
    check_out_index(c, node.target, node.index_node, node.pos);
    let target_res -> CompileResult = compile_node(c, node.target);
    if (target_res is !null && target_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

    let s_info -> StructInfo = c.struct_id_map.get("" + target_res.type);
    if (s_info is !null && s_info.is_class) {
        let has_put -> Bool = false;
        let v_len -> Int = 0; if (s_info.vtable is !null) { v_len = s_info.vtable.length(); }
        let m_idx -> Int = 0;
        while (m_idx < v_len) {
            let m -> FuncInfo = s_info.vtable[m_idx];
            if (m.base_name == "put") { has_put = true; break; }
            m_idx += 1;
        }

        if has_put {
            let fake_args -> Vector(Struct) = [];
            fake_args.append(ArgNode(val=node.index_node, name=null));
            fake_args.append(ArgNode(val=node.value, name=null));
            let fake_call -> CallNode = CallNode(type=NODE_CALL, callee=null, args=fake_args, type_args=null, pos=node.pos, preserve_fallible=false);
            compile_class_method_call(c, s_info, target_res, "put", fake_call);
            return void_result();
        }
    }

    let old_exp -> Int = c.expected_type;
    c.expected_type = TYPE_INT;
    let index_res -> CompileResult = compile_node(c, node.index_node);
    c.expected_type = old_exp;
    if (index_res is !null && index_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    
    if (index_res.type != TYPE_INT) {
        throw_type_error(node.pos, "Index must be an Integer.");
        return void_result();
    }

    if (is_pointer_type(c, target_res.type)) {
        let base_info -> SymbolInfo = c.ptr_base_map.get("" + target_res.type);
        if (base_info is !null) {
            let elem_type -> Int = base_info.type;
            
            if (elem_type == TYPE_VOID) {
                throw_type_error(node.pos, "Cannot index 'ptr Void'. Cast it to a specific pointer type first.");
                return void_result();
            }
            emit_pointer_null_check(c, target_res.reg, target_res.type, node.pos);

            c.expected_type = elem_type;
            let val_res -> CompileResult = compile_node(c, node.value);
            c.expected_type = 0;
            if (val_res is !null && val_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
            
            val_res = emit_implicit_cast(c, val_res, elem_type, node.pos);
            
            let elem_ty_str -> String = get_llvm_type_str(c, elem_type);
            let addr_reg -> String = next_reg(c);
            c.output_file.write(c.indent + addr_reg + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + target_res.reg + ", i32 " + index_res.reg + "\n");
            
            if (result_owns_value(c, elem_type)) {
                if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, elem_type); }
                emit_drop_slot(c, addr_reg, elem_type);
            }
            
            c.output_file.write(c.indent + "store " + elem_ty_str + " " + val_res.reg + ", " + elem_ty_str + "* " + addr_reg + "\n");
            return val_res;
        }
    }

    // Array / Slice assign
    let arr_info -> ArrayInfo = c.array_info_map.get("" + target_res.type);
    if (arr_info is !null) {
        let elem_type -> Int = arr_info.base_type;
        let elem_ty_str -> String = get_llvm_type_str(c, elem_type);

        c.expected_type = elem_type;
        let val_res -> CompileResult = compile_node(c, node.value);
        c.expected_type = 0;
        if (val_res is !null && val_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
        
        val_res = emit_implicit_cast(c, val_res, elem_type, node.pos);

        let curr_len -> String = "";
        let data_ptr -> String = "";
        if (arr_info.size == -1) {
            let parts -> SliceParts = emit_slice_parts(c, target_res.reg, target_res.type, node.pos);
            curr_len = emit_size_to_int(c, parts.length);
            data_ptr = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + parts.data + ", " + get_size_llvm_type() + " " + parts.start + "\n");
        } else {
            curr_len = "" + arr_info.size;
            data_ptr = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + target_res.reg + ", i32 0, i32 0\n");
        }

        emit_array_bounds_check(c, index_res.reg, curr_len, node.pos);

        let ptr_reg -> String = next_reg(c);
        c.output_file.write(c.indent + ptr_reg + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", i32 " + index_res.reg + "\n");
        
        if (result_owns_value(c, elem_type)) {
            if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, elem_type); }
            emit_drop_slot(c, ptr_reg, elem_type);
        }
        
        c.output_file.write(c.indent + "store " + elem_ty_str + " " + val_res.reg + ", " + elem_ty_str + "* " + ptr_reg + "\n");
        return val_res;
    }
    
    let is_vec -> Bool = false;
    if (target_res.type >= 100) {
        if (c.vector_base_map.get("" + target_res.type) is !null) { is_vec = true; }
    }

    if (target_res.type == TYPE_STRING) {
        let is_magic_func -> Bool = false;
        if (c.curr_func is !null) {
            if (c.curr_func.base_name == "string_slice") {
                is_magic_func = true;
            }
        }

        if is_magic_func {
            let val_res -> CompileResult = compile_node(c, node.value);

            // extract i8* buffer from %struct.$String*
            let src_struct_buf -> String = next_reg(c);
            let src_buf -> String = next_reg(c);
            c.output_file.write(c.indent + src_struct_buf + " = getelementptr inbounds %struct.$String, %struct.$String* " + target_res.reg + ", i32 0, i32 0\n");
            c.output_file.write(c.indent + src_buf + " = load i8*, i8** " + src_struct_buf + "\n");

            let ptr_reg -> String = next_reg(c);
            c.output_file.write(c.indent + ptr_reg + " = getelementptr inbounds i8, i8* " + src_buf + ", i32 " + index_res.reg + "\n");
            val_res = emit_implicit_cast(c, val_res, TYPE_BYTE, node.pos);
            c.output_file.write(c.indent + "store i8 " + val_res.reg + ", i8* " + ptr_reg + "\n");
            return val_res;
        }

        throw_type_error(node.pos, "Strings are immutable. Cannot assign to index.");

        return void_result();
    }

    if is_vec {
        let v_info -> SymbolInfo = c.vector_base_map.get("" + target_res.type);
        let elem_type -> Int = v_info.type;
        let elem_ty_str -> String = get_llvm_type_str(c, elem_type);

        c.expected_type = elem_type;
        let val_res -> CompileResult = compile_node(c, node.value);
        c.expected_type = 0;
        
        val_res = emit_implicit_cast(c, val_res, elem_type, node.pos);
        let struct_ty -> String = get_vector_llvm_type(c, elem_type);

        emit_vector_bounds_check(c, target_res.reg, index_res.reg, struct_ty, node.pos);

        let data_field_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + data_field_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + target_res.reg + ", i32 0, i32 2\n");
        let data_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + data_ptr + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_field_ptr + "\n");
        
        let size_index -> String = emit_int_to_size(c, index_res.reg, true);
        let slot_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", " + get_size_llvm_type() + " " + size_index + "\n");

        if (result_owns_value(c, elem_type)) {
            if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, elem_type); }
            emit_drop_slot(c, slot_ptr, elem_type);
        }

        c.output_file.write(c.indent + "store " + elem_ty_str + " " + val_res.reg + ", " + elem_ty_str + "* " + slot_ptr + "\n");
        
        return val_res;
    }
    
    throw_type_error(node.pos, "Type " + get_type_name(c, target_res.type) + " does not support index assignment.");
    return void_result();
}

func compile_slice_access(c -> Compiler, node -> SliceAccessNode, shared -> Bool) -> CompileResult {
    if ((node.start_idx is null && node.end_idx is !null) ||
        (node.start_idx is !null && node.end_idx is null)) {
        throw_invalid_syntax(node.pos, "Slice bounds must either both be present or both be omitted.");
        return void_result();
    }

    let old_exp -> Int = c.expected_type;
    c.expected_type = 0;
    let target_res -> CompileResult = compile_node(c, node.target);
    c.expected_type = old_exp;
    if (target_res is !null && target_res.type == TYPE_POISON) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let omitted -> Bool = node.start_idx is null && node.end_idx is null;
    if (target_res.type == TYPE_STRING) {
        let len_slot -> String = next_reg(c);
        c.output_file.write(c.indent + len_slot + " = getelementptr inbounds %struct.$String, %struct.$String* " + target_res.reg + ", i32 0, i32 1\n");
        let source_len -> String = next_reg(c);
        c.output_file.write(c.indent + source_len + " = load i32, i32* " + len_slot + "\n");

        if (shared) {
            if (!omitted) {
                throw_type_error(node.pos, "String views currently require a full slice expression.");
                return void_result();
            }
            return target_res;
        }

        let start -> String = "0";
        let end -> String = source_len;
        if (!omitted) {
            c.expected_type = TYPE_INT;
            let start_res -> CompileResult = compile_node(c, node.start_idx);
            let end_res -> CompileResult = compile_node(c, node.end_idx);
            c.expected_type = old_exp;
            start = start_res.reg;
            end = end_res.reg;
        }
        emit_slice_bounds_check(c, start, end, source_len, node.pos);
        let slice_hook -> String = get_mangled_symbol(c, "string_slice", node.pos);
        let result -> String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + slice_hook + "(%struct.$String* " + target_res.reg + ", i32 " + start + ", i32 " + end + ")\n");
        emit_release_owned(c, target_res);
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    let elem_type -> Int = 0;
    let source_data -> String = "";
    let current_len -> String = "";
    let source_kind -> Int = 0;
    let source_parts -> SliceParts = null;
    let vec_data_slot -> String = "";
    let vec_size_slot -> String = "";
    let vec_owner -> String = "";

    let arr_info -> ArrayInfo = c.array_info_map.get("" + target_res.type);
    let vec_info -> SymbolInfo = c.vector_base_map.get("" + target_res.type);
    if (arr_info is !null) {
        elem_type = arr_info.base_type;
        let elem_ty -> String = get_llvm_type_str(c, elem_type);
        if (arr_info.size == -1) {
            source_kind = 2;
            source_parts = emit_slice_parts(c, target_res.reg, target_res.type, node.pos);
            current_len = emit_size_to_int(c, source_parts.length);
            source_data = next_reg(c);
            c.output_file.write(c.indent + source_data + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + source_parts.data + ", " + get_size_llvm_type() + " " + source_parts.start + "\n");
        } else {
            source_kind = 1;
            current_len = "" + arr_info.size;
            source_data = next_reg(c);
            c.output_file.write(c.indent + source_data + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + target_res.reg + ", i32 0, i32 0\n");
        }
    } else if (vec_info is !null) {
        source_kind = 3;
        elem_type = vec_info.type;
        let elem_ty -> String = get_llvm_type_str(c, elem_type);
        let vec_ty -> String = get_vector_llvm_type(c, elem_type);
        let size_ty -> String = get_size_llvm_type();
        vec_size_slot = next_reg(c);
        c.output_file.write(c.indent + vec_size_slot + " = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* " + target_res.reg + ", i32 0, i32 0\n");
        let vector_length -> String = next_reg(c);
        c.output_file.write(c.indent + vector_length + " = load " + size_ty + ", " + size_ty + "* " + vec_size_slot + "\n");
        current_len = emit_size_to_int(c, vector_length);
        vec_data_slot = next_reg(c);
        c.output_file.write(c.indent + vec_data_slot + " = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* " + target_res.reg + ", i32 0, i32 2\n");
        source_data = next_reg(c);
        c.output_file.write(c.indent + source_data + " = load " + elem_ty + "*, " + elem_ty + "** " + vec_data_slot + "\n");
        vec_owner = next_reg(c);
        c.output_file.write(c.indent + vec_owner + " = bitcast " + vec_ty + "* " + target_res.reg + " to i8*\n");
    } else {
        throw_type_error(node.pos, "Cannot slice type '" + get_type_name(c, target_res.type) + "'. Only Array, Vector, and String can be sliced.");
        return void_result();
    }

    let start -> String = "0";
    let end -> String = current_len;
    if (!omitted) {
        c.expected_type = TYPE_INT;
        let start_res -> CompileResult = compile_node(c, node.start_idx);
        let end_res -> CompileResult = compile_node(c, node.end_idx);
        c.expected_type = old_exp;
        start = start_res.reg;
        end = end_res.reg;
    }
    emit_slice_bounds_check(c, start, end, current_len, node.pos);

    let length -> String = next_reg(c);
    c.output_file.write(c.indent + length + " = sub i32 " + end + ", " + start + "\n");
    if (!shared) {
        return emit_slice_copy(c, elem_type, source_data, start, length, node.pos);
    }

    if (source_kind == 1) {
        throw_type_error(node.pos, "Shared views over fixed stack storage cannot escape their scope yet. Convert the data to a 'Vector' or 'Array(T)' first.");
        return void_result();
    }

    let size_start -> String = emit_int_to_size(c, start, false);
    let size_length -> String = emit_int_to_size(c, length, false);
    if (source_kind == 2) {
        let absolute_start -> String = next_reg(c);
        c.output_file.write(c.indent + absolute_start + " = add " + get_size_llvm_type() + " " + source_parts.start + ", " + size_start + "\n");
        return emit_make_slice(c, elem_type, source_parts.owner, source_parts.data_slot, source_parts.size_slot, absolute_start, size_length);
    }
    return emit_make_slice(c, elem_type, vec_owner, vec_data_slot, vec_size_slot, size_start, size_length);
}

func compile_map_lit(c -> Compiler, lit_node -> Struct) -> CompileResult {
    let node -> MapLitNode = lit_node;
    let pairs -> Vector(Struct) = node.pairs;
    let pair_count -> Int = 0;
    if (pairs is !null) { pair_count = pairs.length(); }

    let cap -> Int = pair_count * 2;
    if (cap < 8) { cap = 8; }

    let dict_info -> StructInfo = c.struct_id_map.get("" + c.expected_type);
    if (!is_typed_dict(c, dict_info)) {
        dict_info = c.struct_table.get("Dict");
        if (dict_info is null) { dict_info = c.struct_table.get("dict.Dict"); }
    }
    if (dict_info is null) { throw_type_error(node.pos, "Compiler error: 'Dict' class not found in prelude."); }

    let init_args -> Vector(Struct) = [];
    if (!is_typed_dict(c, dict_info)) {
        let cap_tok -> Token = Token(type=TOK_INT, value="" + cap, line=node.pos.ln, col=node.pos.col);
        let cap_node -> IntNode = IntNode(type=NODE_INT, tok=cap_tok, pos=node.pos);
        init_args.append(ArgNode(val=cap_node, name=null));
    }
    let fake_init_call -> CallNode = CallNode(type=NODE_CALL, callee=null, args=init_args, type_args=null, pos=node.pos, preserve_fallible=false);

    let dict_res -> CompileResult = compile_class_init(c, dict_info, fake_init_call);

    // dict.put(k, v)
    let i -> Int = 0;
    while (i < pair_count) {
        let pair -> MapPairNode = pairs[i];
        let put_args -> Vector(Struct) = [];
        put_args.append(ArgNode(val=pair.key, name=null));
        put_args.append(ArgNode(val=pair.value, name=null));
        let fake_put_call -> CallNode = CallNode(type=NODE_CALL, callee=null, args=put_args, type_args=null, pos=node.pos, preserve_fallible=false);
        
        compile_class_method_call(c, dict_info, dict_res, "put", fake_put_call);
        i += 1;
    }

    return CompileResult(reg=dict_res.reg, type=dict_info.type_id, origin_type=0);
}

func compile_enum_def(c -> Compiler, node -> EnumDefNode) -> CompileResult {
    let raw_name -> String = node.name_tok.value;
    let enum_name -> String = c.current_package_prefix + raw_name;
    
    let type_info -> StructInfo = c.struct_table.get(enum_name);
    let type_id -> Int = type_info.type_id;
    let llvm_ty_str -> String = "i32";

    let fields -> Vector(Struct) = node.fields;
    let len -> Int = 0; if (fields is !null) { len = fields.length(); }
    let i -> Int = 0;
    
    let current_val -> Long = 0L;
    let member_names -> Dict = Dict(8);

    while (i < len) {
        let f_node -> EnumFieldNode = fields[i];
        
        if (f_node.value is !null) {
            current_val = eval_const_long(c, f_node.value, f_node.pos);
        }
        
        let field_name -> String = f_node.name_tok.value;
        if (member_names.contains_key(field_name)) {
            throw_name_error(f_node.pos, "Member '" + field_name + "' is already defined in " + enum_name);
            return void_result();
        }
        member_names.put(field_name, StringConstant(id=0, value=field_name));
        if (current_val < -2147483648L || current_val > 2147483647L) {
            throw_overflow_error(f_node.pos, "Value for '" + field_name + "' is outside the Int range");
            return void_result();
        }
        let global_name -> String = "@" + enum_name + "." + field_name;
        
        c.output_file.write(global_name + " = global " + llvm_ty_str + " " + current_val + "\n");
        c.global_symbol_table.put(enum_name + "." + field_name, SymbolInfo(reg=global_name, type=type_id, origin_type=type_id, is_const=true));

        let offset_int -> Int = string_to_int("" + current_val, f_node.pos);
        type_info.fields.append(FieldInfo(name=field_name, type=type_id, llvm_type="i32", offset=offset_int));
        
        current_val += 1L;
        i += 1;
    }
    
    return void_result();
}

func compile_try_unwrap(c -> Compiler, node -> TryUnwrapNode) -> CompileResult {
    let expr_base -> BaseNode = node.expr;
    let expr_res -> CompileResult = null;
    if (expr_base.type == NODE_INDEX_ACCESS) {
        let access -> IndexAccessNode = node.expr;
        expr_res = compile_index_access(c, access, true);
    } else {
        expr_res = compile_node(c, node.expr);
    }

    let fallible_type -> Int = expr_res.type;
    if (!is_fallible_type(c, fallible_type)) {
        if (expr_base.type == NODE_CALL) {
            let call -> CallNode = node.expr;
            let callee_base -> BaseNode = call.callee;
            if (callee_base.type == NODE_VAR_ACCESS) {
                let callee -> VarAccessNode = call.callee;
                let target_type -> Int = get_builtin_cast_target(callee.name_tok.value);
                if (target_type != 0) {
                    throw_invalid_syntax(node.pos, "Conversion to " + get_type_name(c, target_type) + " cannot fail; remove '?'");
                    return void_result();
                }
            }
        }
        throw_invalid_syntax(node.pos, "Cannot use '?' on a non-fallible type.");
        return void_result();
    }
    
    let inner_type -> Int = get_inner_fallible_type(c, fallible_type);
    let fallible_llvm_ty -> String = get_llvm_type_str(c, fallible_type);
    
    let is_err_reg -> String = next_reg(c);
    c.output_file.write(c.indent + is_err_reg + " = extractvalue " + fallible_llvm_ty + " " + expr_res.reg + ", 0\n");
    
    let success_label -> String = next_label(c);
    let fail_label -> String = next_label(c);
    
    c.output_file.write(c.indent + "br i1 " + is_err_reg + ", label %" + fail_label + ", label %" + success_label + "\n\n");
    c.output_file.write(fail_label + ":\n");
    
    let err_val_reg -> String = next_reg(c);
    c.output_file.write(c.indent + err_val_reg + " = extractvalue " + fallible_llvm_ty + " " + expr_res.reg + ", 1\n");
    
    if (c.current_catch_label is !null && c.current_catch_label != "") {
        c.output_file.write(c.indent + "store { i64, i32 } " + err_val_reg + ", { i64, i32 }* " + c.current_catch_err_ptr + "\n");
        c.output_file.write(c.indent + "br label %" + c.current_catch_label + "\n\n");
    } else {
        if (!is_fallible_type(c, c.current_ret_type)) {
            throw_invalid_syntax(node.pos, "Cannot use '?' without catch in a function that does not return a fallible type.");
        }
        let cur_ret_llvm_ty -> String = get_llvm_type_str(c, c.current_ret_type);
        let ret_val_1 -> String = next_reg(c);
        c.output_file.write(c.indent + ret_val_1 + " = insertvalue " + cur_ret_llvm_ty + " undef, i1 true, 0\n");
        let ret_val_2 -> String = next_reg(c);
        c.output_file.write(c.indent + ret_val_2 + " = insertvalue " + cur_ret_llvm_ty + " " + ret_val_1 + ", { i64, i32 } " + err_val_reg + ", 1\n");
        
        cleanup_all_scopes(c);
        
        c.output_file.write(c.indent + "ret " + cur_ret_llvm_ty + " " + ret_val_2 + "\n\n");
    }
    
    c.output_file.write(success_label + ":\n");
    
    if (inner_type != TYPE_VOID) {
        let inner_val_reg -> String = next_reg(c);
        c.output_file.write(c.indent + inner_val_reg + " = extractvalue " + fallible_llvm_ty + " " + expr_res.reg + ", 2\n");
        let inner_owned -> Bool = expr_res.owns_ref && needs_drop(c, inner_type);
        return CompileResult(reg=inner_val_reg, type=inner_type, origin_type=0, owns_ref=inner_owned);
    } else {
        return void_result();
    }
}

func compile_catch(c -> Compiler, node -> CatchNode) -> CompileResult {
    let fail_label -> String = next_label(c);
    let success_label -> String = next_label(c);
    
    let err_reg_ptr -> String = c.alloc_regs[node.alloc_id];
    
    let old_catch_label -> String = c.current_catch_label;
    let old_err_ptr -> String = c.current_catch_err_ptr;
    let old_catch_scope -> Struct = c.current_catch_scope;
    
    c.current_catch_label = fail_label;
    c.current_catch_err_ptr = err_reg_ptr;
    c.current_catch_scope = c.symbol_table;
    
    let res -> CompileResult = compile_node(c, node.stmt);
    discard_statement_result(c, node.stmt, res);
    
    c.current_catch_label = old_catch_label;
    c.current_catch_err_ptr = old_err_ptr;
    c.current_catch_scope = old_catch_scope;
    
    c.output_file.write(c.indent + "br label %" + success_label + "\n\n");
    c.output_file.write(fail_label + ":\n");
    
    enter_scope(c);
    c.symbol_table.table.put(node.err_name.value, SymbolInfo(reg=err_reg_ptr, type=TYPE_ANY_ERROR, origin_type=TYPE_ANY_ERROR, is_const=false, func_arg_types=null));
    
    compile_node(c, node.body);
    
    exit_scope(c);
    
    c.output_file.write(c.indent + "br label %" + success_label + "\n\n");
    c.output_file.write(success_label + ":\n");
    
    return res;
}

func compile_throw(c -> Compiler, node -> ThrowNode) -> CompileResult {
    let res -> CompileResult = compile_node(c, node.value);
    if (res is null || res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

    let error_type -> Int = res.type;
    if (!is_error_type(c, error_type) && is_error_type(c, res.origin_type)) {
        error_type = res.origin_type;
    }
    if (!is_error_type(c, error_type)) {
        throw_type_error(node.pos, "Cannot throw " + get_type_name(c, res.type) + ", expected an error value");
        return void_result();
    }

    let error_value -> CompileResult = emit_error_value(c, res, node.pos);
    let err_val_reg -> String = error_value.reg;
    
    if (c.current_catch_label is !null && c.current_catch_label != "") {
        cleanup_scopes_until(c, c.current_catch_scope);
        c.output_file.write(c.indent + "store { i64, i32 } " + err_val_reg + ", { i64, i32 }* " + c.current_catch_err_ptr + "\n");
        c.output_file.write(c.indent + "br label %" + c.current_catch_label + "\n\n");
    } else {
        if (!is_fallible_type(c, c.current_ret_type)) {
            throw_invalid_syntax(node.pos, "Cannot use 'throw' without a catch block in a function that does not return a fallible type.");
            return void_result();
        }
        
        let target_ty -> String = get_llvm_type_str(c, c.current_ret_type);
        let ret_val_1 -> String = next_reg(c);
        c.output_file.write(c.indent + ret_val_1 + " = insertvalue " + target_ty + " undef, i1 true, 0\n");
        let ret_val_2 -> String = next_reg(c);
        c.output_file.write(c.indent + ret_val_2 + " = insertvalue " + target_ty + " " + ret_val_1 + ", { i64, i32 } " + err_val_reg + ", 1\n");
        
        cleanup_all_scopes(c);
        c.output_file.write(c.indent + "ret " + target_ty + " " + ret_val_2 + "\n\n");
    }
    
    return void_result();
}

func compile_lvalue_ptr(c -> Compiler, node -> Struct, pos -> Position) -> CompileResult {
    if (node is null) { return null; }
    let base -> BaseNode = node;

    if (base.type == NODE_VAR_ACCESS) {
        let v -> VarAccessNode = node;
        let name -> String = v.name_tok.value;

        let info -> SymbolInfo = find_symbol(c, name);
        if (info is !null) {
            if (info.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
            return CompileResult(reg=info.reg, type=info.type, origin_type=info.origin_type);
        }

        let f_info -> FuncInfo = c.func_table.get(name);
        if (f_info is null && c.current_package_prefix != "") {
            f_info = c.func_table.get(c.current_package_prefix + name);
        }
        if (f_info is !null) {
            let specific_type_id -> Int = get_func_type_id(c, f_info.arg_types, f_info.ret_type);
            let sig -> String = get_func_sig_str(c, f_info);
            let func_ptr -> String = "@" + f_info.name;
            let cast_reg -> String = next_reg(c);
            c.output_file.write(c.indent + cast_reg + " = bitcast " + sig + " " + func_ptr + " to i8*\n");

            let clo_payload -> String = emit_alloc_closure(c, specific_type_id);
            let clo_func_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + clo_func_ptr + " = bitcast i8* " + clo_payload + " to i8**\n");
            c.output_file.write(c.indent + "store i8* " + cast_reg + ", i8** " + clo_func_ptr + "\n");
            let clo_env_ptr_i8 -> String = next_reg(c);
            c.output_file.write(c.indent + clo_env_ptr_i8 + " = getelementptr inbounds i8, i8* " + clo_payload + ", i32 " + closure_env_offset() + "\n");
            let clo_env_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + clo_env_ptr + " = bitcast i8* " + clo_env_ptr_i8 + " to i8**\n");
            c.output_file.write(c.indent + "store i8* null, i8** " + clo_env_ptr + "\n");
            return CompileResult(reg=clo_payload, type=specific_type_id);
        }
        
        throw_name_error(v.pos, "Unknown variable or function '" + name + "'.");
        let curr_scope -> Scope = c.symbol_table;
        curr_scope.table.put(name, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    if (base.type == NODE_INDEX_ACCESS) {
        let ia -> IndexAccessNode = node;
        check_out_index(c, ia.target, ia.index_node, ia.pos);
        let target_res -> CompileResult = compile_node(c, ia.target);
        
        let s_info -> StructInfo = c.struct_id_map.get("" + target_res.type);
        if (s_info is !null && s_info.is_class) {
            throw_invalid_syntax(ia.pos, "Cannot take ref of overloaded class index access.");
            return null;
        }

        let index_res -> CompileResult = compile_node(c, ia.index_node);
        if (index_res.type != TYPE_INT) {
            throw_type_error(ia.pos, "Index must be an Integer.");
            return null;
        }

        if (is_pointer_type(c, target_res.type)) {
            let base_info -> SymbolInfo = c.ptr_base_map.get("" + target_res.type);
            if (base_info is !null) {
                let elem_type -> Int = base_info.type;
                if (elem_type == TYPE_VOID) {
                    throw_type_error(ia.pos, "Cannot index 'ptr Void'.");
                    return null;
                }
                emit_pointer_null_check(c, target_res.reg, target_res.type, ia.pos);
                let elem_ty_str -> String = get_llvm_type_str(c, elem_type);
                let addr_reg -> String = next_reg(c);
                c.output_file.write(c.indent + addr_reg + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + target_res.reg + ", i32 " + index_res.reg + "\n");
                return CompileResult(reg=addr_reg, type=elem_type, origin_type=elem_type);
            }
        }

        let arr_info -> ArrayInfo = c.array_info_map.get("" + target_res.type);
        if (arr_info is !null) {
            let elem_type -> Int = arr_info.base_type;
            let elem_ty_str -> String = get_llvm_type_str(c, elem_type);
            let curr_len -> String = "";
            let data_ptr -> String = "";
            if (arr_info.size == -1) {
                let parts -> SliceParts = emit_slice_parts(c, target_res.reg, target_res.type, ia.pos);
                curr_len = emit_size_to_int(c, parts.length);
                data_ptr = next_reg(c);
                c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + parts.data + ", " + get_size_llvm_type() + " " + parts.start + "\n");
            } else {
                curr_len = "" + arr_info.size;
                data_ptr = next_reg(c);
                c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + target_res.reg + ", i32 0, i32 0\n");
            }
            emit_array_bounds_check(c, index_res.reg, curr_len, ia.pos);
            let ptr_reg -> String = next_reg(c);
            c.output_file.write(c.indent + ptr_reg + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", i32 " + index_res.reg + "\n");
            return CompileResult(reg=ptr_reg, type=elem_type, origin_type=elem_type);
        }

        if (target_res.type >= 100 && c.vector_base_map.get("" + target_res.type) is !null) {
            let v_info -> SymbolInfo = c.vector_base_map.get("" + target_res.type);
            let elem_type -> Int = v_info.type;
            let elem_ty_str -> String = get_llvm_type_str(c, elem_type);
            let struct_ty -> String = get_vector_llvm_type(c, elem_type);
            emit_vector_bounds_check(c, target_res.reg, index_res.reg, struct_ty, ia.pos);
            
            let data_field_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + data_field_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + target_res.reg + ", i32 0, i32 2\n");
            let data_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_field_ptr + "\n");
            
            let size_index -> String = emit_int_to_size(c, index_res.reg, true);
            let slot_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", " + get_size_llvm_type() + " " + size_index + "\n");
            return CompileResult(reg=slot_ptr, type=elem_type, origin_type=elem_type);
        }
        
        throw_type_error(ia.pos, "Type does not support l-value indexing.");
        return null;
    }

    if (base.type == NODE_FIELD_ACCESS) {
        let f_acc -> FieldAccessNode = node;
        let obj_res -> CompileResult = compile_node(c, f_acc.obj);
        let struct_type_id -> Int = obj_res.type;
        let struct_ptr_reg -> String = obj_res.reg;

        if (is_pointer_type(c, struct_type_id)) {
            let base_info -> SymbolInfo = c.ptr_base_map.get("" + struct_type_id);
            if (base_info is !null) {
                emit_pointer_null_check(c, struct_ptr_reg, struct_type_id, f_acc.pos);
                struct_type_id = base_info.type;
            }
        }

        if ((struct_type_id == TYPE_GENERIC_STRUCT || struct_type_id == TYPE_GENERIC_CLASS) && obj_res.origin_type >= 100) {
            struct_type_id = obj_res.origin_type;
            let s_info_temp -> StructInfo = c.struct_id_map.get("" + struct_type_id);
            if (s_info_temp is !null) {
                let cast_reg -> String = next_reg(c);
                c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + struct_ptr_reg + " to " + s_info_temp.llvm_name + "*\n");
                struct_ptr_reg = cast_reg;
            }
        }

        let s_info -> StructInfo = c.struct_id_map.get("" + struct_type_id);
        if (s_info is null) {
            throw_type_error(f_acc.pos, "Cannot access field on non-struct type.");
            return null;
        }

        if (f_acc.field_name.starts_with("__")) {
            let class_prefix -> String = "";
            let dot_idx -> Int = s_info.name.length() - 1;
            while (dot_idx >= 0) {
                if (s_info.name[dot_idx] == '.') {
                    class_prefix = s_info.name.slice(0, dot_idx + 1);
                    break;
                }
                dot_idx -= 1;
            }
            if (c.current_package_prefix != class_prefix) {
                throw_name_error(f_acc.pos, "Member '" + f_acc.field_name + "' is private to '" + s_info.name + "'.");
                return null;
            }
        }

        let field -> FieldInfo = find_field(s_info, f_acc.field_name);
        if (field is null) {
            if (s_info.is_class) {
                let vtable_vec -> Vector(Struct) = s_info.vtable;
                let v_len -> Int = 0; if (vtable_vec is !null) { v_len = vtable_vec.length(); }
                let m_idx -> Int = 0;
                let m_info -> FuncInfo = null;
                while (m_idx < v_len) {
                    let m -> FuncInfo = vtable_vec[m_idx];
                    if (m.base_name == f_acc.field_name) {
                        m_info = m;
                        break;
                    }
                    m_idx += 1;
                }
                
                if (m_info is !null) {
                    let bound_args -> Vector(Struct) = [];
                    let ba_idx -> Int = 1;
                    while (ba_idx < m_info.arg_types.length()) {
                        bound_args.append(m_info.arg_types[ba_idx]);
                        ba_idx += 1;
                    }
                    let specific_type_id -> Int = get_method_type_id(c, bound_args, m_info.ret_type);
                    let sig -> String = get_func_sig_str(c, m_info);
                    
                    let vtable_ptr_addr -> String = next_reg(c);
                    c.output_file.write(c.indent + vtable_ptr_addr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + struct_ptr_reg + ", i32 0, i32 0\n");
                    let vtable_ptr -> String = next_reg(c);
                    c.output_file.write(c.indent + vtable_ptr + " = load " + class_vtable_type(c, s_info) + "*, " + class_vtable_type(c, s_info) + "** " + vtable_ptr_addr + "\n");
                    
                    let method_i8ptr_addr -> String = next_reg(c);
                    c.output_file.write(c.indent + method_i8ptr_addr + " = getelementptr inbounds " + class_vtable_type(c, s_info) + ", " + class_vtable_type(c, s_info) + "* " + vtable_ptr + ", i32 0, i32 " + m_idx + "\n");
                    let method_i8ptr -> String = next_reg(c);
                    c.output_file.write(c.indent + method_i8ptr + " = load i8*, i8** " + method_i8ptr_addr + "\n");
                    
                    let cast_reg -> String = next_reg(c);
                    c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + method_i8ptr + " to i8*\n");

                    let clo_payload -> String = emit_alloc_closure(c, specific_type_id);
                    let clo_func_ptr -> String = next_reg(c);
                    c.output_file.write(c.indent + clo_func_ptr + " = bitcast i8* " + clo_payload + " to i8**\n");
                    c.output_file.write(c.indent + "store i8* " + cast_reg + ", i8** " + clo_func_ptr + "\n");
                    
                    let clo_env_ptr_i8 -> String = next_reg(c);
                    c.output_file.write(c.indent + clo_env_ptr_i8 + " = getelementptr inbounds i8, i8* " + clo_payload + ", i32 " + closure_env_offset() + "\n");
                    let clo_env_ptr -> String = next_reg(c);
                    c.output_file.write(c.indent + clo_env_ptr + " = bitcast i8* " + clo_env_ptr_i8 + " to i8**\n");
                    
                    let env_cast -> String = next_reg(c);
                    c.output_file.write(c.indent + env_cast + " = bitcast " + s_info.llvm_name + "* " + struct_ptr_reg + " to i8*\n");
                    c.output_file.write(c.indent + "store i8* " + env_cast + ", i8** " + clo_env_ptr + "\n");
                    return CompileResult(reg=clo_payload, type=specific_type_id, origin_type=specific_type_id);
                }
            }
            throw_name_error(f_acc.pos, "Field '" + f_acc.field_name + "' not found.");
            return null;
        }

        let f_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + struct_ptr_reg + ", i32 0, i32 " + field.offset + "\n");
        return CompileResult(reg=f_ptr, type=field.type, origin_type=field.type);
    }

    if (base.type == NODE_DEREF) {
        let d_node -> DerefNode = node;
        let res -> CompileResult = compile_node(c, d_node.node);
        if (res is null || res.type == TYPE_POISON || res.reg == "") {
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        let i -> Int = 0;
        let curr_reg -> String = res.reg;
        let curr_type -> Int = res.type;

        while (i < d_node.level - 1) { 
            if (curr_type == TYPE_NULL) {
                throw_null_dereference_error(d_node.pos, "Cannot dereference 'nullptr'.");
                return null;
            }
            let base_info -> SymbolInfo = c.ptr_base_map.get("" + curr_type);
            if (base_info is null) { 
                throw_type_error(d_node.pos, "Attempt to dereference non-pointer."); 
                return null; 
            }
            let next_type -> Int = base_info.type;
            if (next_type == TYPE_VOID) {
                throw_type_error(d_node.pos, "Cannot dereference 'ptr Void'.");
                return null;
            }
            emit_pointer_null_check(c, curr_reg, curr_type, d_node.pos);
            let ty_str -> String = get_llvm_type_str(c, next_type);
            let next_reg -> String = next_reg(c);
            c.output_file.write(c.indent + next_reg + " = load " + ty_str + ", " + ty_str + "* " + curr_reg + "\n");
            
            curr_reg = next_reg;
            curr_type = next_type;
            i += 1;
        }
        
        let base_info -> SymbolInfo = c.ptr_base_map.get("" + curr_type);
        if (base_info is null) { 
            throw_type_error(d_node.pos, "Attempt to take ref of non-pointer deref.");
            return null;
        }
        return CompileResult(reg=curr_reg, type=base_info.type, origin_type=base_info.type);
    }

    throw_invalid_syntax(pos, "Cannot take ref of r-value.");
    return null;
}

func compile_type_layout(c -> Compiler, node -> TypeLayoutNode) -> CompileResult {
    let type_id -> Int = resolve_type(c, node.type_node);
    if (!check_layout_type(c, type_id, node.is_align, node.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }

    let llvm_type -> String = get_llvm_type_str(c, type_id);
    let size_ty -> String = get_size_llvm_type();
    let value -> String = "";
    if (node.is_align) {
        let pair_type -> String = "{ i8, " + llvm_type + " }";
        value = "ptrtoint (" + llvm_type + "* getelementptr (" + pair_type + ", " + pair_type + "* null, i32 0, i32 1) to " + size_ty + ")";
    } else {
        value = "ptrtoint (" + llvm_type + "* getelementptr (" + llvm_type + ", " + llvm_type + "* null, i32 1) to " + size_ty + ")";
    }
    return CompileResult(reg=value, type=TYPE_UINTSIZE);
}

func compile_binop(c -> Compiler, node -> BinOpNode) -> CompileResult {
    let left -> CompileResult = compile_node(c, node.left);
    if (left is !null && left.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let op_type -> Int = node.op_tok.type; 

    if (op_type == TOK_AND || op_type == TOK_OR) {
        if (left.type != TYPE_BOOL) {
            throw_type_error(node.pos, "Logic operators '&&' and '||' require Bool operands. ");
            return void_result();
        }
        let label_rhs -> String = "logic_rhs_" + c.type_counter;
        let label_merge -> String = "logic_merge_" + c.type_counter;
        let label_left -> String = "logic_left_" + c.type_counter;
        c.type_counter += 1;

        c.output_file.write(c.indent + "br label %" + label_left + "\n");
        c.output_file.write("\n" + label_left + ":\n");

        if (op_type == TOK_AND) {
            c.output_file.write(c.indent + "br i1 " + left.reg + ", label %" + label_rhs + ", label %" + label_merge + "\n");
        } else {
            c.output_file.write(c.indent + "br i1 " + left.reg + ", label %" + label_merge + ", label %" + label_rhs + "\n");
        }

        c.output_file.write("\n" + label_rhs + ":\n");
        let right_res -> CompileResult = compile_node(c, node.right);
        if (right_res.type != TYPE_BOOL) { throw_type_error(node.pos, "Right operand must be Bool."); }
        
        let label_rhs_end -> String = "logic_rhs_end_" + c.type_counter;
        c.type_counter += 1;
        c.output_file.write(c.indent + "br label %" + label_rhs_end + "\n");
        c.output_file.write("\n" + label_rhs_end + ":\n");
        c.output_file.write(c.indent + "br label %" + label_merge + "\n");

        c.output_file.write("\n" + label_merge + ":\n");
        let final_reg -> String = next_reg(c);
        c.output_file.write(c.indent + final_reg + " = phi i1 [ " + left.reg + ", %" + label_left + " ], [ " + right_res.reg + ", %" + label_rhs_end + " ]\n");
        
        return CompileResult(reg=final_reg, type=TYPE_BOOL);
    }

    let right -> CompileResult = compile_node(c, node.right);
    if (right is !null && right.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    if (op_type == TOK_EE || op_type == TOK_NE) {
        if (left.type == TYPE_NULL || left.type == TYPE_NULLPTR ||
            right.type == TYPE_NULL || right.type == TYPE_NULLPTR) {
            throw_type_error(node.pos, "Invalid operator. Do not use '==' or '!=' with null/nullptr. Use 'is' or 'is !'.");
            return void_result();
        }
    }

    if (left.type == TYPE_ANY_ERROR || right.type == TYPE_ANY_ERROR) {
        if (op_type != TOK_EE && op_type != TOK_NE) {
            throw_type_error(node.pos, "Operator '" + node.op_tok.value + "' is not defined for error values");
            return void_result();
        }
        if (!is_error_type(c, left.type) || !is_error_type(c, right.type)) {
            let other_type -> Int = right.type;
            if (left.type != TYPE_ANY_ERROR) { other_type = left.type; }
            throw_type_error(node.pos, "Cannot compare an error value with " + get_type_name(c, other_type));
            return void_result();
        }

        left = emit_error_value(c, left, node.pos);
        right = emit_error_value(c, right, node.pos);

        let left_domain -> String = next_reg(c);
        let right_domain -> String = next_reg(c);
        let left_code -> String = next_reg(c);
        let right_code -> String = next_reg(c);
        c.output_file.write(c.indent + left_domain + " = extractvalue { i64, i32 } " + left.reg + ", 0\n");
        c.output_file.write(c.indent + right_domain + " = extractvalue { i64, i32 } " + right.reg + ", 0\n");
        c.output_file.write(c.indent + left_code + " = extractvalue { i64, i32 } " + left.reg + ", 1\n");
        c.output_file.write(c.indent + right_code + " = extractvalue { i64, i32 } " + right.reg + ", 1\n");

        let domain_equal -> String = next_reg(c);
        let code_equal -> String = next_reg(c);
        let equal -> String = next_reg(c);
        c.output_file.write(c.indent + domain_equal + " = icmp eq i64 " + left_domain + ", " + right_domain + "\n");
        c.output_file.write(c.indent + code_equal + " = icmp eq i32 " + left_code + ", " + right_code + "\n");
        c.output_file.write(c.indent + equal + " = and i1 " + domain_equal + ", " + code_equal + "\n");
        if (op_type == TOK_EE) {
            return CompileResult(reg=equal, type=TYPE_BOOL);
        }

        let not_equal -> String = next_reg(c);
        c.output_file.write(c.indent + not_equal + " = xor i1 " + equal + ", true\n");
        return CompileResult(reg=not_equal, type=TYPE_BOOL);
    }

    // String
    if (left.type == TYPE_STRING || right.type == TYPE_STRING) {
        if (op_type == TOK_PLUS) {
            let left_stringable -> Bool = left.type == TYPE_STRING || left.type == TYPE_NULL || is_primitive_type(left.type);
            let right_stringable -> Bool = right.type == TYPE_STRING || right.type == TYPE_NULL || is_primitive_type(right.type);
            if (!left_stringable || !right_stringable) {
                let invalid_type -> Int = left.type; if (left_stringable) { invalid_type = right.type; }
                throw_type_error(node.pos, "Cannot concatenate String and " + get_type_name(c, invalid_type));
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            // convert type
            if (left.type != TYPE_STRING) {
                left = convert_to_string(c, left);
            }
            if (right.type != TYPE_STRING) {
                right = convert_to_string(c, right);
            }

            let concat_hook -> String = get_mangled_symbol(c, "string_concat", node.pos);
            let new_str_ptr -> String = next_reg(c);
            c.output_file.write(c.indent + new_str_ptr + " = call %struct.$String* @" + concat_hook + "(%struct.$String* " + left.reg + ", %struct.$String* " + right.reg + ")\n");
            emit_release_owned(c, left);
            emit_release_owned(c, right);
            return CompileResult(reg=new_str_ptr, type=TYPE_STRING, owns_ref=true);
        }

        if (left.type != right.type) {
            throw_type_error(node.pos, "Cannot operate on String with other types.");
            return void_result();
        }


        let allowed -> Bool = false;
        if (op_type == TOK_EE) { allowed = true; }
        if (op_type == TOK_NE) { allowed = true; }
        
        if (!allowed) {
            throw_type_error(node.pos, "Arithmetic operations on Strings are not supported (except +).");
            return void_result();
        }

        let compare_hook -> String = get_mangled_symbol(c, "string_compare", node.pos);
        let cmp_val -> String = next_reg(c);
        c.output_file.write(c.indent + cmp_val + " = call i32 @" + compare_hook + "(%struct.$String* " + left.reg + ", %struct.$String* " + right.reg + ")\n");
        emit_release_owned(c, left);
        emit_release_owned(c, right);

        let res_reg -> String = next_reg(c);
        let op_code -> String = "icmp eq";

        if (op_type == TOK_NE) { op_code = "icmp ne"; }

        c.output_file.write(c.indent + res_reg + " = " + op_code + " i32 " + cmp_val + ", 0\n");
        
        return CompileResult(reg=res_reg, type=TYPE_BOOL);
    }

    if (op_type == TOK_POW) {
        let left_numeric -> Bool = is_integer_type(left.type) || left.type == TYPE_FLOAT || left.type == TYPE_FLOAT32;
        let right_numeric -> Bool = is_integer_type(right.type) || right.type == TYPE_FLOAT || right.type == TYPE_FLOAT32;
        if (!left_numeric || !right_numeric) {
            throw_type_error(node.pos, "Operator '**' requires numeric operands");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        left = promote_to_float(c, left);
        right = promote_to_float(c, right);
        let res_reg -> String = next_reg(c);
        let pow_hook -> String = get_mangled_symbol(c, "float_pow", node.pos);
        c.output_file.write(c.indent + res_reg + " = call double @" + pow_hook + "(double " + left.reg + ", double " + right.reg + ")\n");
        return CompileResult(reg=res_reg, type=TYPE_FLOAT);
    }

    if ((left.type == TYPE_CHAR && right.type == TYPE_BYTE) ||
        (left.type == TYPE_BYTE && right.type == TYPE_CHAR)) {
        if (left.type == TYPE_BYTE) {
            let promoted -> String = next_reg(c);
            c.output_file.write(c.indent + promoted + " = zext i8 " + left.reg + " to i32\n");
            left = CompileResult(reg=promoted, type=TYPE_CHAR, origin_type=TYPE_BYTE);
        }
        if (right.type == TYPE_BYTE) {
            let promoted -> String = next_reg(c);
            c.output_file.write(c.indent + promoted + " = zext i8 " + right.reg + " to i32\n");
            right = CompileResult(reg=promoted, type=TYPE_CHAR, origin_type=TYPE_BYTE);
        }
    }

    if (left.type == TYPE_CHAR || right.type == TYPE_CHAR) {
        if (left.type != right.type) {
            throw_type_error(node.pos, "Cannot mix Char with other types in binary operations.");
            return void_result();
        }

        let is_char_cmp -> Bool = false;
        if (op_type == TOK_EE || op_type == TOK_NE || op_type == TOK_LT || op_type == TOK_GT || op_type == TOK_LTE || op_type == TOK_GTE) {
            is_char_cmp = true;
        }
        
        if (!is_char_cmp) {
            throw_type_error(node.pos, "Char type only supports comparison operators (==, !=, <, >, <=, >=).");
            return void_result();
        }

        let op_code -> String = "";
        if (op_type == TOK_EE) { op_code = "icmp eq"; }
        else if (op_type == TOK_NE) { op_code = "icmp ne"; }
        else if (op_type == TOK_GT) { op_code = "icmp ugt"; }
        else if (op_type == TOK_LT) { op_code = "icmp ult"; }
        else if (op_type == TOK_GTE) { op_code = "icmp uge"; }
        else if (op_type == TOK_LTE) { op_code = "icmp ule"; }

        let res_reg -> String = next_reg(c);
        c.output_file.write(c.indent + res_reg + " = " + op_code + " i32 " + left.reg + ", " + right.reg + "\n");
        return CompileResult(reg=res_reg, type=TYPE_BOOL);
    }

    let is_cmp -> Bool = false;
    if (op_type == TOK_EE) { is_cmp = true; }
    if (op_type == TOK_NE) { is_cmp = true; }
    if (op_type == TOK_GT) { is_cmp = true; }
    if (op_type == TOK_LT) { is_cmp = true; }
    if (op_type == TOK_GTE) { is_cmp = true; }
    if (op_type == TOK_LTE) { is_cmp = true; }

    if is_cmp {
        let is_enum_cmp -> Bool = false;
        if (left.type >= 100 && left.type == right.type) {
            let s_info -> StructInfo = c.struct_id_map.get("" + left.type);
            if (s_info is !null && s_info.is_enum) {
                is_enum_cmp = true;
            }
        } else if (left.type == TYPE_GENERIC_ENUM && right.type == TYPE_GENERIC_ENUM) {
            is_enum_cmp = true;
        } else if (left.type == TYPE_GENERIC_ENUM && right.type >= 100) {
            let s_info -> StructInfo = c.struct_id_map.get("" + right.type);
            if (s_info is !null && s_info.is_enum) { is_enum_cmp = true; }
        } else if (right.type == TYPE_GENERIC_ENUM && left.type >= 100) {
            let s_info -> StructInfo = c.struct_id_map.get("" + left.type);
            if (s_info is !null && s_info.is_enum) { is_enum_cmp = true; }
        }
        
        if is_enum_cmp {
            if (op_type != TOK_EE && op_type != TOK_NE) {
                throw_type_error(node.pos, "Enum type only supports == and !=.");
                return void_result();
            }
            let res_reg -> String = next_reg(c);
            let op_code -> String = "icmp eq";
            if (op_type == TOK_NE) { op_code = "icmp ne"; }
            c.output_file.write(c.indent + res_reg + " = " + op_code + " i32 " + left.reg + ", " + right.reg + "\n");
            return CompileResult(reg=res_reg, type=TYPE_BOOL);
        }
        
        if (left.type >= 100 || right.type >= 100 || left.type == TYPE_NULL || right.type == TYPE_NULL) {
            throw_type_error(node.pos, "Pointer comparison is not supported yet. Please use loop counters.");
            return void_result();
        }
        if (left.type == TYPE_BOOL || right.type == TYPE_BOOL) {
            if (left.type != right.type) { throw_type_error(node.pos, "Cannot mix Bool with other types."); return void_result(); }
            if (op_type != TOK_EE && op_type != TOK_NE) { throw_type_error(node.pos, "Invalid Bool operator."); return void_result(); }
            let res_reg -> String = next_reg(c);
            let op_code -> String = "icmp eq";
            if (op_type == TOK_NE) { op_code = "icmp ne"; }
            c.output_file.write(c.indent + res_reg + " = " + op_code + " i1 " + left.reg + ", " + right.reg + "\n");
            return CompileResult(reg=res_reg, type=TYPE_BOOL);
        }
    }

    if (left.type == TYPE_BOOL || right.type == TYPE_BOOL) {
        throw_type_error(node.pos, "Arithmetic operators cannot be used on Bool. ");
        return void_result();
    }


    if (is_integer_type(left.type) && is_integer_type(right.type) &&
        is_signed_integer(left.type) != is_signed_integer(right.type)) {
        let safe_widening -> Bool = false;
        if (is_signed_integer(left.type) && get_type_bitwidth(left.type) > get_type_bitwidth(right.type)) { safe_widening = true; }
        if (is_signed_integer(right.type) && get_type_bitwidth(right.type) > get_type_bitwidth(left.type)) { safe_widening = true; }
        if safe_widening {
        } else if (is_unsuffix_int_literal(node.left)) {
            left = compile_type_cast(c, left, right.type, node.pos);
        } else if (is_unsuffix_int_literal(node.right)) {
            right = compile_type_cast(c, right, left.type, node.pos);
        } else {
            throw_type_error(node.pos, "Cannot mix signed and unsigned integers without an explicit conversion");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
    }

    let target_type -> Int = left.type;
    if (left.type == TYPE_FLOAT || right.type == TYPE_FLOAT) {
        target_type = TYPE_FLOAT;
    } else if (left.type == TYPE_FLOAT32 || right.type == TYPE_FLOAT32) {
        target_type = TYPE_FLOAT32;
    } else if (is_integer_type(left.type) && is_integer_type(right.type)) {
        let l_bits -> Int = get_type_bitwidth(left.type);
        let r_bits -> Int = get_type_bitwidth(right.type);

        if (r_bits > l_bits) { target_type = right.type; }
        else if (l_bits > r_bits) { target_type = left.type; }
        else {
            if (is_unsigned_integer(right.type)) { target_type = right.type; }
            else { target_type = left.type; }
        }
    } else {
        throw_type_error(node.pos, "Invalid types for binary operator.");
        return void_result();
    }

    left = compile_type_cast(c, left, target_type, node.pos);
    right = compile_type_cast(c, right, target_type, node.pos);

    let type_str -> String = get_llvm_type_str(c, target_type);
    let res_reg -> String = next_reg(c);
    let op_code -> String = "";

    if is_cmp {
        if (target_type == TYPE_FLOAT || target_type == TYPE_FLOAT32) {
            if (op_type == TOK_EE) { op_code = "fcmp oeq"; }
            else if (op_type == TOK_NE) { op_code = "fcmp une"; }
            else if (op_type == TOK_GT) { op_code = "fcmp ogt"; }
            else if (op_type == TOK_LT) { op_code = "fcmp olt"; }
            else if (op_type == TOK_GTE) { op_code = "fcmp oge"; }
            else if (op_type == TOK_LTE) { op_code = "fcmp ole"; }
        } else {
            let suffix -> String = "s"; 
            if (is_unsigned_integer(target_type)) { suffix = "u"; }
            if (op_type == TOK_EE) { op_code = "icmp eq"; }
            else if (op_type == TOK_NE) { op_code = "icmp ne"; }
            else if (op_type == TOK_GT) { op_code = "icmp " + suffix + "gt"; }
            else if (op_type == TOK_LT) { op_code = "icmp " + suffix + "lt"; }
            else if (op_type == TOK_GTE) { op_code = "icmp " + suffix + "ge"; }
            else if (op_type == TOK_LTE) { op_code = "icmp " + suffix + "le"; }
        }
        c.output_file.write(c.indent + res_reg + " = " + op_code + " " + type_str + " " + left.reg + ", " + right.reg + "\n");
        return CompileResult(reg=res_reg, type=TYPE_BOOL);
    }

    if (target_type == TYPE_FLOAT || target_type == TYPE_FLOAT32) {
        if (op_type == TOK_PLUS)  { op_code = "fadd"; }
        else if (op_type == TOK_SUB)   { op_code = "fsub"; }
        else if (op_type == TOK_MUL)   { op_code = "fmul"; }
        else if (op_type == TOK_DIV)   { op_code = "fdiv"; }
        else if (op_type == TOK_MOD)   { op_code = ""; }
    } else {
        if (op_type == TOK_PLUS)  { op_code = "add"; }
        else if (op_type == TOK_SUB)   { op_code = "sub"; }
        else if (op_type == TOK_MUL)   { op_code = "mul"; }
        else if (op_type == TOK_DIV) { 
            if (is_unsigned_integer(target_type)) { op_code = "udiv"; } else { op_code = "sdiv"; }
        }
        else if (op_type == TOK_MOD) { 
            if (is_unsigned_integer(target_type)) { op_code = "urem"; } else { op_code = "srem"; }
        }
        else if (op_type == TOK_BIT_AND) { op_code = "and"; }
        else if (op_type == TOK_BIT_OR) { op_code = "or"; }
        else if (op_type == TOK_BIT_XOR) { op_code = "xor"; }
        else if (op_type == TOK_LSHIFT) { op_code = "shl"; }
        else if (op_type == TOK_RSHIFT) { 
            if (is_unsigned_integer(target_type)) { op_code = "lshr"; } else { op_code = "ashr"; }
        }
    }

    if (op_type == TOK_DIV || op_type == TOK_MOD) {
        if (right.reg == "0" || right.reg == "0.0") {
            throw_zero_division_error(node.pos, "Cannot divide by zero. ");
            return void_result();
        }
        let is_zero_reg -> String = next_reg(c);
        if (target_type == TYPE_FLOAT || target_type == TYPE_FLOAT32) {
            c.output_file.write(c.indent + is_zero_reg + " = fcmp oeq " + type_str + " " + right.reg + ", 0.0\n");
        } else {
            c.output_file.write(c.indent + is_zero_reg + " = icmp eq " + type_str + " " + right.reg + ", 0\n");
        }
        let err_label -> String = "div_zero_" + c.type_counter;
        let ok_label -> String = "div_ok_" + c.type_counter;
        c.type_counter += 1;
        c.output_file.write(c.indent + "br i1 " + is_zero_reg + ", label %" + err_label + ", label %" + ok_label + "\n");
        c.output_file.write("\n" + err_label + ":\n");
        emit_runtime_error(c, node.pos, "Division by zero");
        c.output_file.write("\n" + ok_label + ":\n");

        if (is_signed_integer(target_type)) {
            let min_literal -> String = get_signed_min_literal(target_type);
            if (min_literal.length() > 0) {
                let is_min -> String = next_reg(c);
                c.output_file.write(c.indent + is_min + " = icmp eq " + type_str + " " + left.reg + ", " + min_literal + "\n");
                let is_negative_one -> String = next_reg(c);
                c.output_file.write(c.indent + is_negative_one + " = icmp eq " + type_str + " " + right.reg + ", -1\n");
                let is_overflow -> String = next_reg(c);
                c.output_file.write(c.indent + is_overflow + " = and i1 " + is_min + ", " + is_negative_one + "\n");

                let overflow_label -> String = "div_overflow_" + c.type_counter;
                let arithmetic_label -> String = "div_arithmetic_" + c.type_counter;
                c.type_counter += 1;
                c.output_file.write(c.indent + "br i1 " + is_overflow + ", label %" + overflow_label + ", label %" + arithmetic_label + "\n");
                c.output_file.write("\n" + overflow_label + ":\n");
                emit_runtime_error(c, node.pos, "Signed division overflow");
                c.output_file.write("\n" + arithmetic_label + ":\n");
            }
        }
    }


    if (op_type == TOK_LSHIFT || op_type == TOK_RSHIFT) {
        let shift_bits -> Int = get_type_bitwidth(target_type);
        if (is_unsuffix_int_literal(node.right)) {
            let amount -> Long = eval_const_long(c, node.right, node.pos);
            if (amount < 0L || amount >= Long(shift_bits)) {
                throw_overflow_error(node.pos, "Shift count must be between 0 and " + (shift_bits - 1));
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
        } else {
            let too_large -> String = next_reg(c);
            let invalid -> String = too_large;
            c.output_file.write(c.indent + too_large + " = icmp uge " + type_str + " " + right.reg + ", " + shift_bits + "\n");
            if (is_signed_integer(target_type)) {
                let negative -> String = next_reg(c);
                let combined -> String = next_reg(c);
                c.output_file.write(c.indent + negative + " = icmp slt " + type_str + " " + right.reg + ", 0\n");
                c.output_file.write(c.indent + combined + " = or i1 " + negative + ", " + too_large + "\n");
                invalid = combined;
            }
            let error_label -> String = "shift_error_" + c.type_counter;
            let shift_label -> String = "shift_ok_" + c.type_counter;
            c.type_counter += 1;
            c.output_file.write(c.indent + "br i1 " + invalid + ", label %" + error_label + ", label %" + shift_label + "\n");
            c.output_file.write("\n" + error_label + ":\n");
            emit_runtime_error(c, node.pos, "Invalid shift count");
            c.output_file.write("\n" + shift_label + ":\n");
        }
    }

    if ((target_type == TYPE_INT128 || target_type == TYPE_UINT128) && (op_type == TOK_DIV || op_type == TOK_MOD)) {
        let hook_name -> String = "int128_div";
        if (target_type == TYPE_UINT128) { hook_name = "uint128_div"; }
        if (op_type == TOK_MOD) {
            hook_name = "int128_rem";
            if (target_type == TYPE_UINT128) { hook_name = "uint128_rem"; }
        }
        let arithmetic_hook -> String = get_mangled_symbol(c, hook_name, node.pos);
        c.output_file.write(c.indent + res_reg + " = call i128 @" + arithmetic_hook + "(i128 " + left.reg + ", i128 " + right.reg + ")\n");
        return CompileResult(reg=res_reg, type=target_type);
    }

    if ((target_type == TYPE_FLOAT || target_type == TYPE_FLOAT32) && op_type == TOK_MOD) {
        let left_reg -> String = left.reg;
        let right_reg -> String = right.reg;
        if (target_type == TYPE_FLOAT32) {
            let widened_left -> String = next_reg(c);
            let widened_right -> String = next_reg(c);
            c.output_file.write(c.indent + widened_left + " = fpext float " + left_reg + " to double\n");
            c.output_file.write(c.indent + widened_right + " = fpext float " + right_reg + " to double\n");
            left_reg = widened_left;
            right_reg = widened_right;
        }
        let mod_hook -> String = get_mangled_symbol(c, "float_mod", node.pos);
        let mod_result -> String = res_reg;
        if (target_type == TYPE_FLOAT32) { mod_result = next_reg(c); }
        c.output_file.write(c.indent + mod_result + " = call double @" + mod_hook + "(double " + left_reg + ", double " + right_reg + ")\n");
        if (target_type == TYPE_FLOAT32) { c.output_file.write(c.indent + res_reg + " = fptrunc double " + mod_result + " to float\n"); }
        return CompileResult(reg=res_reg, type=target_type);
    }

    c.output_file.write(c.indent + res_reg + " = " + op_code + " " + type_str + " " + left.reg + ", " + right.reg + "\n");
    return CompileResult(reg=res_reg, type=target_type);
}

func emit_function_value(c -> Compiler, info -> FuncInfo) -> CompileResult {
    if ((info.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let specific_type -> Int = get_func_type_id(c, info.arg_types, info.ret_type);
    let cast -> String = next_reg(c);
    c.output_file.write(c.indent + cast + " = bitcast " + get_func_sig_str(c, info) + " @" + info.name + " to i8*\n");

    let closure -> String = emit_alloc_closure(c, specific_type);
    let function_slot -> String = next_reg(c);
    c.output_file.write(c.indent + function_slot + " = bitcast i8* " + closure + " to i8**\n");
    c.output_file.write(c.indent + "store i8* " + cast + ", i8** " + function_slot + "\n");

    let environment_bytes -> String = next_reg(c);
    let environment_slot -> String = next_reg(c);
    c.output_file.write(c.indent + environment_bytes + " = getelementptr inbounds i8, i8* " + closure + ", i32 " + closure_env_offset() + "\n");
    c.output_file.write(c.indent + environment_slot + " = bitcast i8* " + environment_bytes + " to i8**\n");
    c.output_file.write(c.indent + "store i8* null, i8** " + environment_slot + "\n");

    return CompileResult(reg=closure, type=specific_type, origin_type=info.ret_type);
}

func emit_generic_method_value(c -> Compiler, generic -> GenericTypeNode) -> CompileResult {
    let field_base -> BaseNode = generic.base_type;
    if (field_base.type != NODE_FIELD_ACCESS) {
        throw_type_error(generic.pos, "A generic method instance must name a class method.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    let field -> FieldAccessNode = generic.base_type;
    let object -> CompileResult = compile_node(c, field.obj);
    if (object is null || object.type == TYPE_POISON) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let info -> StructInfo = c.struct_id_map.get("" + object.type);
    if (info is null || !info.is_class) {
        throw_type_error(generic.pos, "Generic methods can only be bound from class values.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let template -> GenericTemplate = c.generic_methods.get(info.name + "_" + field.field_name);
    if (template is null) {
        throw_name_error(generic.pos, "Generic method '" + field.field_name + "' is not defined in '" + info.name + "'.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let types -> Vector(Struct) = resolve_generic_method_args(c, template, generic.type_args, null, generic.pos);
    if (types is null) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let method_info -> FuncInfo = register_generic_method(c, template, info, types, generic.pos);
    if (method_info is null) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    if (object.is_const_access && method_info.mutates_self) {
        throw_type_error(generic.pos, "Cannot bind mutating method '" + field.field_name + "' through const value");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    emit_method_nullcheck(c, object.reg, info.llvm_name, field.field_name, generic.pos);
    let args -> Vector(Struct) = [];
    let i -> Int = 1;
    while (i < method_info.arg_types.length()) {
        args.append(method_info.arg_types[i]);
        i++;
    }

    let method_type -> Int = get_method_type_id(c, args, method_info.ret_type);
    let closure -> String = emit_alloc_closure(c, method_type);
    let cast -> String = next_reg(c);
    c.output_file.write(c.indent + cast + " = bitcast " + get_func_sig_str(c, method_info) + " @" + method_info.name + " to i8*\n");

    let function_slot -> String = next_reg(c);
    c.output_file.write(c.indent + function_slot + " = bitcast i8* " + closure + " to i8**\n");
    c.output_file.write(c.indent + "store i8* " + cast + ", i8** " + function_slot + "\n");

    let environment_bytes -> String = next_reg(c);
    let environment_slot -> String = next_reg(c);
    c.output_file.write(c.indent + environment_bytes + " = getelementptr inbounds i8, i8* " + closure + ", i32 " + closure_env_offset() + "\n");
    c.output_file.write(c.indent + environment_slot + " = bitcast i8* " + environment_bytes + " to i8**\n");

    let object_bytes -> String = next_reg(c);
    c.output_file.write(c.indent + object_bytes + " = bitcast " + info.llvm_name + "* " + object.reg + " to i8*\n");
    c.output_file.write(c.indent + "store i8* " + object_bytes + ", i8** " + environment_slot + "\n");

    emit_retain(c, object.reg, object.type);

    return CompileResult(reg=closure, type=method_type, origin_type=method_info.ret_type);
}

func compile_generic_value(c -> Compiler, node -> GenericTypeNode) -> CompileResult {
    let base -> BaseNode = node.base_type;
    if (base.type == NODE_FIELD_ACCESS) {
        return emit_generic_method_value(c, node);
    }

    let name -> String = generic_symbol_name(c, node.base_type, true);
    let template -> GenericTemplate = c.generic_funcs.get(name);
    if (template is null) {
        throw_name_error(node.pos, "Generic function '" + name + "' is not defined.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let types -> Vector(Struct) = resolve_generic_args(c, template, node.type_args, null, node.pos);
    if (types is null) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let instance -> FuncInfo = register_generic_func(c, template, types, node.pos);
    if (instance is null) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    return emit_function_value(c, instance);
}

func compile_node(c -> Compiler, node -> Struct) -> CompileResult {
    if (node is null) {
        return void_result();
    }

    let base -> BaseNode = node;
    if (base.type == NODE_GENERIC_TYPE) { return compile_generic_value(c, node); }
    if (base.type == NODE_TYPE_LAYOUT) { return compile_type_layout(c, node); }

    if (base.type == NODE_BLOCK) {
        return compile_block(c, node);
    }

    if (base.type == NODE_STRING) {
        let n -> StringNode = node;
        let val -> String = n.tok.value;
        let id -> Int = register_string_constant(c, val);
        let len -> Int = val.length() + 1;
        let res_reg -> String = next_reg(c);

        c.output_file.write(c.indent + res_reg + " = getelementptr inbounds { i32, i32, %struct.$String }, { i32, i32, %struct.$String }* @.str." + id + ", i32 0, i32 2\n");
        
        return CompileResult(reg=res_reg, type=TYPE_STRING, origin_type=0);
    }

    if (base.type == NODE_VAR_DECL) { return compile_var_decl(c, node); }
    if (base.type == NODE_IF)       { return compile_if(c, node); }
    if (base.type == NODE_WHILE)    { return compile_while(c, node); }
    if (base.type == NODE_FOR)      { return compile_for(c, node); }
    if (base.type == NODE_BINOP)    { return compile_binop(c, node); }
    if (base.type == NODE_RETURN)   { return compile_return(c, node); }
    if (base.type == NODE_STRUCT_DEF) { return compile_struct_def(c, node); }
    if (base.type == NODE_CLASS_DEF)  { return compile_class_def(c, node); }
    if (base.type == NODE_FIELD_ACCESS) { return compile_field_access(c, node); }
    if (base.type == NODE_FIELD_ASSIGN) { return compile_field_assign(c, node); }
    if (base.type == NODE_EXTERN_BLOCK) { return compile_extern_block(c, node); }
    if (base.type == NODE_VECTOR_LIT) { return compile_vector_lit(c, node); }
    if (base.type == NODE_INDEX_ACCESS) { return compile_index_access(c, node, false); }
    if (base.type == NODE_INDEX_ASSIGN) { return compile_index_assign(c, node); }
    if (base.type == NODE_SLICE_ACCESS) { return compile_slice_access(c, node, false); }
    if (base.type == NODE_MAP_LIT) { return compile_map_lit(c, node); }
    if (base.type == NODE_ENUM_DEF) { return compile_enum_def(c, node); }
    if (base.type == NODE_TRY_UNWRAP) { return compile_try_unwrap(c, node); }
    if (base.type == NODE_CATCH) { return compile_catch(c, node); }
    if (base.type == NODE_THROW) { return compile_throw(c, node); }

    // function and closure
    if (base.type == NODE_FUNC_DEF) {
            let func_def -> FunctionDefNode = node;
            if (c.scope_depth == 0) {
                compile_func_def(c, func_def);
                return null;
            } else {
                let clo_res -> CompileResult = compile_local_closure(c, func_def);
                let f_name -> String = func_def.name_tok.value;

                if (f_name != "") {
                    let llvm_ty_str -> String = get_llvm_type_str(c, clo_res.type);
                    let ptr_reg -> String = next_reg(c);
                    
                    c.output_file.write(c.indent + ptr_reg + " = alloca " + llvm_ty_str + "\n");
                    c.output_file.write(c.indent + "store " + llvm_ty_str + " " + clo_res.reg + ", " + llvm_ty_str + "* " + ptr_reg + "\n");
                    
                    let curr_scope -> Scope = c.symbol_table;
                    curr_scope.table.put(f_name, SymbolInfo(reg=ptr_reg, type=clo_res.type, origin_type=clo_res.origin_type, is_const=true));
                    curr_scope.gc_vars.append(GCTracker(reg=ptr_reg, type=clo_res.type));
                }

                return clo_res;
            }
        }

    // ptr
    if (base.type == NODE_PTR_ASSIGN) {return compile_ptr_assign(c, node);}
    // ref
    if (base.type == NODE_REF) {
        let r_node -> RefNode = node;

        if (reject_const_write(c, r_node.node, r_node.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }

        let ref_base -> BaseNode = r_node.node;
        if (ref_base.type == NODE_SLICE_ACCESS) {
            let slice_node -> SliceAccessNode = r_node.node;
            return compile_slice_access(c, slice_node, true);
        }

        let lval -> CompileResult = compile_lvalue_ptr(c, r_node.node, r_node.pos);
        if (lval is null) { return void_result(); }

        let ptr_id -> Int = get_ptr_type_id(c, lval.type);
        return CompileResult(reg=lval.reg, type=ptr_id);
    }
    // deref
    if (base.type == NODE_DEREF) {
        let d_node -> DerefNode = node;
        let res -> CompileResult = compile_node(c, d_node.node);
        if (res is null || res.type == TYPE_POISON || res.reg == "") {
            return CompileResult(reg="poison", type=TYPE_POISON);
        }

        let i -> Int = 0;
        let curr_reg -> String = res.reg;
        let curr_type -> Int = res.type;
        
        while (i < d_node.level) {
            if (curr_type == TYPE_NULL) {
                throw_null_dereference_error(d_node.pos, "Cannot dereference 'nullptr'. ");
                return void_result();
            }
            let base_info -> SymbolInfo = c.ptr_base_map.get("" + curr_type);
            if (base_info is null) {
                throw_type_error(d_node.pos, "Attempt to dereference non-pointer. ");
                return void_result();
            }
            
            let next_type -> Int = base_info.type;
            if (next_type == TYPE_VOID) {
                throw_type_error(d_node.pos, "Cannot dereference 'ptr Void'. Cast it to a specific pointer type first.");
                return void_result();
            }
            emit_pointer_null_check(c, curr_reg, curr_type, d_node.pos);
            let ty_str -> String = get_llvm_type_str(c, next_type);
            let next_reg -> String = next_reg(c);
            
            c.output_file.write(c.indent + next_reg + " = load " + ty_str + ", " + ty_str + "* " + curr_reg + "\n");
            
            curr_reg = next_reg;
            curr_type = next_type;
            i += 1;
        }
        return CompileResult(reg=curr_reg, type=curr_type, is_const_access=res.is_const_access);
    }

    if (base.type == NODE_IMPORT) { 
        compile_import(c, node);
        return void_result();
    }
    
    if (base.type == NODE_NULLPTR) {
        return CompileResult(reg="null", type=TYPE_NULLPTR);
    }

    if (base.type == NODE_NULL) {
        return CompileResult(reg="null", type=TYPE_NULL);
    }

    if (base.type == NODE_IS || base.type == NODE_IS_NOT) {
        let b_node -> BinOpNode = node;
        let lhs_res -> CompileResult = compile_node(c, b_node.left);
        let rhs_res -> CompileResult = compile_node(c, b_node.right);

        let l_reg -> String = lhs_res.reg;
        let r_reg -> String = rhs_res.reg;

        if (lhs_res.type == TYPE_NULL && is_pointer_type(c, rhs_res.type)) {
            throw_type_error(b_node.pos, "Cannot use 'null' with explicit pointer types. Use 'nullptr'.");
            return void_result();
        }
        if (rhs_res.type == TYPE_NULL && is_pointer_type(c, lhs_res.type)) {
            throw_type_error(b_node.pos, "Cannot use 'null' with explicit pointer types. Use 'nullptr'.");
            return void_result();
        }
        if (lhs_res.type == TYPE_NULLPTR && !is_pointer_type(c, rhs_res.type) && rhs_res.type != TYPE_NULLPTR) {
            throw_type_error(b_node.pos, "Cannot use 'nullptr' with non-pointer types.");
            return void_result();
        }
        if (rhs_res.type == TYPE_NULLPTR && !is_pointer_type(c, lhs_res.type) && lhs_res.type != TYPE_NULLPTR) {
            throw_type_error(b_node.pos, "Cannot use 'nullptr' with non-pointer types.");
            return void_result();
        }
        if ((is_primitive_type(lhs_res.type) && lhs_res.type != TYPE_NULL && lhs_res.type != TYPE_NULLPTR) ||
            (is_primitive_type(rhs_res.type) && rhs_res.type != TYPE_NULL && rhs_res.type != TYPE_NULLPTR)) {
            throw_type_error(b_node.pos, "Operator 'is' requires reference or pointer operands");
            return void_result();
        }
        
        // convert to i8* for address comparison
        if (lhs_res.type != TYPE_NULL && lhs_res.type != TYPE_NULLPTR) {
            let lhs_info -> StructInfo = c.struct_id_map.get("" + lhs_res.type);
            if (lhs_info is !null && lhs_info.is_interface) {
                let object_l -> String = next_reg(c);
                c.output_file.write(c.indent + object_l + " = extractvalue { i8*, i8* } " + l_reg + ", 0\n");
                l_reg = object_l;
            } else {
                let cast_l -> String = next_reg(c);
                let ty_l -> String = get_llvm_type_str(c, lhs_res.type);
                c.output_file.write(c.indent + cast_l + " = bitcast " + ty_l + " " + l_reg + " to i8*\n");
                l_reg = cast_l;
            }
        }
        if (rhs_res.type != TYPE_NULL && rhs_res.type != TYPE_NULLPTR) {
            let rhs_info -> StructInfo = c.struct_id_map.get("" + rhs_res.type);
            if (rhs_info is !null && rhs_info.is_interface) {
                let object_r -> String = next_reg(c);
                c.output_file.write(c.indent + object_r + " = extractvalue { i8*, i8* } " + r_reg + ", 0\n");
                r_reg = object_r;
            } else {
                let cast_r -> String = next_reg(c);
                let ty_r -> String = get_llvm_type_str(c, rhs_res.type);
                c.output_file.write(c.indent + cast_r + " = bitcast " + ty_r + " " + r_reg + " to i8*\n");
                r_reg = cast_r;
            }
        }

        let cmp_reg -> String = next_reg(c);
        let cond -> String = "eq";
        if (base.type == NODE_IS_NOT) { cond = "ne"; }
        
        c.output_file.write(c.indent + cmp_reg + " = icmp " + cond + " i8* " + l_reg + ", " + r_reg + "\n");
        return CompileResult(reg=cmp_reg, type=TYPE_BOOL);
    }

    if (base.type == NODE_INT) {
        let n -> IntNode = node;
        let raw_val -> String = n.tok.value;
        let t_id -> Int = c.expected_type;
        
        let is_i128 -> Bool = false;
        let suffix_len -> Int = 0;
        
        if (raw_val.ends_with("ULL") || raw_val.ends_with("ull")) {
            is_i128 = true;
            suffix_len = 3;
            t_id = TYPE_UINT128;
        } else if (raw_val.ends_with("LL") || raw_val.ends_with("ll")) {
            is_i128 = true;
            suffix_len = 2;
            t_id = TYPE_INT128;
        } else if (raw_val.ends_with("UL") || raw_val.ends_with("ul")) {
            suffix_len = 2;
            if (t_id == 0 || !is_integer_type(t_id)) { t_id = TYPE_UINT64; }
        } else if (raw_val.ends_with("U") || raw_val.ends_with("u")) {
            suffix_len = 1;
            if (t_id == 0 || !is_integer_type(t_id)) { t_id = TYPE_UINT32; }
        } else if (raw_val.ends_with("L") || raw_val.ends_with("l")) {
            suffix_len = 1;
            if (t_id == 0 || !is_integer_type(t_id)) { t_id = TYPE_LONG; }
        }

        if (exceeds_64bit_range(raw_val)) {
            is_i128 = true;
        }

        if is_i128 {
            if (t_id == 0 || !is_integer_type(t_id)) {
                t_id = TYPE_INT128;
            }
            let parsed_wide -> UInt128 = parse_const_uint128(raw_val, n.pos);
            let bits -> Int = get_type_bitwidth(t_id);
            let max_value -> UInt128 = 340282366920938463463374607431768211455ULL;
            if (bits == 8) {
                if (is_unsigned_integer(t_id)) { max_value = UInt128(255); }
                else { max_value = UInt128(127); }
            } else if (bits == 16) {
                if (is_unsigned_integer(t_id)) { max_value = UInt128(65535); }
                else { max_value = UInt128(32767); }
            } else if (bits == 32) {
                if (is_unsigned_integer(t_id)) { max_value = UInt128(4294967295UL); }
                else { max_value = UInt128(2147483647); }
            } else if (bits == 64) {
                if (is_unsigned_integer(t_id)) { max_value = UInt128(18446744073709551615UL); }
                else { max_value = UInt128(9223372036854775807L); }
            } else if (!is_unsigned_integer(t_id)) {
                max_value = 170141183460469231731687303715884105727ULL;
            }
            if (parsed_wide > max_value) {
                throw_overflow_error(n.pos, "Literal '" + raw_val + "' overflows " + get_type_name(c, t_id) + " valid range.");
                return void_result();
            }
            let actual_val -> String = raw_val;
            if (suffix_len > 0) {
                actual_val = raw_val.slice(0, raw_val.length() - suffix_len);
            }
            let clean_val -> String = "";
            let i -> Int = 0;
            let act_len -> Int = actual_val.length();
            while (i < act_len) {
                if (actual_val[i] != '_') {
                    clean_val = clean_val + actual_val.slice(i, i + 1);
                }
                i += 1;
            }
            return CompileResult(reg=clean_val, type=t_id); 
        }

        let parsed_val -> Long = string_to_long(raw_val, n.pos);
        if (t_id == 0 || !is_integer_type(t_id)) {
            if (raw_val.ends_with("L") || raw_val.ends_with("l")) {
                t_id = TYPE_LONG;
            } else if (parsed_val < -2147483648L || parsed_val > 2147483647L) {
                t_id = TYPE_LONG;
            } else {
                t_id = TYPE_INT;
            }
        } else {
            let bits -> Int = get_type_bitwidth(t_id); // Byte or Int8
            let is_overflow -> Bool = false;

            if (bits == 8) {
                if (is_unsigned_integer(t_id)) {
                    if (parsed_val < 0L || parsed_val > 255L) { is_overflow = true; }
                } else {
                    if (parsed_val < -128L || parsed_val > 127L) { is_overflow = true; }
                }
            } else if (bits == 16) {
                if (is_unsigned_integer(t_id)) {
                    if (parsed_val < 0L || parsed_val > 65535L) { is_overflow = true; }
                } else {
                    if (parsed_val < -32768L || parsed_val > 32767L) { is_overflow = true; }
                }
            } else if (bits == 32) {
                if (is_unsigned_integer(t_id)) {
                    if (parsed_val < 0L || parsed_val > 4294967295L) { is_overflow = true; }
                } else {
                    if (parsed_val < -2147483648L || parsed_val > 2147483647L) { is_overflow = true; }
                }
            }

            if is_overflow {
                throw_overflow_error(n.pos, "Literal '" + raw_val + "' overflows " + get_type_name(c, t_id) + " valid range.");
                return void_result();
            }
        }

        return CompileResult(reg="" + parsed_val, type=t_id); 
    }
    if (base.type == NODE_CHAR) {
        let cn -> CharNode = node;
        let char_val -> Int = string_to_int(cn.tok.value, cn.pos);
        return CompileResult(reg="" + char_val, type=TYPE_CHAR);
    }
    if (base.type == NODE_FLOAT) {
        let n -> FloatNode = node;
        let val_str -> String = n.tok.value;
        let is_f32 -> Bool = false;
        
        if (val_str.ends_with("f") || val_str.ends_with("F")) {
            is_f32 = true;
            val_str = val_str.slice(0, val_str.length() - 1);
        }

        if (c.expected_type == TYPE_FLOAT32 || (c.expected_type == 0 && is_f32)) {
            let tmp_reg -> String = next_reg(c);
            c.output_file.write(c.indent + tmp_reg + " = fptrunc double " + val_str + " to float\n");
            return CompileResult(reg=tmp_reg, type=TYPE_FLOAT32);
        }
        return CompileResult(reg=val_str, type=TYPE_FLOAT); 
    }

    if (base.type == NODE_BOOL) {
        let b -> BooleanNode = node;
        let val_str -> String = "0";
        if (b.value == 1) { val_str = "1"; }
        return CompileResult(reg=val_str, type=TYPE_BOOL);
    }

    if (base.type == NODE_VAR_ACCESS) {
        let v -> VarAccessNode = node;
        let var_name -> String = v.name_tok.value; 
        
        let info -> SymbolInfo = find_symbol(c, var_name);
        if (info is null) {
            let f_info -> FuncInfo = c.func_table.get(var_name);
            if (f_info is null && c.current_package_prefix != "") {
                f_info = c.func_table.get(c.current_package_prefix + var_name);
                if (f_info is !null) { var_name = c.current_package_prefix + var_name; }
            }
            if (f_info is !null) {
                if ((f_info.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
                    throw_type_error(v.pos, "Compiler intrinsic '" + f_info.base_name + "' cannot be used as a function value.");
                    return CompileResult(reg="poison", type=TYPE_POISON);
                }
                let specific_type_id -> Int = get_func_type_id(c, f_info.arg_types, f_info.ret_type);
                let sig -> String = get_func_sig_str(c, f_info);
                let func_ptr -> String = "@" + f_info.name;
                
                let cast_reg -> String = next_reg(c);
                c.output_file.write(c.indent + cast_reg + " = bitcast " + sig + " " + func_ptr + " to i8*\n");
                let clo_payload -> String = emit_alloc_closure(c, specific_type_id);
                let clo_func_ptr_i8 -> String = clo_payload;
                let clo_func_ptr -> String = next_reg(c);
                c.output_file.write(c.indent + clo_func_ptr + " = bitcast i8* " + clo_func_ptr_i8 + " to i8**\n");
                c.output_file.write(c.indent + "store i8* " + cast_reg + ", i8** " + clo_func_ptr + "\n");
                let clo_env_ptr_i8 -> String = next_reg(c);
                c.output_file.write(c.indent + clo_env_ptr_i8 + " = getelementptr inbounds i8, i8* " + clo_payload + ", i32 " + closure_env_offset() + "\n");
                let clo_env_ptr -> String = next_reg(c);
                c.output_file.write(c.indent + clo_env_ptr + " = bitcast i8* " + clo_env_ptr_i8 + " to i8**\n");
                c.output_file.write(c.indent + "store i8* null, i8** " + clo_env_ptr + "\n");

                return CompileResult(reg=clo_payload, type=specific_type_id);
            }

            throw_name_error(v.pos, "Undefined variable or function '" + var_name + "'. ");
            let curr_scope -> Scope = c.symbol_table;
            curr_scope.table.put(var_name, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        
        if (info.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

        if (info.reg.starts_with("$intrinsic.")) { return emit_target_intrinsic(c, info); }

        let llvm_ty_str -> String = get_llvm_type_str(c, info.type);
        if (llvm_ty_str == "") {
            throw_type_error(v.pos, "Variable '" + var_name + "' has invalid internal type ID. ");
            return void_result();
        }

        let arr_check -> ArrayInfo = c.array_info_map.get("" + info.type);
        if (arr_check is !null) {
            if (arr_check.size != -1) {
                return CompileResult(reg=info.reg, type=info.type, origin_type=info.origin_type, is_const_access=info.is_const || info.is_const_access);
            }
        }
        
        let val_reg -> String = next_reg(c);
        c.output_file.write(c.indent + val_reg + " = load " + llvm_ty_str + ", " + llvm_ty_str + "* " + info.reg + "\n");
        return CompileResult(reg=val_reg, type=info.type, origin_type=info.origin_type, is_const_access=info.is_const || info.is_const_access);
    }

    if (base.type == NODE_VAR_ASSIGN) {
        return compile_var_assign(c, node);
    }

    if (base.type == NODE_CALL) {
        let n_call -> CallNode = node;
        let callee_node -> Struct = n_call.callee;
        let callee -> BaseNode = callee_node;
        if (callee.type == NODE_GENERIC_TYPE) {
            let generic_callee -> GenericTypeNode = callee_node;
            callee_node = generic_callee.base_type;
            callee = callee_node;
        }

        let func_name -> String = "";
        let is_direct -> Bool = false;
        let is_package_call -> Bool = false;

        if (callee.type == NODE_FIELD_ACCESS) {
            let f_acc -> FieldAccessNode = callee_node;

            let obj_base_pre -> BaseNode = f_acc.obj;
            if (obj_base_pre.type == NODE_SUPER) {
                let self_info -> SymbolInfo = find_symbol(c, "self");
                if (self_info is null) { throw_invalid_syntax(n_call.pos, "Cannot use 'super' outside of a method."); }

                let curr_class -> StructInfo = c.struct_id_map.get("" + self_info.type);
                if (curr_class is null || !curr_class.is_class || curr_class.parent_id == 0) {
                    throw_type_error(n_call.pos, "Cannot use 'super', class has no parent.");
                    return void_result();
                }

                let p_info -> StructInfo = c.struct_id_map.get("" + curr_class.parent_id);
                let target_m_name -> String = f_acc.field_name;
                if (target_m_name == "init") { target_m_name = "$init"; }
                if (target_m_name == "deinit") { target_m_name = "$deinit"; }

                let full_m_name -> String = c.current_package_prefix + p_info.name + "_" + target_m_name;
                let f_info -> FuncInfo = c.func_table.get(full_m_name);
                if (f_info is null) {
                    throw_name_error(n_call.pos, "Method '" + target_m_name + "' not found in parent class '" + p_info.name + "'.");
                    return void_result();
                }

                let self_ty_str -> String = get_llvm_type_str(c, self_info.type);
                let self_val_reg -> String = next_reg(c);
                c.output_file.write(c.indent + self_val_reg + " = load " + self_ty_str + ", " + self_ty_str + "* " + self_info.reg + "\n");
                let self_res -> CompileResult = CompileResult(reg=self_val_reg, type=self_info.type, origin_type=0);

                c.expected_type = curr_class.parent_id;
                let casted_self -> CompileResult = emit_implicit_cast(c, self_res, curr_class.parent_id, n_call.pos);
                c.expected_type = 0;

                let sig -> String = get_func_sig_str(c, f_info);
                let args_str -> String = get_llvm_type_str(c, curr_class.parent_id) + " " + casted_self.reg;

                let args -> Vector(Struct) = n_call.args;
                let a_len -> Int = 0; if (args is !null) { a_len = args.length(); }
                let arg_idx -> Int = 0;
                let owned_args -> Vector(Struct) = [];
                let expected_types -> Vector(Struct) = f_info.arg_types;
                
                let expected_arg_count -> Int = 0;
                if (expected_types is !null) { expected_arg_count = expected_types.length() - 1; }
                
                if (a_len != expected_arg_count) {
                    throw_type_error(n_call.pos, "'super.'" + target_m_name + " expects " + expected_arg_count + " arguments, got " + a_len + ".");
                    return void_result();
                }
                args = bind_call_args(args, f_info.arg_names, 1, n_call.pos);
                if (args is null && expected_arg_count > 0) { return CompileResult(reg="poison", type=TYPE_POISON); }

                while (arg_idx < a_len) {
                    let arg_node_curr -> ArgNode = args[arg_idx];
                    let expected_type_node -> TypeListNode = expected_types[arg_idx + 1];
                    let expected_type -> Int = expected_type_node.type;

                    c.expected_type = expected_type;
                    let arg_val -> CompileResult = compile_node(c, arg_node_curr.val);
                    c.expected_type = 0;
                    if (arg_val is !null && arg_val.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
                    arg_val = emit_implicit_cast(c, arg_val, expected_type, n_call.pos);

                    let ty_str -> String = get_llvm_type_str(c, arg_val.type);
                    args_str = args_str + ", " + ty_str + " " + arg_val.reg;
                    if (arg_val.owns_ref) { owned_args.append(arg_val); }

                    arg_idx += 1;
                }

                let llvm_ret_type -> String = get_llvm_type_str(c, f_info.ret_type);
                if (f_info.ret_type == TYPE_VOID) {
                    c.output_file.write(c.indent + "call " + llvm_ret_type + " @" + f_info.name + "(" + args_str + ")\n");
                    emit_release_owned_args(c, owned_args);
                    return CompileResult(reg="", type=TYPE_VOID, origin_type=0);
                } else {
                    let call_res -> String = next_reg(c);
                    c.output_file.write(c.indent + call_res + " = call " + llvm_ret_type + " @" + f_info.name + "(" + args_str + ")\n");
                    emit_release_owned_args(c, owned_args);
                    return CompileResult(reg=call_res, type=f_info.ret_type, origin_type=0, owns_ref=result_owns_value(c, f_info.ret_type));
                }
            }

            let is_module_path -> Bool = true;
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
                let inner_v -> VarAccessNode = curr_obj;
                let root_name -> String = inner_v.name_tok.value;
                if (find_symbol(c, root_name) is null) {
                    let module_prefix -> String = c.current_file_visible_prefixes.get(root_name);
                    if (module_prefix is !null) {
                        func_name = module_member_name(module_prefix, path_parts, f_acc.field_name);
                        is_package_call = true;
                    } else {
                        let source_name -> String = module_member_name(root_name + ".", path_parts, f_acc.field_name);
                        let mapped_func -> String = c.current_file_func_aliases.get(source_name);
                        if (mapped_func is !null) {
                            func_name = mapped_func;
                            is_package_call = true;
                        }
                    }
                }
            }

            let try_string_method -> Bool = false;
            let guessed_type -> Int = get_expr_type(c, f_acc.obj);
            if (!is_package_call) {
                if (f_acc.field_name == "length") {
                    if (guessed_type == TYPE_STRING || c.vector_base_map.get("" + guessed_type) is !null || c.array_info_map.get("" + guessed_type) is !null) {
                        return compile_length_method(c, f_acc.obj, n_call);
                    }
                }
                if (c.vector_base_map.get("" + guessed_type) is !null) {
                    if (f_acc.field_name == "append") {
                        return compile_vector_append(c, f_acc.obj, n_call);
                    }
                    if (f_acc.field_name == "drop") {
                        return compile_vector_drop(c, f_acc.obj, n_call);
                    }
                }
                if (guessed_type == TYPE_STRING) {
                    try_string_method = true;
                }
            }

            if try_string_method {
                let res -> CompileResult = compile_string_method_call(c, f_acc.obj, f_acc.field_name, n_call);
                if (res is !null) { return res; }
            }

            if (!is_package_call && !try_string_method) {
                let obj_res -> CompileResult = compile_node(c, f_acc.obj);
                if (obj_res is !null && obj_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
                let struct_type_id -> Int = obj_res.type;
                if (struct_type_id == TYPE_GENERIC_STRUCT && obj_res.origin_type >= 100) {
                    struct_type_id = obj_res.origin_type;
                }
                let s_info -> StructInfo = c.struct_id_map.get("" + struct_type_id);
                if (s_info is !null && (s_info.is_class || s_info.is_interface)) {
                    return compile_class_method_call(c, s_info, obj_res, f_acc.field_name, n_call);
                }
            }
        }

        if (callee.type == NODE_VAR_ACCESS) {
            let v_node -> VarAccessNode = callee_node;
            func_name = v_node.name_tok.value;
        }

        let generic_type_name -> String = generic_symbol_name(c, callee_node, false);
        let generic_type_template -> GenericTemplate = c.generic_structs.get(generic_type_name);
        if (use_generic_constructor(c, generic_type_name, generic_type_template, n_call.type_args, n_call.args, c.expected_type)) {
            let types -> Vector(Struct) = resolve_generic_constructor_args(c, generic_type_template, n_call.type_args, n_call.args, c.expected_type, n_call.pos);
            if (types is null) { return CompileResult(reg="poison", type=TYPE_POISON); }

            let template_base -> BaseNode = generic_type_template.node;
            let instance_type -> Int = 0;
            if (template_base.type == NODE_CLASS_DEF) {
                instance_type = register_generic_class(c, generic_type_template, types, n_call.pos);
            } else {
                instance_type = register_generic_struct(c, generic_type_template, types, n_call.pos);
            }

            let instance -> StructInfo = c.struct_id_map.get("" + instance_type);
            if (template_base.type == NODE_CLASS_DEF) {
                return compile_class_init(c, instance, n_call);
            }

            return compile_struct_init(c, instance, n_call);
        }

        if (callee.type == NODE_VAR_ACCESS || callee.type == NODE_FIELD_ACCESS) {
            let generic_name -> String = generic_symbol_name(c, callee_node, true);
            let template -> GenericTemplate = c.generic_funcs.get(generic_name);
            if (template is !null) {
                let types -> Vector(Struct) = resolve_generic_args(c, template, n_call.type_args, n_call.args, n_call.pos);
                if (types is null) { return CompileResult(reg="poison", type=TYPE_POISON); }

                let instance -> FuncInfo = register_generic_func(c, template, types, n_call.pos);
                if (instance is null) { return CompileResult(reg="poison", type=TYPE_POISON); }

                func_name = generic_instance_name(template.name, types, c);
            }
        }

        if (func_name != "") {
            let cast_target -> Int = get_builtin_cast_target(func_name);
            let is_cast -> Bool = cast_target != 0;

            if is_cast {
                let args -> Vector(Struct) = n_call.args;
                let a_len -> Int = 0; if (args is !null) { a_len = args.length(); }
                if (reject_named_args(args, n_call.pos, "a type conversion")) { return CompileResult(reg="poison", type=TYPE_POISON); }
                if (a_len != 1) {
                    throw_type_error(n_call.pos, "Type cast expects exactly 1 argument.");
                    return void_result();
                }
                let arg_curr -> ArgNode = args[0];
                if (!validate_explicit_literal_cast(arg_curr.val, cast_target, n_call.pos)) {
                    return void_result();
                }
                let old_exp -> Int = c.expected_type;
                c.expected_type = 0;
                let arg_base -> BaseNode = arg_curr.val;
                if (arg_base.type == NODE_INT && is_integer_type(cast_target) &&
                    cast_target != TYPE_CHAR) {
                    c.expected_type = cast_target;
                }
                let val_res -> CompileResult = compile_node(c, arg_curr.val);
                c.expected_type = old_exp;

                let source_info -> StructInfo = c.struct_id_map.get("" + val_res.type);
                let conversion -> FuncInfo = find_class_conversion(source_info, cast_target);
                if (conversion is !null) {
                    let no_args -> Vector(Struct) = [];
                    let conversion_call -> CallNode = CallNode(type=NODE_CALL, callee=null, args=no_args, type_args=null, pos=n_call.pos, preserve_fallible=true);
                    let converted -> CompileResult = compile_class_method_call(
                        c,
                        source_info,
                        val_res,
                        conversion_method_name(cast_target),
                        conversion_call
                    );
                    if (is_fallible_type(c, converted.type) && !n_call.preserve_fallible) {
                        return unwrap_conversion_or_panic(c, converted, val_res.type, cast_target, n_call.pos);
                    }
                    return converted;
                }

                if (is_numeric_literal_expression(arg_curr.val)) {
                    return compile_type_cast(c, val_res, cast_target, n_call.pos);
                }
                return compile_explicit_type_cast(c, val_res, cast_target, n_call.pos, n_call.preserve_fallible);
            }

            if (!is_package_call) {
                let found_local -> Bool = false;
                let local_name -> String = func_name;
                if (c.current_package_prefix != "") {
                    local_name = c.current_package_prefix + func_name;
                }
                
                if (c.struct_table.get(local_name) is !null || c.func_table.get(local_name) is !null) {
                    func_name = local_name;
                    found_local = true;
                }

                if (!found_local) {
                    let mapped_type -> String = c.current_file_type_aliases.get(func_name);
                    if (mapped_type is !null) {
                        func_name = mapped_type;
                    } else {
                        let mapped_func -> String = c.current_file_func_aliases.get(func_name);
                        if (mapped_func is !null) {
                            func_name = mapped_func;
                        }
                    }
                }
            }
            if is_package_call {
                let f_acc -> FieldAccessNode = n_call.callee;
                if (f_acc.field_name.starts_with("__")) {
                    throw_name_error(n_call.pos, "Function '" + func_name + "' is not defined.");
                    return void_result();
                }
                is_direct = true;
            } else {
                let s_check -> StructInfo = c.struct_table.get(func_name);
                if (s_check is !null) {
                    is_direct = true;
                } else {
                    let f_check -> FuncInfo = c.func_table.get(func_name);
                    let v_check -> SymbolInfo = find_symbol(c, func_name);
                    if (f_check is !null && v_check is null) {
                        is_direct = true;
                    }
                }
            }
        }

        if is_direct {
            let g_alias_type -> String = c.global_type_aliases.get(func_name);
            if (g_alias_type is !null) { func_name = g_alias_type; }

            let g_alias_func -> String = c.global_func_aliases.get(func_name);
            if (g_alias_func is !null) { func_name = g_alias_func; }

            let target_func_name -> String = func_name;
            let check_built -> FuncInfo = c.func_table.get(func_name);
            if (check_built is !null) { target_func_name = check_built.base_name; }

            let intr_print -> String = c.compiler_link.get("print");
            let is_print -> Bool = false;
            if (intr_print is !null) {
                if (func_name == intr_print) { is_print = true; }
            } else {
                if (target_func_name == "print") { is_print = true; }
            }
            if is_print {
                let args -> Vector(Struct) = n_call.args;
                let a_len -> Int = 0;
                if (args is !null) { a_len = args.length(); }
                if (reject_named_args(args, n_call.pos, "print")) { return CompileResult(reg="poison", type=TYPE_POISON); }

                let print_hook -> String = get_mangled_symbol(c, "print_bytes", null);
                if (print_hook is null) {
                    throw_type_error(n_call.pos, "Missing CompilerLink hook 'print_bytes'. Did you import 'builtin'?");
                    return void_result();
                }

                if (a_len == 0) {
                    let fmt_ptr -> String = next_reg(c);
                    c.output_file.write(c.indent + "call void @" + print_hook + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_newline, i32 0, i32 0), i32 1)\n");
                    return void_result();
                }
                
                let a_idx -> Int = 0;
                while (a_idx < a_len) {
                    let curr_arg -> ArgNode = args[a_idx];
                    let arg_res -> CompileResult = compile_node(c, curr_arg.val);
                    compile_print(c, arg_res.reg, arg_res.type, n_call.pos, arg_res.origin_type);
                    emit_release_owned(c, arg_res);
                    a_idx += 1;
                }

                c.output_file.write(c.indent + "call void @" + print_hook + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_newline, i32 0, i32 0), i32 1)\n");
                return void_result();
            }

            let s_info -> StructInfo = c.struct_table.get(func_name);
            if (s_info is !null) {
                if (s_info.is_class) {
                    return compile_class_init(c, s_info, n_call);
                } else {
                    return compile_struct_init(c, s_info, n_call);
                }
            }

            let func_info -> FuncInfo = c.func_table.get(func_name);

            if (func_info is null) {
                throw_name_error(n_call.pos, "Function '" + func_name + "' is not defined.");
                return void_result();
            }
            if (func_info.compiler_link_name == "dict_key_hash" || func_info.compiler_link_name == "dict_keys_equal") {
                return compile_dict_intrinsic(c, func_info, n_call);
            }
            if ((func_info.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
                throw_invalid_syntax(n_call.pos, "Compiler intrinsic '" + func_info.base_name + "' must be called as " + func_info.base_name + "(Type).");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }

            if (!validate_fallible_call(c, func_info.ret_type, n_call.preserve_fallible, func_info.base_name, n_call.pos)) {
                return CompileResult(reg="poison", type=TYPE_POISON);
            }

            let args_str -> String = "";
            let args -> Vector(Struct) = n_call.args;
            let a_len -> Int = 0;
            if (args is !null) { a_len = args.length(); }
            let arg_idx -> Int = 0;
            let owned_args -> Vector(Struct) = [];

            let arg_types -> Vector(Struct) = func_info.arg_types;
            let type_len -> Int = 0; 
            if (arg_types is !null) { type_len = arg_types.length(); }
            if (!func_info.is_varargs) {
                args = bind_call_args(args, func_info.arg_names, 0, n_call.pos);
                if (args is null && type_len > 0) { return CompileResult(reg="poison", type=TYPE_POISON); }
            } else if (reject_named_args(args, n_call.pos, "a variadic function")) {
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            
            let is_first -> Bool = true;
            
            while (arg_idx < a_len) {
                let arg_node_curr -> ArgNode = args[arg_idx];

                if (arg_idx >= type_len) { 
                    if (!func_info.is_varargs) {
                        throw_type_error(n_call.pos, "Too many arguments.");
                        return void_result();
                    }
                    let arg_val -> CompileResult = compile_node(c, arg_node_curr.val);
                    if (arg_val is !null && arg_val.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

                    if (arg_val.type >= 100) {
                        throw_type_error(n_call.pos, "Cannot pass complex types (Struct/Array/Vector) directly to C varargs functions.");
                        return void_result();
                    }

                    if (arg_val.type == TYPE_BYTE) {
                        arg_val = promote_to_int(c, arg_val);
                    }
                    if (arg_val.type == TYPE_BOOL) {
                        let zext_reg -> String = next_reg(c);
                        c.output_file.write(c.indent + zext_reg + " = zext i1 " + arg_val.reg + " to i32\n");
                        arg_val = CompileResult(reg=zext_reg, type=TYPE_INT);
                    }
                    if (!is_first) { args_str = args_str + ", "; }
                    let ty_str -> String = get_llvm_type_str(c, arg_val.type);
                    args_str += ty_str + " " + arg_val.reg;
                    if (arg_val.owns_ref) { owned_args.append(arg_val); }

                    is_first = false;
                    arg_idx += 1;
                    continue;
                }

                let type_node_curr -> TypeListNode = arg_types[arg_idx];
                let expected_type -> Int = type_node_curr.type;

                c.expected_type = expected_type;
                let arg_val -> CompileResult = compile_node(c, arg_node_curr.val);
                c.expected_type = 0;
                if (arg_val is !null && arg_val.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
                
                arg_val = emit_implicit_cast(c, arg_val, expected_type, n_call.pos);

                let ty_str -> String = get_llvm_type_str(c, arg_val.type);
                if (!is_first) { args_str = args_str + ", "; }
                args_str += ty_str + " " + arg_val.reg;
                is_first = false;
                if (arg_val.owns_ref) { owned_args.append(arg_val); }
                
                arg_idx += 1;
            }
            
            if (arg_idx < type_len) { throw_type_error(n_call.pos, "Too few arguments."); }

            let ret_type_str -> String = get_llvm_type_str(c, func_info.ret_type);
            let call_res_reg -> String = "";

            let abi_callconv -> String = func_callconv(func_info);
            let call_prefix -> String = abi_callconv + ret_type_str + " ";
            if (func_info.is_varargs) {
                let sig_args -> String = "";
                let p_idx -> Int = 0;
                let first_p -> Bool = true;
                while (p_idx < type_len) {
                    let p_curr -> TypeListNode = arg_types[p_idx];
                    if (!first_p) { sig_args = sig_args + ", "; }
                    sig_args = sig_args + get_llvm_type_str(c, p_curr.type);
                    first_p = false;
                    p_idx += 1;
                }
                if (!first_p) { sig_args = sig_args + ", ..."; }
                else { sig_args = "..."; }
                call_prefix = abi_callconv + ret_type_str + " (" + sig_args + ") ";
            }
            
            if (func_info.ret_type == TYPE_VOID) {
                if (func_info.is_varargs) {
                    c.output_file.write(c.indent + "call " + call_prefix + "@" + func_info.name + "(" + args_str + ")\n");
                } else {
                    c.output_file.write(c.indent + "call " + abi_callconv + "void @" + func_info.name + "(" + args_str + ")\n");
                }
                emit_release_owned_args(c, owned_args);
                return void_result();
            } else {
                call_res_reg = next_reg(c);
                c.output_file.write(c.indent + call_res_reg + " = call " + call_prefix + "@" + func_info.name + "(" + args_str + ")\n");
                emit_release_owned_args(c, owned_args);
                let returns_owned -> Bool = result_owns_value(c, func_info.ret_type) &&
                                            (func_info.abi_name is null || func_info.abi_name.length() == 0);
                return CompileResult(reg=call_res_reg, type=func_info.ret_type, owns_ref=returns_owned);
            }
        }

        else {
            if (callee.type == NODE_VAR_ACCESS) {
                let v_node -> VarAccessNode = callee_node;
                let s_info -> StructInfo = c.struct_table.get(v_node.name_tok.value);
                if (s_info is !null) {
                    if (s_info.is_class) {
                        return compile_class_init(c, s_info, n_call);
                    } else {
                        return compile_struct_init(c, s_info, n_call);
                    }
                }
            }

            let callee_res -> CompileResult = compile_node(c, callee_node);
            if (callee_res is !null && callee_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
            let ptr_type -> Int = callee_res.type;

            let ret_type_id -> Int = 0;
            let is_valid_call -> Bool = false;

            if (ptr_type == TYPE_GENERIC_FUNCTION || ptr_type == TYPE_GENERIC_METHOD) {
                if (callee.type == NODE_VAR_ACCESS) {
                    let v_node -> VarAccessNode = callee_node;
                    let info -> SymbolInfo = find_symbol(c, v_node.name_tok.value);
                    if (info is !null && info.origin_type >= 100) {
                        let f_ret_info -> SymbolInfo = c.func_ret_map.get("" + info.origin_type);
                        if (f_ret_info is !null) {
                            ret_type_id = f_ret_info.type;
                            is_valid_call = true;
                        } else {
                            let m_ret_info -> SymbolInfo = c.method_ret_map.get("" + info.origin_type);
                            if (m_ret_info is !null) {
                                ret_type_id = m_ret_info.type;
                                is_valid_call = true;
                            }
                        }
                    }
                } else {
                    ret_type_id = callee_res.origin_type;
                    if (ret_type_id != 0) { is_valid_call = true; }
                }
                
                if (!is_valid_call) {
                    throw_type_error(n_call.pos, "Generic Function must specify return type.");
                    return void_result();
                }
            } 
            else {
                let f_ret_info -> SymbolInfo = c.func_ret_map.get("" + ptr_type);
                if (f_ret_info is !null) {
                    ret_type_id = f_ret_info.type;
                    is_valid_call = true;
                } else {
                    let m_ret_info -> SymbolInfo = c.method_ret_map.get("" + ptr_type);
                    if (m_ret_info is !null) {
                        ret_type_id = m_ret_info.type;
                        is_valid_call = true;
                    }
                }
            }

            if is_valid_call {
                if (!validate_fallible_call(c, ret_type_id, n_call.preserve_fallible, "", n_call.pos)) {
                    return CompileResult(reg="poison", type=TYPE_POISON);
                }
                let is_closure -> Bool = false;
                let actual_env_reg -> String = "";
                let raw_func_ptr -> String = callee_res.reg;
                let is_func -> Bool = ptr_type == TYPE_GENERIC_FUNCTION || c.func_ret_map.get("" + ptr_type) is !null;
                let is_meth -> Bool = ptr_type == TYPE_GENERIC_METHOD || c.method_ret_map.get("" + ptr_type) is !null;
                if (is_func || is_meth) {
                    is_closure = true;
                    let env_ptr_i8_addr -> String = next_reg(c);
                    c.output_file.write(c.indent + env_ptr_i8_addr + " = getelementptr inbounds i8, i8* " + callee_res.reg + ", i32 " + closure_env_offset() + "\n");
                    let env_ptr_addr -> String = next_reg(c);
                    c.output_file.write(c.indent + env_ptr_addr + " = bitcast i8* " + env_ptr_i8_addr + " to i8**\n");
                    actual_env_reg = next_reg(c);
                    c.output_file.write(c.indent + actual_env_reg + " = load i8*, i8** " + env_ptr_addr + "\n");
                    let f_ptr_i8_addr -> String = next_reg(c);
                    c.output_file.write(c.indent + f_ptr_i8_addr + " = getelementptr inbounds i8, i8* " + callee_res.reg + ", i32 0\n");
                    let f_ptr_addr -> String = next_reg(c);
                    c.output_file.write(c.indent + f_ptr_addr + " = bitcast i8* " + f_ptr_i8_addr + " to i8**\n");
                    raw_func_ptr = next_reg(c);
                    c.output_file.write(c.indent + raw_func_ptr + " = load i8*, i8** " + f_ptr_addr + "\n");
                }

                let args -> Vector(Struct) = n_call.args;
                let a_len -> Int = 0; if (args is !null) { a_len = args.length(); }
                if (reject_named_args(args, n_call.pos, "a Function or Method value")) { return CompileResult(reg="poison", type=TYPE_POISON); }
                
                let expected_args -> Vector(Struct) = null;
                if (ptr_type != TYPE_GENERIC_FUNCTION && ptr_type != TYPE_GENERIC_METHOD) {
                    let sig_info -> SymbolInfo = c.func_ret_map.get("" + ptr_type);
                    if (sig_info is null) { sig_info = c.method_ret_map.get("" + ptr_type); }
                    if (sig_info is !null) { expected_args = sig_info.func_arg_types; }
                }

                if (expected_args is !null) {
                    let exp_len -> Int = expected_args.length();
                    if (a_len != exp_len) {
                        throw_type_error(n_call.pos, "Argument count mismatch in Function/Method call. Expected " + exp_len + ", got " + a_len);
                        return void_result();
                    }
                }

                let a_idx -> Int = 0;

                let sig_g -> String = "";
                let sig_c -> String = "i8*";
                let args_g_str -> String = "";
                let args_c_str -> String = "i8* " + actual_env_reg;
                let first -> Bool = true;
                let owned_args -> Vector(Struct) = [];
                
                while (a_idx < a_len) {
                    let curr_arg -> ArgNode = args[a_idx];
                    let a_res -> CompileResult = compile_node(c, curr_arg.val);
                    
                    if (expected_args is !null) {
                        let exp_arg_node -> TypeListNode = expected_args[a_idx];
                        if (a_res.type != exp_arg_node.type && a_res.type != TYPE_POISON && exp_arg_node.type != TYPE_POISON && a_res.type != TYPE_ANYPTR) {
                            if (!is_subclass(c, a_res.type, exp_arg_node.type)) {
                                throw_type_error(n_call.pos, "Argument type mismatch in Function/Method call. Expected " + get_type_name(c, exp_arg_node.type) + ", got " + get_type_name(c, a_res.type));
                                return void_result();
                            }
                        }
                    }

                    let a_ty -> String = get_llvm_type_str(c, a_res.type);

                    if (!first) {
                        sig_g = sig_g + ", ";
                        args_g_str = args_g_str + ", ";
                        sig_c = sig_c + ", ";
                        args_c_str = args_c_str + ", ";
                    } else {
                        sig_c = sig_c + ", ";
                        args_c_str = args_c_str + ", ";
                    }
                    
                    sig_g += a_ty;
                    args_g_str += a_ty + " " + a_res.reg;
                    sig_c += a_ty;
                    args_c_str += a_ty + " " + a_res.reg;
                    if (a_res.owns_ref) { owned_args.append(a_res); }
                    first = false;
                    a_idx += 1;
                }

                let ret_ty_str -> String = get_llvm_type_str(c, ret_type_id);

                if is_closure {
                    let is_env_null -> String = next_reg(c);
                    c.output_file.write(c.indent + is_env_null + " = icmp eq i8* " + actual_env_reg + ", null\n");
                    
                    let l_global -> String = "call_g_" + c.type_counter;
                    let l_closure -> String = "call_c_" + c.type_counter;
                    let l_merge -> String = "call_m_" + c.type_counter;
                    c.type_counter += 1;
                    
                    c.output_file.write(c.indent + "br i1 " + is_env_null + ", label %" + l_global + ", label %" + l_closure + "\n");

                    c.output_file.write("\n" + l_global + ":\n");
                    let cast_g -> String = next_reg(c);
                    c.output_file.write("  " + cast_g + " = bitcast i8* " + raw_func_ptr + " to " + ret_ty_str + " (" + sig_g + ")*\n");
                    let res_g -> String = "";
                    if (ret_type_id == TYPE_VOID) {
                        c.output_file.write("  call void " + cast_g + "(" + args_g_str + ")\n");
                    } else {
                        res_g = next_reg(c);
                        c.output_file.write("  " + res_g + " = call " + ret_ty_str + " " + cast_g + "(" + args_g_str + ")\n");
                    }
                    c.output_file.write("  br label %" + l_merge + "\n");

                    c.output_file.write("\n" + l_closure + ":\n");
                    let cast_c -> String = next_reg(c);
                    c.output_file.write("  " + cast_c + " = bitcast i8* " + raw_func_ptr + " to " + ret_ty_str + " (" + sig_c + ")*\n");
                    let res_c -> String = "";
                    if (ret_type_id == TYPE_VOID) {
                        c.output_file.write("  call void " + cast_c + "(" + args_c_str + ")\n");
                    } else {
                        res_c = next_reg(c);
                        c.output_file.write("  " + res_c + " = call " + ret_ty_str + " " + cast_c + "(" + args_c_str + ")\n");
                    }
                    c.output_file.write("  br label %" + l_merge + "\n");

                    c.output_file.write("\n" + l_merge + ":\n");
                    if (ret_type_id == TYPE_VOID) {
                        emit_release_owned_args(c, owned_args);
                        emit_release_owned(c, callee_res);
                        return void_result();
                    } else {
                        let final_res -> String = next_reg(c);
                        c.output_file.write("  " + final_res + " = phi " + ret_ty_str + " [ " + res_g + ", %" + l_global + " ], [ " + res_c + ", %" + l_closure + " ]\n");
                        emit_release_owned_args(c, owned_args);
                        emit_release_owned(c, callee_res);
                        return CompileResult(reg=final_res, type=ret_type_id, origin_type=0, owns_ref=result_owns_value(c, ret_type_id));
                    }
                }
            }

            throw_name_error(n_call.pos, "Call target is not a function or function pointer.");
            return void_result();
        }
    }

    if (base.type == NODE_BREAK) {
        let n_break -> BreakNode = node;
        if (c.loop_stack is null) {
            throw_invalid_syntax(n_break.pos, "'break' outside of loop. ");
            return void_result();
        }
        let scope -> LoopScope = c.loop_stack;
        cleanup_scopes_until(c, scope.loop_scope);
        c.output_file.write(c.indent + "br label %" + scope.label_break + "\n");

        return void_result();
    }

    if (base.type == NODE_CONTINUE) {
        let n_cont -> ContinueNode = node;
        if (c.loop_stack is null) {
            throw_invalid_syntax(n_cont.pos, "'continue' outside of loop. ");
            return void_result();
        }
        let scope -> LoopScope = c.loop_stack;
        cleanup_scopes_until(c, scope.loop_scope);
        c.output_file.write(c.indent + "br label %" + scope.label_continue + "\n");

        return void_result();
    }

    if (base.type == NODE_POSTFIX) {
        let u -> PostfixOpNode = node;
        let op_type -> Int = u.op_tok.type;

        let var_node -> BaseNode = u.node;

        let target_reg -> String = "";
        let target_type -> Int = 0;
        let type_str -> String = "";

        if (var_node.type == NODE_VAR_ACCESS) {
            let v_acc -> VarAccessNode = u.node;
            let var_name -> String = v_acc.name_tok.value;

            let info -> SymbolInfo = find_symbol(c, var_name);
            if (info is null) { 
                throw_name_error(v_acc.pos, "Undefined variable '" + var_name + "'. "); 
                let curr_scope -> Scope = c.symbol_table;
                curr_scope.table.put(var_name, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            if (info.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
            if (info.is_const) { throw_type_error(u.pos, "Cannot modify constant variable '" + var_name + "'."); }

            target_reg = info.reg;
            target_type = info.type;
            type_str = get_llvm_type_str(c, info.type);
            
        }
        else if (var_node.type == NODE_FIELD_ACCESS) {
            let f_acc -> FieldAccessNode = u.node;
            if (reject_const_write(c, f_acc.obj, u.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }
            let obj_res -> CompileResult = compile_node(c, f_acc.obj);
            if (obj_res is !null && obj_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
            
            let type_id -> Int = obj_res.type;
            let obj_reg -> String = obj_res.reg;
            
            if (type_id == TYPE_GENERIC_STRUCT) {
                let base_obj -> BaseNode = f_acc.obj;
                if (base_obj.type == NODE_VAR_ACCESS) {
                    let v_node -> VarAccessNode = f_acc.obj;
                    let info -> SymbolInfo = find_symbol(c, v_node.name_tok.value);
                    if (info is !null && info.origin_type >= 100) {
                        type_id = info.origin_type;
                        let s_info_temp -> StructInfo = c.struct_id_map.get("" + type_id);
                        if (s_info_temp is !null) {
                            let cast_reg -> String = next_reg(c);
                            c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + obj_reg + " to " + s_info_temp.llvm_name + "*\n");
                            obj_reg = cast_reg;
                        }
                    }
                }
            }
            
            let s_info -> StructInfo = c.struct_id_map.get("" + type_id);
            if (s_info is null) { throw_type_error(u.pos, "Cannot access field on non-struct type."); }
            
            let field -> FieldInfo = find_field(s_info, f_acc.field_name);
            if (field is null) { throw_name_error(u.pos, "Field '" + f_acc.field_name + "' not found."); }
            
            target_type = field.type;
            type_str = field.llvm_type;
            target_reg = next_reg(c);

            c.output_file.write(c.indent + target_reg + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + obj_reg + ", i32 0, i32 " + field.offset + "\n");
            
        } else {
            let op_str -> String = "++";
            if (op_type == TOK_DEC) { op_str = "--"; }
            throw_type_error(u.pos, "Operator '" + op_str + "' can only be applied to variables or struct fields.");
            return void_result();
        }
        
        if (target_type == TYPE_BOOL) {
            throw_type_error(u.pos, "Cannot increment/decrement Bool type. ");
            return void_result();
        }

        let old_val_reg -> String = next_reg(c);
        c.output_file.write(c.indent + old_val_reg + " = load " + type_str + ", " + type_str + "* " + target_reg + "\n");

        let new_val_reg -> String = next_reg(c);

        if (is_integer_type(target_type)) {
            let op_code -> String = "add";
            if (op_type == TOK_DEC) { op_code = "sub"; }
            c.output_file.write(c.indent + new_val_reg + " = " + op_code + " " + type_str + " " + old_val_reg + ", 1\n");
        }
        else if (target_type == TYPE_FLOAT || target_type == TYPE_FLOAT32) {
            let op_code -> String = "fadd";
            if (op_type == TOK_DEC) { op_code = "fsub"; }
            c.output_file.write(c.indent + new_val_reg + " = " + op_code + " " + type_str + " " + old_val_reg + ", 1.0\n");
        }
        else {
            throw_type_error(u.pos, "Cannot increment/decrement type " + get_type_name(c, target_type));
            return void_result();
        }

        c.output_file.write(c.indent + "store " + type_str + " " + new_val_reg + ", " + type_str + "* " + target_reg + "\n");
        return CompileResult(reg=old_val_reg, type=target_type);
    }

    if (base.type == NODE_UNARYOP) {
        let u -> UnaryOpNode = node;
        let op_type -> Int = u.op_tok.type; 
        
        let operand -> CompileResult = compile_node(c, u.node);
        if (operand is !null && operand.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
        let res_reg -> String = next_reg(c);

        if (op_type == TOK_SUB) {
            if (is_integer_type(operand.type)) {
                let ty_str -> String = get_llvm_type_str(c, operand.type);
                c.output_file.write(c.indent + res_reg + " = sub " + ty_str + " 0, " + operand.reg + "\n");
                return CompileResult(reg=res_reg, type=operand.type);
            } else if (operand.type == TYPE_FLOAT || operand.type == TYPE_FLOAT32) {
                let ty_str -> String = get_llvm_type_str(c, operand.type);
                c.output_file.write(c.indent + res_reg + " = fneg " + ty_str + " " + operand.reg + "\n");
                return CompileResult(reg=res_reg, type=operand.type);
            } else {
                throw_type_error(u.pos, "Cannot negate non-numeric type. ");
                return void_result();
            }
        }
        else if (op_type == TOK_NOT) {
            if (operand.type != TYPE_BOOL) {
                throw_type_error(u.pos, "Operator '!' requires Bool type. ");
                return void_result();
            }
            c.output_file.write(c.indent + res_reg + " = xor i1 " + operand.reg + ", 1\n");
            return CompileResult(reg=res_reg, type=TYPE_BOOL);
        } 
        else if (op_type == TOK_BIT_NOT) {
            if (is_integer_type(operand.type)) {
                let ty_str -> String = get_llvm_type_str(c, operand.type);
                c.output_file.write(c.indent + res_reg + " = xor " + ty_str + " " + operand.reg + ", -1\n");
                return CompileResult(reg=res_reg, type=operand.type);
            } else {
                throw_type_error(u.pos, "Operator '~' requires an integer type.");
                return void_result();
            }
        }
        else {
            return operand;
        }
    }

    return null;
}

func integer_max_literal(type_id -> Int) -> String {
    if (type_id == TYPE_INT8) { return "127"; }
    if (type_id == TYPE_INT16) { return "32767"; }
    if (type_id == TYPE_INT) { return "2147483647"; }
    if (type_id == TYPE_INTSIZE && get_target_pointer_bits() == 32) { return "2147483647"; }
    if (type_id == TYPE_LONG || type_id == TYPE_INTSIZE) { return "9223372036854775807"; }
    if (type_id == TYPE_INT128) { return "170141183460469231731687303715884105727"; }
    if (type_id == TYPE_BYTE) { return "255"; }
    if (type_id == TYPE_UINT16) { return "65535"; }
    if (type_id == TYPE_UINT32) { return "4294967295"; }
    if (type_id == TYPE_UINTSIZE && get_target_pointer_bits() == 32) { return "4294967295"; }
    if (type_id == TYPE_UINT64 || type_id == TYPE_UINTSIZE) { return "18446744073709551615"; }
    if (type_id == TYPE_UINT128) { return "340282366920938463463374607431768211455"; }
    return "";
}

func signed_negative_limit(type_id -> Int) -> UInt128 {
    if (type_id == TYPE_INT8) { return UInt128(128); }
    if (type_id == TYPE_INT16) { return UInt128(32768); }
    if (type_id == TYPE_INT) { return UInt128(2147483648UL); }
    if (type_id == TYPE_INTSIZE && get_target_pointer_bits() == 32) { return UInt128(2147483648UL); }
    if (type_id == TYPE_LONG || type_id == TYPE_INTSIZE) { return UInt128(9223372036854775808UL); }
    if (type_id == TYPE_INT128) { return 170141183460469231731687303715884105728ULL; }
    return UInt128(0);
}

func positive_integer_limit(type_id -> Int) -> UInt128 {
    if (type_id == TYPE_INT8) { return UInt128(127); }
    if (type_id == TYPE_INT16) { return UInt128(32767); }
    if (type_id == TYPE_INT) { return UInt128(2147483647); }
    if (type_id == TYPE_INTSIZE && get_target_pointer_bits() == 32) { return UInt128(2147483647); }
    if (type_id == TYPE_LONG || type_id == TYPE_INTSIZE) { return UInt128(9223372036854775807L); }
    if (type_id == TYPE_INT128) { return 170141183460469231731687303715884105727ULL; }
    if (type_id == TYPE_BYTE) { return UInt128(255); }
    if (type_id == TYPE_UINT16) { return UInt128(65535); }
    if (type_id == TYPE_UINT32) { return UInt128(4294967295UL); }
    if (type_id == TYPE_UINTSIZE && get_target_pointer_bits() == 32) { return UInt128(4294967295UL); }
    if (type_id == TYPE_UINT64 || type_id == TYPE_UINTSIZE) { return UInt128(18446744073709551615UL); }
    if (type_id == TYPE_UINT128) { return 340282366920938463463374607431768211455ULL; }
    return UInt128(0);
}

func parse_decimal_float_literal(raw -> String) -> Float {
    let end -> Int = raw.length();
    if (raw.ends_with("f") || raw.ends_with("F")) { end -= 1; }

    let result -> Float = 0.0;
    let fraction_scale -> Float = 0.1;
    let in_fraction -> Bool = false;
    let i -> Int = 0;
    while (i < end) {
        let ch -> Char = raw[i];
        if (ch == '.') {
            in_fraction = true;
        } else if (ch != '_') {
            let digit -> Int = Int(ch) - Int('0');
            if (!in_fraction) {
                result = result * 10.0 + Float(digit);
            } else {
                result += Float(digit) * fraction_scale;
                fraction_scale *= 0.1;
            }
        }
        i += 1;
    }
    return result;
}

func float_integer_limit(type_id -> Int) -> Float {
    let bits -> Int = get_type_bitwidth(type_id);
    if (is_signed_integer(type_id)) { bits -= 1; }
    let limit -> Float = 1.0;
    let i -> Int = 0;
    while (i < bits) {
        limit *= 2.0;
        i += 1;
    }
    return limit;
}

func is_numeric_literal_expression(node -> Struct) -> Bool {
    if (node is null) { return false; }
    let base -> BaseNode = node;
    if (base.type == NODE_INT || base.type == NODE_FLOAT ||
        base.type == NODE_CHAR || base.type == NODE_BOOL) {
        return true;
    }
    if (base.type == NODE_UNARYOP) {
        let unary -> UnaryOpNode = node;
        if (unary.op_tok.type == TOK_PLUS || unary.op_tok.type == TOK_SUB) {
            return is_numeric_literal_expression(unary.node);
        }
    }
    return false;
}

func validate_explicit_literal_cast(node -> Struct, target_type -> Int, pos -> Position) -> Bool {
    if (node is null) { return true; }
    let base -> BaseNode = node;
    let magnitude -> UInt128 = UInt128(0);
    let negative -> Bool = false;
    let literal_text -> String = "";
    let is_float_literal -> Bool = false;
    let float_value -> Float = 0.0;

    if (base.type == NODE_INT) {
        let integer -> IntNode = node;
        literal_text = integer.tok.value;
        magnitude = parse_const_uint128(integer.tok.value, integer.pos);
    } else if (base.type == NODE_FLOAT) {
        let float_node -> FloatNode = node;
        literal_text = float_node.tok.value;
        float_value = parse_decimal_float_literal(float_node.tok.value);
        is_float_literal = true;
    } else if (base.type == NODE_CHAR) {
        let char_node -> CharNode = node;
        literal_text = "'" + char_node.tok.value + "'";
        magnitude = UInt128(string_to_int(char_node.tok.value, char_node.pos));
    } else if (base.type == NODE_BOOL) {
        return true;
    } else if (base.type == NODE_UNARYOP) {
        let unary -> UnaryOpNode = node;
        let inner_base -> BaseNode = unary.node;
        if (unary.op_tok.type != TOK_SUB) { return true; }
        if (inner_base.type == NODE_INT) {
            let integer -> IntNode = unary.node;
            literal_text = "-" + integer.tok.value;
            magnitude = parse_const_uint128(integer.tok.value, integer.pos);
            negative = magnitude != UInt128(0);
        } else if (inner_base.type == NODE_FLOAT) {
            let float_node -> FloatNode = unary.node;
            literal_text = "-" + float_node.tok.value;
            float_value = 0.0 - parse_decimal_float_literal(float_node.tok.value);
            is_float_literal = true;
        } else {
            return true;
        }
    } else {
        return true;
    }

    let target_name -> String = get_type_name(null, target_type);
    if (is_float_literal) {
        if (!is_integer_type(target_type) && target_type != TYPE_BOOL) { return true; }
        let valid -> Bool = true;
        if (target_type == TYPE_BOOL) {
            valid = float_value == 0.0 || float_value == 1.0;
        } else if (target_type == TYPE_CHAR) {
            valid = float_value >= 0.0 && float_value < 1114112.0 &&
                    (float_value < 55296.0 || float_value >= 57344.0);
        } else {
            let limit -> Float = float_integer_limit(target_type);
            if (is_unsigned_integer(target_type)) {
                valid = float_value >= 0.0 && float_value < limit;
            } else {
                valid = float_value >= 0.0 - limit && float_value < limit;
            }
        }
        if (!valid) {
            throw_overflow_error(pos, "Constant " + literal_text + " overflows " + target_name);
            return false;
        }
        return true;
    }

    if (target_type == TYPE_BOOL) {
        if (negative || magnitude > UInt128(1)) {
            throw_type_error(pos, "Cannot convert constant " + literal_text + " to Bool; expected 0 or 1");
            return false;
        }
        return true;
    }
    if (target_type == TYPE_CHAR) {
        if (negative || magnitude > UInt128(1114111) ||
            (magnitude >= UInt128(55296) && magnitude <= UInt128(57343))) {
            throw_overflow_error(pos, "Constant " + literal_text + " is not a valid Unicode scalar value");
            return false;
        }
        return true;
    }
    if (!is_integer_type(target_type)) { return true; }

    if (!negative) {
        let max_value -> UInt128 = positive_integer_limit(target_type);
        if (max_value != UInt128(0) && magnitude > max_value) {
            throw_overflow_error(pos, "Constant " + literal_text + " overflows " + target_name);
            return false;
        }
        return true;
    }

    if (is_unsigned_integer(target_type)) {
        throw_overflow_error(pos, "Constant " + literal_text + " overflows " + target_name);
        return false;
    }
    let limit -> UInt128 = signed_negative_limit(target_type);
    if (limit != UInt128(0) && magnitude > limit) {
        throw_overflow_error(pos, "Constant " + literal_text + " overflows " + target_name);
        return false;
    }
    return true;
}

func integer_upper_bound(type_id -> Int) -> String {
    if (type_id == TYPE_INT8) { return "128.0"; }
    if (type_id == TYPE_INT16) { return "32768.0"; }
    if (type_id == TYPE_INT) { return "2147483648.0"; }
    if (type_id == TYPE_INTSIZE && get_target_pointer_bits() == 32) { return "2147483648.0"; }
    if (type_id == TYPE_LONG || type_id == TYPE_INTSIZE) { return "9223372036854775808.0"; }
    if (type_id == TYPE_INT128) { return "170141183460469231731687303715884105728.0"; }
    if (type_id == TYPE_BYTE) { return "256.0"; }
    if (type_id == TYPE_UINT16) { return "65536.0"; }
    if (type_id == TYPE_UINT32) { return "4294967296.0"; }
    if (type_id == TYPE_UINTSIZE && get_target_pointer_bits() == 32) { return "4294967296.0"; }
    if (type_id == TYPE_UINT64 || type_id == TYPE_UINTSIZE) { return "18446744073709551616.0"; }
    if (type_id == TYPE_UINT128) { return "340282366920938463463374607431768211456.0"; }
    return "";
}

func integer_lower_bound(type_id -> Int) -> String {
    if (is_unsigned_integer(type_id)) { return "0.0"; }
    if (type_id == TYPE_INT8) { return "-128.0"; }
    if (type_id == TYPE_INT16) { return "-32768.0"; }
    if (type_id == TYPE_INT) { return "-2147483648.0"; }
    if (type_id == TYPE_INTSIZE && get_target_pointer_bits() == 32) { return "-2147483648.0"; }
    if (type_id == TYPE_LONG || type_id == TYPE_INTSIZE) { return "-9223372036854775808.0"; }
    if (type_id == TYPE_INT128) { return "-170141183460469231731687303715884105728.0"; }
    return "0.0";
}

func append_cast_condition(c -> Compiler, current -> String, next -> String) -> String {
    if (current.length() == 0) { return next; }
    let combined -> String = next_reg(c);
    c.output_file.write(c.indent + combined + " = and i1 " + current + ", " + next + "\n");
    return combined;
}

func emit_integer_cast_check(c -> Compiler, value -> String, source_type -> Int, target_type -> Int) -> String {
    let llvm_type -> String = get_llvm_type_str(c, source_type);
    let signed_source -> Bool = is_signed_integer(source_type);
    let source_bits -> Int = get_type_bitwidth(source_type);
    let target_bits -> Int = get_type_bitwidth(target_type);
    let valid -> String = "";

    if (target_type == TYPE_BOOL) {
        let is_zero -> String = next_reg(c);
        let is_one -> String = next_reg(c);
        let result -> String = next_reg(c);
        c.output_file.write(c.indent + is_zero + " = icmp eq " + llvm_type + " " + value + ", 0\n");
        c.output_file.write(c.indent + is_one + " = icmp eq " + llvm_type + " " + value + ", 1\n");
        c.output_file.write(c.indent + result + " = or i1 " + is_zero + ", " + is_one + "\n");
        return result;
    }

    if (target_type == TYPE_CHAR) {
        if (signed_source) {
            let non_negative -> String = next_reg(c);
            c.output_file.write(c.indent + non_negative + " = icmp sge " + llvm_type + " " + value + ", 0\n");
            valid = append_cast_condition(c, valid, non_negative);
        }
        if (source_bits >= 32) {
            let below_limit -> String = next_reg(c);
            let predicate -> String = "ule";
            if (signed_source) { predicate = "sle"; }
            c.output_file.write(c.indent + below_limit + " = icmp " + predicate + " " + llvm_type + " " + value + ", 1114111\n");
            valid = append_cast_condition(c, valid, below_limit);
        }
        let can_reach_surrogates -> Bool = source_bits >= 32 ||
            (!signed_source && source_bits >= 16);
        if (can_reach_surrogates) {
            let below_surrogates -> String = next_reg(c);
            let above_surrogates -> String = next_reg(c);
            let outside_surrogates -> String = next_reg(c);
            let less_predicate -> String = "ult";
            let greater_predicate -> String = "ugt";
            if (signed_source) {
                less_predicate = "slt";
                greater_predicate = "sgt";
            }
            c.output_file.write(c.indent + below_surrogates + " = icmp " + less_predicate + " " + llvm_type + " " + value + ", 55296\n");
            c.output_file.write(c.indent + above_surrogates + " = icmp " + greater_predicate + " " + llvm_type + " " + value + ", 57343\n");
            c.output_file.write(c.indent + outside_surrogates + " = or i1 " + below_surrogates + ", " + above_surrogates + "\n");
            valid = append_cast_condition(c, valid, outside_surrogates);
        }
        if (valid.length() == 0) { return "true"; }
        return valid;
    }

    let source_unsigned -> Bool = is_unsigned_integer(source_type);
    let target_unsigned -> Bool = is_unsigned_integer(target_type);
    if (!source_unsigned && target_unsigned) {
        let non_negative -> String = next_reg(c);
        c.output_file.write(c.indent + non_negative + " = icmp sge " + llvm_type + " " + value + ", 0\n");
        valid = append_cast_condition(c, valid, non_negative);
        if (target_bits < source_bits) {
            let below_max -> String = next_reg(c);
            c.output_file.write(c.indent + below_max + " = icmp sle " + llvm_type + " " + value + ", " + integer_max_literal(target_type) + "\n");
            valid = append_cast_condition(c, valid, below_max);
        }
    } else if (source_unsigned && !target_unsigned) {
        let below_max -> String = next_reg(c);
        c.output_file.write(c.indent + below_max + " = icmp ule " + llvm_type + " " + value + ", " + integer_max_literal(target_type) + "\n");
        valid = append_cast_condition(c, valid, below_max);
    } else if (source_bits > target_bits) {
        let below_max -> String = next_reg(c);
        let predicate -> String = "ule";
        if (signed_source) { predicate = "sle"; }
        c.output_file.write(c.indent + below_max + " = icmp " + predicate + " " + llvm_type + " " + value + ", " + integer_max_literal(target_type) + "\n");
        valid = append_cast_condition(c, valid, below_max);
        if (signed_source) {
            let above_min -> String = next_reg(c);
            c.output_file.write(c.indent + above_min + " = icmp sge " + llvm_type + " " + value + ", " + get_signed_min_literal(target_type) + "\n");
            valid = append_cast_condition(c, valid, above_min);
        }
    }

    if (valid.length() == 0) { return "true"; }
    return valid;
}

func emit_float_cast_check(c -> Compiler, value -> String, source_type -> Int, target_type -> Int) -> String {
    let llvm_type -> String = get_llvm_type_str(c, source_type);
    if (target_type == TYPE_BOOL) {
        let is_zero -> String = next_reg(c);
        let is_one -> String = next_reg(c);
        let valid -> String = next_reg(c);
        c.output_file.write(c.indent + is_zero + " = fcmp oeq " + llvm_type + " " + value + ", 0.0\n");
        c.output_file.write(c.indent + is_one + " = fcmp oeq " + llvm_type + " " + value + ", 1.0\n");
        c.output_file.write(c.indent + valid + " = or i1 " + is_zero + ", " + is_one + "\n");
        return valid;
    }

    let valid -> String = "";
    let lower -> String = next_reg(c);
    let upper -> String = next_reg(c);
    let lower_bound -> String = integer_lower_bound(target_type);
    let upper_bound -> String = integer_upper_bound(target_type);
    if (target_type == TYPE_CHAR) {
        lower_bound = "0.0";
        upper_bound = "1114112.0";
    }
    c.output_file.write(c.indent + lower + " = fcmp oge " + llvm_type + " " + value + ", " + lower_bound + "\n");
    c.output_file.write(c.indent + upper + " = fcmp olt " + llvm_type + " " + value + ", " + upper_bound + "\n");
    valid = append_cast_condition(c, valid, lower);
    valid = append_cast_condition(c, valid, upper);

    if (target_type == TYPE_CHAR) {
        let before_surrogates -> String = next_reg(c);
        let after_surrogates -> String = next_reg(c);
        let outside_surrogates -> String = next_reg(c);
        c.output_file.write(c.indent + before_surrogates + " = fcmp olt " + llvm_type + " " + value + ", 55296.0\n");
        c.output_file.write(c.indent + after_surrogates + " = fcmp oge " + llvm_type + " " + value + ", 57344.0\n");
        c.output_file.write(c.indent + outside_surrogates + " = or i1 " + before_surrogates + ", " + after_surrogates + "\n");
        valid = append_cast_condition(c, valid, outside_surrogates);
    }
    return valid;
}

func standard_overflow_error(c -> Compiler, pos -> Position) -> CompileResult {
    let i -> Int = 0;
    while (i < c.error_types.length()) {
        let info -> StructInfo = c.error_types[i];
        if (info.compiler_link_name == "Error") {
            let field -> FieldInfo = find_field(info, "Overflow");
            if (field is !null) {
                return emit_error_value(c, CompileResult(reg="" + field.offset, type=info.type_id, origin_type=info.type_id), pos);
            }
        }
        i += 1;
    }
    throw_internal_compiler_error(pos, "The standard Error enum does not define Overflow.");
    return CompileResult(reg="zeroinitializer", type=TYPE_ANY_ERROR);
}

func emit_fallible_cast(c -> Compiler, value -> CompileResult, valid -> String, target_type -> Int, pos -> Position) -> CompileResult {
    let fail_label -> String = next_label(c);
    let success_label -> String = next_label(c);
    let end_label -> String = next_label(c);
    let fallible_type -> Int = get_fallible_type_id(c, target_type);
    let fallible_llvm -> String = get_llvm_type_str(c, fallible_type);
    let target_llvm -> String = get_llvm_type_str(c, target_type);

    c.output_file.write(c.indent + "br i1 " + valid + ", label %" + success_label + ", label %" + fail_label + "\n");

    c.output_file.write("\n" + fail_label + ":\n");
    let error_value -> CompileResult = standard_overflow_error(c, pos);
    let fail_1 -> String = next_reg(c);
    let fail_2 -> String = next_reg(c);
    c.output_file.write(c.indent + fail_1 + " = insertvalue " + fallible_llvm + " undef, i1 true, 0\n");
    c.output_file.write(c.indent + fail_2 + " = insertvalue " + fallible_llvm + " " + fail_1 + ", { i64, i32 } " + error_value.reg + ", 1\n");
    c.output_file.write(c.indent + "br label %" + end_label + "\n");

    c.output_file.write("\n" + success_label + ":\n");
    let converted -> CompileResult = compile_type_cast(c, value, target_type, pos);
    let success_1 -> String = next_reg(c);
    let success_2 -> String = next_reg(c);
    let success_3 -> String = next_reg(c);
    c.output_file.write(c.indent + success_1 + " = insertvalue " + fallible_llvm + " undef, i1 false, 0\n");
    c.output_file.write(c.indent + success_2 + " = insertvalue " + fallible_llvm + " " + success_1 + ", { i64, i32 } zeroinitializer, 1\n");
    c.output_file.write(c.indent + success_3 + " = insertvalue " + fallible_llvm + " " + success_2 + ", " + target_llvm + " " + converted.reg + ", 2\n");
    c.output_file.write(c.indent + "br label %" + end_label + "\n");

    c.output_file.write("\n" + end_label + ":\n");
    let result -> String = next_reg(c);
    c.output_file.write(c.indent + result + " = phi " + fallible_llvm + " [ " + fail_2 + ", %" + fail_label + " ], [ " + success_3 + ", %" + success_label + " ]\n");
    return CompileResult(reg=result, type=fallible_type, origin_type=0, owns_ref=false);
}

func unwrap_conversion_or_panic(c -> Compiler, value -> CompileResult, source_type -> Int, target_type -> Int, pos -> Position) -> CompileResult {
    let fallible_llvm -> String = get_llvm_type_str(c, value.type);
    let failed -> String = next_reg(c);
    let fail_label -> String = next_label(c);
    let success_label -> String = next_label(c);
    c.output_file.write(c.indent + failed + " = extractvalue " + fallible_llvm + " " + value.reg + ", 0\n");
    c.output_file.write(c.indent + "br i1 " + failed + ", label %" + fail_label + ", label %" + success_label + "\n");

    c.output_file.write("\n" + fail_label + ":\n");
    emit_runtime_error(c, pos, "conversion from " + get_type_name(c, source_type) + " to " + get_type_name(c, target_type) + " failed");

    c.output_file.write("\n" + success_label + ":\n");
    let result -> String = next_reg(c);
    c.output_file.write(c.indent + result + " = extractvalue " + fallible_llvm + " " + value.reg + ", 2\n");
    return CompileResult(reg=result, type=target_type, origin_type=0, owns_ref=value.owns_ref && needs_drop(c, target_type));
}

func compile_explicit_type_cast(c -> Compiler, value -> CompileResult, target_type -> Int, pos -> Position, preserve_failure -> Bool) -> CompileResult {
    if (value.type == TYPE_POISON) { return value; }

    if (value.type == TYPE_ANY_ERROR && is_integer_type(target_type)) {
        let code -> String = next_reg(c);
        c.output_file.write(c.indent + code + " = extractvalue { i64, i32 } " + value.reg + ", 1\n");
        return compile_explicit_type_cast(c, CompileResult(reg=code, type=TYPE_INT), target_type, pos, preserve_failure);
    }

    if (!needs_explicit_cast(c, value.type, target_type)) {
        return compile_type_cast(c, value, target_type, pos);
    }

    let check_type -> Int = value.type;
    let source_info -> StructInfo = c.struct_id_map.get("" + check_type);
    if (source_info is !null && source_info.is_enum) { check_type = TYPE_INT; }

    let valid -> String = "";
    if (is_integer_type(check_type)) {
        valid = emit_integer_cast_check(c, value.reg, check_type, target_type);
    } else if (check_type == TYPE_FLOAT || check_type == TYPE_FLOAT32) {
        valid = emit_float_cast_check(c, value.reg, check_type, target_type);
    } else {
        return compile_type_cast(c, value, target_type, pos);
    }

    if (preserve_failure) {
        return emit_fallible_cast(c, value, valid, target_type, pos);
    }

    let fail_label -> String = next_label(c);
    let success_label -> String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + valid + ", label %" + success_label + ", label %" + fail_label + "\n");
    c.output_file.write("\n" + fail_label + ":\n");
    emit_runtime_error(c, pos, "conversion from " + get_type_name(c, value.type) + " to " + get_type_name(c, target_type) + " is out of range");
    c.output_file.write("\n" + success_label + ":\n");
    return compile_type_cast(c, value, target_type, pos);
}

func compile_type_cast(c -> Compiler, val_res -> CompileResult, target_type -> Int, pos -> Position) -> CompileResult {
    if (val_res.type == TYPE_POISON) { return val_res; }
    if (val_res.type == target_type) { return val_res; }

    let src_ty_str -> String = get_llvm_type_str(c, val_res.type);
    let dst_ty_str -> String = get_llvm_type_str(c, target_type);
    let res_reg -> String = next_reg(c);

    if (target_type == TYPE_STRING) {
        return convert_to_string(c, val_res);
    }

    if (val_res.type == TYPE_ANY_ERROR && is_integer_type(target_type)) {
        let code -> String = next_reg(c);
        c.output_file.write(c.indent + code + " = extractvalue { i64, i32 } " + val_res.reg + ", 1\n");
        return compile_type_cast(c, CompileResult(reg=code, type=TYPE_INT), target_type, pos);
    }

    let src_is_float -> Bool = val_res.type == TYPE_FLOAT || val_res.type == TYPE_FLOAT32;
    let dst_is_float -> Bool = target_type == TYPE_FLOAT || target_type == TYPE_FLOAT32;

    let src_is_int -> Bool = is_integer_type(val_res.type) || val_res.type == TYPE_BOOL;
    let dst_is_int -> Bool = is_integer_type(target_type) || target_type == TYPE_BOOL;

    let src_info -> StructInfo = c.struct_id_map.get("" + val_res.type);
    let src_is_enum -> Bool = src_info is !null && src_info.is_enum;
    if (src_is_enum && is_integer_type(target_type)) {
        let dst_bits -> Int = get_type_bitwidth(target_type);
        if (dst_bits == 32) {
            return CompileResult(reg=val_res.reg, type=target_type, origin_type=0);
        }
        if (dst_bits < 32) {
            c.output_file.write(c.indent + res_reg + " = trunc i32 " + val_res.reg + " to " + dst_ty_str + "\n");
        } else {
            c.output_file.write(c.indent + res_reg + " = zext i32 " + val_res.reg + " to " + dst_ty_str + "\n");
        }
        return CompileResult(reg=res_reg, type=target_type, origin_type=0);
    }
    
    let src_is_ptr -> Bool = is_pointer_type(c, val_res.type) || val_res.type == TYPE_STRING || val_res.type == TYPE_ANYPTR || val_res.type == TYPE_NULLPTR;
    let dst_is_ptr -> Bool = is_pointer_type(c, target_type) || target_type == TYPE_STRING || target_type == TYPE_ANYPTR;

    if (src_is_ptr && dst_is_ptr) {
        c.output_file.write(c.indent + res_reg + " = bitcast " + src_ty_str + " " + val_res.reg + " to " + dst_ty_str + "\n");
        return CompileResult(reg=res_reg, type=target_type, origin_type=0);
    }

    if (src_is_ptr && dst_is_int) {
        c.output_file.write(c.indent + res_reg + " = ptrtoint " + src_ty_str + " " + val_res.reg + " to " + dst_ty_str + "\n");
        return CompileResult(reg=res_reg, type=target_type, origin_type=0);
    }
    if (src_is_int && dst_is_ptr) {
        c.output_file.write(c.indent + res_reg + " = inttoptr " + src_ty_str + " " + val_res.reg + " to " + dst_ty_str + "\n");
        return CompileResult(reg=res_reg, type=target_type, origin_type=0);
    }

    if (src_is_float && dst_is_float) {
        if (val_res.type == TYPE_FLOAT && target_type == TYPE_FLOAT32) {
            c.output_file.write(c.indent + res_reg + " = fptrunc double " + val_res.reg + " to float\n");
        } else {
            c.output_file.write(c.indent + res_reg + " = fpext float " + val_res.reg + " to double\n");
        }
        return CompileResult(reg=res_reg, type=target_type, origin_type=0);
    }

    if (src_is_int && dst_is_float) {
        let op -> String = "sitofp";
        if (is_unsigned_integer(val_res.type) || val_res.type == TYPE_BOOL) { op = "uitofp"; }
        c.output_file.write(c.indent + res_reg + " = " + op + " " + src_ty_str + " " + val_res.reg + " to " + dst_ty_str + "\n");
        return CompileResult(reg=res_reg, type=target_type, origin_type=0);
    }
    if (src_is_float && dst_is_int) {
        let op -> String = "fptosi";
        if (is_unsigned_integer(target_type) || target_type == TYPE_BOOL) { op = "fptoui"; }
        c.output_file.write(c.indent + res_reg + " = " + op + " " + src_ty_str + " " + val_res.reg + " to " + dst_ty_str + "\n");
        return CompileResult(reg=res_reg, type=target_type, origin_type=0);
    }

    if (src_is_int && dst_is_int) {
        let src_bits -> Int = get_type_bitwidth(val_res.type);
        let dst_bits -> Int = get_type_bitwidth(target_type);
        
        if (src_bits == dst_bits) {
            return CompileResult(reg=val_res.reg, type=target_type, origin_type=0);
        }
        if (src_bits > dst_bits) {
            c.output_file.write(c.indent + res_reg + " = trunc " + src_ty_str + " " + val_res.reg + " to " + dst_ty_str + "\n");
        } else {
            let op -> String = "sext";
            if (is_unsigned_integer(val_res.type) || val_res.type == TYPE_BOOL) { op = "zext"; }
            c.output_file.write(c.indent + res_reg + " = " + op + " " + src_ty_str + " " + val_res.reg + " to " + dst_ty_str + "\n");
        }
        return CompileResult(reg=res_reg, type=target_type, origin_type=0);
    }

    throw_type_error(pos, "Unsupported explicit type cast.");
    return void_result();
}

// BUILTIN HELPER
func compile_print(c -> Compiler, reg -> String, type_id -> Int, pos -> Position, origin_id -> Int) -> Void {
    if (type_id == TYPE_POISON) { return; }
    if (is_fallible_type(c, type_id)) {
        throw_type_error(pos, "Fallible value must be handled with '?' before printing");
        return;
    }

    if (type_id == TYPE_INT128 || type_id == TYPE_UINT128) {
        let formatted -> CompileResult = convert_to_string(c, CompileResult(reg=reg, type=type_id, origin_type=origin_id));
        compile_print(c, formatted.reg, TYPE_STRING, pos, TYPE_STRING);
        emit_release_owned(c, formatted);
        return;
    }

    if (type_id == TYPE_STRING) {
        let hook_raw_str -> String = get_mangled_symbol(c, "print_bytes", pos);
        let label_null -> String = next_label(c);
        let label_value -> String = next_label(c);
        let label_end -> String = next_label(c);
        let is_null -> String = next_reg(c);

        c.output_file.write(c.indent + is_null + " = icmp eq %struct.$String* " + reg + ", null\n");
        c.output_file.write(c.indent + "br i1 " + is_null + ", label %" + label_null + ", label %" + label_value + "\n");

        c.output_file.write("\n" + label_null + ":\n");
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* null, i32 0)\n");
        c.output_file.write(c.indent + "br label %" + label_end + "\n");

        c.output_file.write("\n" + label_value + ":\n");
        let struct_reg -> String = next_reg(c);
        let ptr_reg -> String = next_reg(c);
        let len_field -> String = next_reg(c);
        let len_reg -> String = next_reg(c);
        c.output_file.write(c.indent + struct_reg + " = getelementptr inbounds %struct.$String, %struct.$String* " + reg + ", i32 0, i32 0\n");
        c.output_file.write(c.indent + ptr_reg + " = load i8*, i8** " + struct_reg + "\n");
        c.output_file.write(c.indent + len_field + " = getelementptr inbounds %struct.$String, %struct.$String* " + reg + ", i32 0, i32 1\n");
        c.output_file.write(c.indent + len_reg + " = load i32, i32* " + len_field + "\n");
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + ptr_reg + ", i32 " + len_reg + ")\n");
        c.output_file.write(c.indent + "br label %" + label_end + "\n");

        c.output_file.write("\n" + label_end + ":\n");
        return;
    }

    if (type_id == TYPE_CHAR) {
        let hook_char -> String = get_mangled_symbol(c, "print_char", pos);
        c.output_file.write(c.indent + "call void @" + hook_char + "(i32 " + reg + ")\n");
        return;
    }

    if (type_id == TYPE_ANY_ERROR) {
        compile_print_error_internal(c, reg, pos);
        return;
    }

    if (type_id == TYPE_UINT64 || type_id == TYPE_UINTSIZE) {
        let formatted -> CompileResult = convert_to_string(c, CompileResult(reg=reg, type=type_id, origin_type=origin_id));
        compile_print(c, formatted.reg, TYPE_STRING, pos, TYPE_STRING);
        emit_release_owned(c, formatted);
        return;
    }

    if (is_primitive_type(type_id)) {
        if (type_id == TYPE_INT || type_id == TYPE_INT8 || type_id == TYPE_INT16 || type_id == TYPE_UINT16) {
            let temp_res -> CompileResult = CompileResult(reg=reg, type=type_id, origin_type=origin_id);
            if (type_id != TYPE_INT) { temp_res = promote_to_int(c, temp_res); }
            let hook_int -> String = get_mangled_symbol(c, "print_int", pos);
            c.output_file.write(c.indent + "call void @" + hook_int + "(i32 " + temp_res.reg + ")\n");
            return;
        }
        if (type_id == TYPE_LONG || type_id == TYPE_UINT32 || type_id == TYPE_INTSIZE) {
            let temp_res -> CompileResult = CompileResult(reg=reg, type=type_id, origin_type=origin_id);
            if (type_id != TYPE_LONG) { temp_res = promote_to_long(c, temp_res); }
            let hook_long -> String = get_mangled_symbol(c, "print_long", pos);
            c.output_file.write(c.indent + "call void @" + hook_long + "(i64 " + temp_res.reg + ")\n");
            return;
        }
        if (type_id == TYPE_FLOAT || type_id == TYPE_FLOAT32) {
            let temp_res -> CompileResult = CompileResult(reg=reg, type=type_id, origin_type=origin_id);
            if (type_id != TYPE_FLOAT) { temp_res = promote_to_float(c, temp_res); }
            let hook_float -> String = get_mangled_symbol(c, "print_float", pos);
            c.output_file.write(c.indent + "call void @" + hook_float + "(double " + temp_res.reg + ")\n");
            return;
        }
        if (type_id == TYPE_BOOL) {
            let hook_bool -> String = get_mangled_symbol(c, "print_bool", pos);
            c.output_file.write(c.indent + "call void @" + hook_bool + "(i1 " + reg + ")\n");
            return;
        }
        throw_type_error(pos, "Unsupported primitive type for printing.");
        return;
    }

    if (type_id == TYPE_NULL || type_id == TYPE_NULLPTR) {
        let hook_raw_str -> String = get_mangled_symbol(c, "print_bytes", pos);
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([5 x i8], [5 x i8]* @.str_null, i32 0, i32 0), i32 4)\n");
        return;
    }

    if (is_pointer_type(c, type_id)) {
        let base_info -> SymbolInfo = c.ptr_base_map.get("" + type_id);
        if (base_info is !null && base_info.type == TYPE_BYTE) {
            let hook_raw_str -> String = get_mangled_symbol(c, "print_raw_string", pos);
            c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + reg + ")\n");
        } else {
            let hook_long -> String = get_mangled_symbol(c, "print_long", pos);
            let p_to_i -> String = next_reg(c);
            c.output_file.write(c.indent + p_to_i + " = ptrtoint i8* " + reg + " to i64\n");
            c.output_file.write(c.indent + "call void @" + hook_long + "(i64 " + p_to_i + ")\n");
        }
        return;
    }
    
    if (type_id == TYPE_GENERIC_STRUCT || type_id == TYPE_GENERIC_CLASS) {
        if (origin_id >= 100) {
            let s_info_real -> StructInfo = c.struct_id_map.get("" + origin_id);
            if (s_info_real is !null) {
                let cast_reg -> String = next_reg(c);
                c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + reg + " to " + s_info_real.llvm_name + "*\n");
                compile_print_struct_internal(c, cast_reg, s_info_real, pos);
                return;
            }
        }
        let ptr_i64 -> String = next_reg(c);
        let hook_long -> String = get_mangled_symbol(c, "print_long", pos);
        c.output_file.write(c.indent + ptr_i64 + " = ptrtoint i8* " + reg + " to i64\n");
        c.output_file.write(c.indent + "call void @" + hook_long + "(i64 " + ptr_i64 + ")\n");
        return;
    }
    
    if (type_id >= 100) {
        let s_info -> StructInfo = c.struct_id_map.get("" + type_id);
        if (s_info is !null) {
            if (s_info.name == "$Variant") {
                compile_print_variant_internal(c, reg, s_info, pos);
                return;
            }
            if (s_info.is_enum) {
                compile_print_enum_internal(c, reg, s_info, pos);
                return;
            }
            compile_print_struct_internal(c, reg, s_info, pos);
            return;
        }
        
        let v_info -> SymbolInfo = c.vector_base_map.get("" + type_id);
        if (v_info is !null) {
            compile_print_vector_internal(c, reg, v_info, pos);
            return;
        }

        let arr_info -> ArrayInfo = c.array_info_map.get("" + type_id);
        if (arr_info is !null) {
            compile_print_array_internal(c, reg, type_id, arr_info, pos);
            return;
        }
    }
}

func compile_print_error_internal(c -> Compiler, error_reg -> String, pos -> Position) -> Void {
    let domain -> String = next_reg(c);
    let code -> String = next_reg(c);
    let end_label -> String = next_label(c);
    c.output_file.write(c.indent + domain + " = extractvalue { i64, i32 } " + error_reg + ", 0\n");
    c.output_file.write(c.indent + code + " = extractvalue { i64, i32 } " + error_reg + ", 1\n");

    let i -> Int = 0;
    while (i < c.error_types.length()) {
        let info -> StructInfo = c.error_types[i];
        let match_label -> String = next_label(c);
        let next_type_label -> String = next_label(c);
        let matches -> String = next_reg(c);
        c.output_file.write(c.indent + matches + " = icmp eq i64 " + domain + ", " + type_fingerprint(c, info.type_id) + "\n");
        c.output_file.write(c.indent + "br i1 " + matches + ", label %" + match_label + ", label %" + next_type_label + "\n");

        c.output_file.write("\n" + match_label + ":\n");
        compile_print_enum_internal(c, code, info, pos);
        c.output_file.write(c.indent + "br label %" + end_label + "\n");

        c.output_file.write("\n" + next_type_label + ":\n");
        i += 1;
    }

    let hook_raw_str -> String = get_mangled_symbol(c, "print_bytes", pos);
    let hook_int -> String = get_mangled_symbol(c, "print_int", pos);
    let prefix -> String = "Error(code=";
    let prefix_id -> Int = register_string_constant(c, prefix);
    let prefix_ptr -> String = get_string_ptr(prefix_id, prefix);
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + prefix_ptr + ", i32 " + prefix.length() + ")\n");
    c.output_file.write(c.indent + "call void @" + hook_int + "(i32 " + code + ")\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_close_paren, i32 0, i32 0), i32 1)\n");
    c.output_file.write(c.indent + "br label %" + end_label + "\n");

    c.output_file.write("\n" + end_label + ":\n");
}

func compile_print_enum_internal(c -> Compiler, enum_reg -> String, s_info -> StructInfo, pos -> Position) -> Void {
    let hook_raw_str -> String = get_mangled_symbol(c, "print_bytes", pos);
    let default_label -> String = next_label(c);
    let end_label -> String = next_label(c);
    
    let fields -> Vector(Struct) = s_info.fields;
    let len -> Int = 0; if (fields is !null) { len = fields.length(); }
    
    c.output_file.write(c.indent + "switch i32 " + enum_reg + ", label %" + default_label + " [\n");
    
    let i -> Int = 0;
    let labels -> Vector(String) = [];
    while (i < len) {
        let f -> FieldInfo = fields[i];
        let lbl -> String = next_label(c);
        labels.append(lbl);
        c.output_file.write("    i32 " + f.offset + ", label %" + lbl + "\n");
        i += 1;
    }
    c.output_file.write("  ]\n");
    
    i = 0;
    while (i < len) {
        let f -> FieldInfo = fields[i];
        let lbl -> String = labels[i];
        c.output_file.write("\n" + lbl + ":\n");
        let name_str -> String = s_info.name + "." + f.name;
        let id -> Int = register_string_constant(c, name_str);
        let ptr_ -> String = get_string_ptr(id, name_str);
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + ptr_ + ", i32 " + name_str.length() + ")\n");
        c.output_file.write(c.indent + "br label %" + end_label + "\n");
        i += 1;
    }
    
    c.output_file.write("\n" + default_label + ":\n");
    let unk_str -> String = s_info.name + "(<unknown>)";
    let unk_id -> Int = register_string_constant(c, unk_str);
    let unk_ptr -> String = get_string_ptr(unk_id, unk_str);
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + unk_ptr + ", i32 " + unk_str.length() + ")\n");
    c.output_file.write(c.indent + "br label %" + end_label + "\n");
    
    c.output_file.write("\n" + end_label + ":\n");
}

func compile_print_struct_internal(c -> Compiler, obj_reg -> String, s_info -> StructInfo, pos -> Position) -> Void {
    let hook_raw_str -> String = get_mangled_symbol(c, "print_bytes", pos);
    let header -> String = s_info.name + "(";
    let header_id -> Int = register_string_constant(c, header);
    let header_ptr -> String = get_string_ptr(header_id, header);
    
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + header_ptr + ", i32 " + header.length() + ")\n");

    let fields_vec -> Vector(Struct) = s_info.fields;
    let f_len -> Int = 0;
    if (fields_vec is !null) { f_len = fields_vec.length(); }
    let f_idx -> Int = 0;
    
    while (f_idx < f_len) {
        let f_curr -> FieldInfo = fields_vec[f_idx];
        if (f_curr.name == "_vptr") {
            f_idx += 1;
            continue;
        }
        let f_name_eq -> String = f_curr.name + "=";
        let fn_id -> Int = register_string_constant(c, f_name_eq);
        let fn_ptr -> String = get_string_ptr(fn_id, f_name_eq);
    
        c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* " + fn_ptr + ", i32 " + f_name_eq.length() + ")\n");
        
        let f_ptr -> String = next_reg(c);
        c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + obj_reg + ", i32 0, i32 " + f_curr.offset + "\n");
        let f_val_reg -> String = next_reg(c);
        c.output_file.write(c.indent + f_val_reg + " = load " + f_curr.llvm_type + ", " + f_curr.llvm_type + "* " + f_ptr + "\n");
        compile_print(c, f_val_reg, f_curr.type, pos, f_curr.type); 

        f_idx += 1;
        if (f_idx < f_len) {
            c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([3 x i8], [3 x i8]* @.str_comma_space, i32 0, i32 0), i32 2)\n");
        }
    }
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_close_paren, i32 0, i32 0), i32 1)\n");
}

func compile_print_vector_internal(c -> Compiler, vec_reg -> String, v_info -> SymbolInfo, pos -> Position) -> Void {
    let hook_raw_str -> String = get_mangled_symbol(c, "print_bytes", pos);
    let elem_type -> Int = v_info.type;
    let elem_ty_str -> String = get_llvm_type_str(c, elem_type);
    let struct_ty -> String = get_vector_llvm_type(c, elem_type);
    let size_ty -> String = get_size_llvm_type();

    let size_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_reg + ", i32 0, i32 0\n");
    let size_val -> String = next_reg(c);
    c.output_file.write(c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");
    
    let data_ptr_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + data_ptr_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_reg + ", i32 0, i32 2\n");
    let data_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + data_ptr + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_ptr_ptr + "\n");

    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_open_bracket, i32 0, i32 0), i32 1)\n");

    let label_cond -> String = next_label(c);
    let label_body -> String = next_label(c);
    let label_sep  -> String = next_label(c);
    let label_end  -> String = next_label(c);

    let idx_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + idx_ptr + " = alloca " + size_ty + "\n");
    c.output_file.write(c.indent + "store " + size_ty + " 0, " + size_ty + "* " + idx_ptr + "\n");
    c.output_file.write(c.indent + "br label %" + label_cond + "\n");

    c.output_file.write("\n" + label_cond + ":\n");
    let curr_idx -> String = next_reg(c);
    c.output_file.write(c.indent + curr_idx + " = load " + size_ty + ", " + size_ty + "* " + idx_ptr + "\n");
    let cmp -> String = next_reg(c);
    c.output_file.write(c.indent + cmp + " = icmp ult " + size_ty + " " + curr_idx + ", " + size_val + "\n");
    c.output_file.write(c.indent + "br i1 " + cmp + ", label %" + label_body + ", label %" + label_end + "\n");

    c.output_file.write("\n" + label_body + ":\n");
    let slot -> String = next_reg(c);
    c.output_file.write(c.indent + slot + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", " + size_ty + " " + curr_idx + "\n");
    let val -> String = next_reg(c);
    c.output_file.write(c.indent + val + " = load " + elem_ty_str + ", " + elem_ty_str + "* " + slot + "\n");
    
    compile_print(c, val, elem_type, pos, elem_type);

    let next_idx -> String = next_reg(c);
    c.output_file.write(c.indent + next_idx + " = add " + size_ty + " " + curr_idx + ", 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + next_idx + ", " + size_ty + "* " + idx_ptr + "\n");
    
    let is_not_last -> String = next_reg(c);
    c.output_file.write(c.indent + is_not_last + " = icmp ult " + size_ty + " " + next_idx + ", " + size_val + "\n");
    c.output_file.write(c.indent + "br i1 " + is_not_last + ", label %" + label_sep + ", label %" + label_cond + "\n");

    c.output_file.write("\n" + label_sep + ":\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([3 x i8], [3 x i8]* @.str_comma_space, i32 0, i32 0), i32 2)\n");
    c.output_file.write(c.indent + "br label %" + label_cond + "\n");

    c.output_file.write("\n" + label_end + ":\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_close_bracket, i32 0, i32 0), i32 1)\n");
}

func compile_print_array_internal(c -> Compiler, arr_reg -> String, type_id -> Int, arr_info -> ArrayInfo, pos -> Position) -> Void {
    let hook_raw_str -> String = get_mangled_symbol(c, "print_bytes", pos);
    let elem_type -> Int = arr_info.base_type;
    let elem_ty_str -> String = get_llvm_type_str(c, elem_type);

    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_open_bracket, i32 0, i32 0), i32 1)\n");

    let size_val -> String = next_reg(c);
    let slice_parts -> SliceParts = null;
    if (arr_info.size == -1) {
        slice_parts = emit_slice_parts(c, arr_reg, type_id, pos);
        let slice_length -> String = emit_size_to_int(c, slice_parts.length);
        c.output_file.write(c.indent + size_val + " = add i32 0, " + slice_length + "\n");
    } else {
        c.output_file.write(c.indent + size_val + " = add i32 0, " + arr_info.size + "\n");
    }

    let data_ptr -> String = "";
    if (arr_info.size == -1) {
        data_ptr = next_reg(c);
        c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + slice_parts.data + ", " + get_size_llvm_type() + " " + slice_parts.start + "\n");
    } else {
        data_ptr = next_reg(c);
        c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + arr_reg + ", i32 0, i32 0\n");
    }

    let label_cond -> String = next_label(c);
    let label_body -> String = next_label(c);
    let label_sep  -> String = next_label(c);
    let label_end  -> String = next_label(c);

    let idx_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + idx_ptr + " = alloca i32\n");
    c.output_file.write(c.indent + "store i32 0, i32* " + idx_ptr + "\n");
    c.output_file.write(c.indent + "br label %" + label_cond + "\n");

    c.output_file.write("\n" + label_cond + ":\n");
    let curr_idx -> String = next_reg(c);
    c.output_file.write(c.indent + curr_idx + " = load i32, i32* " + idx_ptr + "\n");
    let cmp -> String = next_reg(c);

    c.output_file.write(c.indent + cmp + " = icmp slt i32 " + curr_idx + ", " + size_val + "\n");
    c.output_file.write(c.indent + "br i1 " + cmp + ", label %" + label_body + ", label %" + label_end + "\n");

    c.output_file.write("\n" + label_body + ":\n");
    let slot_ptr -> String = next_reg(c);

    c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", i32 " + curr_idx + "\n");
    
    let val_reg -> String = "";
    if (c.array_info_map.get("" + elem_type) is !null) {
        val_reg = slot_ptr;
    } else {
        val_reg = next_reg(c);
        c.output_file.write(c.indent + val_reg + " = load " + elem_ty_str + ", " + elem_ty_str + "* " + slot_ptr + "\n");
    }
    
    compile_print(c, val_reg, elem_type, pos, elem_type);

    let next_idx -> String = next_reg(c);
    c.output_file.write(c.indent + next_idx + " = add i32 " + curr_idx + ", 1\n");
    c.output_file.write(c.indent + "store i32 " + next_idx + ", i32* " + idx_ptr + "\n");
    
    let is_not_last -> String = next_reg(c);
    c.output_file.write(c.indent + is_not_last + " = icmp slt i32 " + next_idx + ", " + size_val + "\n");
    c.output_file.write(c.indent + "br i1 " + is_not_last + ", label %" + label_sep + ", label %" + label_cond + "\n");

    c.output_file.write("\n" + label_sep + ":\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([3 x i8], [3 x i8]* @.str_comma_space, i32 0, i32 0), i32 2)\n");
    c.output_file.write(c.indent + "br label %" + label_cond + "\n");

    c.output_file.write("\n" + label_end + ":\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([2 x i8], [2 x i8]* @.str_close_bracket, i32 0, i32 0), i32 1)\n");
}

func compile_print_variant_internal(c -> Compiler, variant_reg -> String, v_info -> StructInfo, pos -> Position) -> Void {
    let hook_raw_str -> String = get_mangled_symbol(c, "print_bytes", pos);
    let variant_llvm -> String = v_info.llvm_name;

    let is_null -> String = next_reg(c);
    c.output_file.write(c.indent + is_null + " = icmp eq " + variant_llvm + "* " + variant_reg + ", null\n");
    let label_null_print -> String = "var_null_print_" + c.type_counter;
    let label_not_null -> String = "var_not_null_" + c.type_counter;
    let label_end -> String = "var_end_" + c.type_counter;
    c.type_counter += 1;

    c.output_file.write(c.indent + "br i1 " + is_null + ", label %" + label_null_print + ", label %" + label_not_null + "\n");

    c.output_file.write("\n" + label_null_print + ":\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([5 x i8], [5 x i8]* @.str_null, i32 0, i32 0), i32 4)\n");
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_not_null + ":\n");

    let type_id_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + type_id_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + variant_reg + ", i32 0, i32 0\n");
    let type_id_reg -> String = next_reg(c);
    c.output_file.write(c.indent + type_id_reg + " = load i64, i64* " + type_id_ptr + "\n");

    let payload_low_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + payload_low_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + variant_reg + ", i32 0, i32 1\n");
    let payload_low -> String = next_reg(c);
    c.output_file.write(c.indent + payload_low + " = load i64, i64* " + payload_low_ptr + "\n");
    let payload_high_ptr -> String = next_reg(c);
    c.output_file.write(c.indent + payload_high_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + variant_reg + ", i32 0, i32 2\n");
    let payload_high -> String = next_reg(c);
    c.output_file.write(c.indent + payload_high + " = load i64, i64* " + payload_high_ptr + "\n");

    let label_null -> String = "var_null_" + c.type_counter;
    let label_int -> String = "var_int_" + c.type_counter;
    let label_long -> String = "var_long_" + c.type_counter;
    let label_float -> String = "var_float_" + c.type_counter;
    let label_bool -> String = "var_bool_" + c.type_counter;
    let label_string -> String = "var_string_" + c.type_counter;
    let label_char -> String = "var_char_" + c.type_counter;
    let label_int128 -> String = "var_int128_" + c.type_counter;
    let label_uint128 -> String = "var_uint128_" + c.type_counter;
    let label_default -> String = "var_default_" + c.type_counter;
    c.type_counter += 1;

    c.output_file.write(c.indent + "switch i64 " + type_id_reg + ", label %" + label_default + " [\n");
    c.output_file.write("    i64 0, label %" + label_null + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_INT) + ", label %" + label_int + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_LONG) + ", label %" + label_long + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_FLOAT) + ", label %" + label_float + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_BOOL) + ", label %" + label_bool + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_STRING) + ", label %" + label_string + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_CHAR) + ", label %" + label_char + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_INT128) + ", label %" + label_int128 + "\n");
    c.output_file.write("    i64 " + type_fingerprint(c, TYPE_UINT128) + ", label %" + label_uint128 + "\n");
    c.output_file.write("  ]\n");

    // null
    c.output_file.write("\n" + label_null + ":\n");
    c.output_file.write(c.indent + "call void @" + hook_raw_str + "(i8* getelementptr inbounds ([5 x i8], [5 x i8]* @.str_null, i32 0, i32 0), i32 4)\n");
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    // Int
    c.output_file.write("\n" + label_int + ":\n");
    let unboxed_int -> String = next_reg(c);
    c.output_file.write(c.indent + unboxed_int + " = trunc i64 " + payload_low + " to i32\n");
    compile_print(c, unboxed_int, TYPE_INT, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    // Long
    c.output_file.write("\n" + label_long + ":\n");
    compile_print(c, payload_low, TYPE_LONG, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    // Float
    c.output_file.write("\n" + label_float + ":\n");
    let unboxed_float -> String = next_reg(c);
    c.output_file.write(c.indent + unboxed_float + " = bitcast i64 " + payload_low + " to double\n");
    compile_print(c, unboxed_float, TYPE_FLOAT, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");
    
    // Bool
    c.output_file.write("\n" + label_bool + ":\n");
    let unboxed_bool -> String = next_reg(c);
    c.output_file.write(c.indent + unboxed_bool + " = trunc i64 " + payload_low + " to i1\n");
    compile_print(c, unboxed_bool, TYPE_BOOL, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    // String
    c.output_file.write("\n" + label_string + ":\n");
    let unboxed_str -> String = next_reg(c);
    c.output_file.write(c.indent + unboxed_str + " = inttoptr i64 " + payload_low + " to %struct.$String*\n");
    compile_print(c, unboxed_str, TYPE_STRING, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    // Char
    c.output_file.write("\n" + label_char + ":\n");
    let unboxed_char -> String = next_reg(c);
    c.output_file.write(c.indent + unboxed_char + " = trunc i64 " + payload_low + " to i32\n");
    compile_print(c, unboxed_char, TYPE_CHAR, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_int128 + ":\n");
    let unboxed_int128 -> String = combine_i128_words(c, payload_low, payload_high);
    compile_print(c, unboxed_int128, TYPE_INT128, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_uint128 + ":\n");
    let unboxed_uint128 -> String = combine_i128_words(c, payload_low, payload_high);
    compile_print(c, unboxed_uint128, TYPE_UINT128, pos, 0);
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    // other object
    c.output_file.write("\n" + label_default + ":\n");
    let hook_long -> String = get_mangled_symbol(c, "print_long", pos);
    c.output_file.write(c.indent + "call void @" + hook_long + "(i64 " + payload_low + ")\n");
    c.output_file.write(c.indent + "br label %" + label_end + "\n");

    c.output_file.write("\n" + label_end + ":\n");
}

func compile_string_method_call(c -> Compiler, obj_node -> Struct, method_name -> String, call_node -> CallNode) -> CompileResult {
    // check if method exists before compiling obj_node to avoid double compile
    let target_func -> String = "string_" + method_name;
    let real_func_name -> String = c.compiler_link.get(target_func);

    if (real_func_name is null) {
        return null;
    }

    let f_info -> FuncInfo = c.func_table.get(real_func_name);
    if (f_info is null) {
        throw_internal_compiler_error(call_node.pos, "Missing function metadata for CompilerLink '" + target_func + "'.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    if (!validate_fallible_call(c, f_info.ret_type, call_node.preserve_fallible, method_name, call_node.pos)) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let obj_res -> CompileResult = compile_node(c, obj_node);

    // WhiteLang methods receive the string object, native adapters receive its buffer
    let args_str -> String = "%struct.$String* " + obj_res.reg;
    let args -> Vector(Struct) = call_node.args;
    let a_len -> Int = 0;
    if (args is !null) { a_len = args.length(); }
    args = bind_call_args(args, f_info.arg_names, 1, call_node.pos);
    if (args is null) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let a_idx -> Int = 0;
    let owned_args -> Vector(Struct) = [];
    
    while (a_idx < a_len) {
        args_str = args_str + ", ";
        let curr_arg -> ArgNode = args[a_idx];
        let expected_node -> TypeListNode = f_info.arg_types[a_idx + 1];
        c.expected_type = expected_node.type;
        let arg_res -> CompileResult = compile_node(c, curr_arg.val);
        c.expected_type = 0;
        arg_res = emit_implicit_cast(c, arg_res, expected_node.type, call_node.pos);
        
        args_str = args_str + get_llvm_type_str(c, arg_res.type) + " " + arg_res.reg;
        if (arg_res.owns_ref) { owned_args.append(arg_res); }
        a_idx += 1;
    }

    let ret_ty_str -> String = get_llvm_type_str(c, f_info.ret_type);
    let call_reg -> String = "";
    if (f_info.ret_type == TYPE_VOID) {
        c.output_file.write(c.indent + "call void @" + f_info.name + "(" + args_str + ")\n");
        emit_release_owned_args(c, owned_args);
        emit_release_owned(c, obj_res);
        return void_result();
    } else {
        call_reg = next_reg(c);
        c.output_file.write(c.indent + call_reg + " = call " + ret_ty_str + " @" + f_info.name + "(" + args_str + ")\n");
        emit_release_owned_args(c, owned_args);
        emit_release_owned(c, obj_res);
        return CompileResult(reg=call_reg, type=f_info.ret_type, owns_ref=result_owns_value(c, f_info.ret_type));
    }
}
// --------------

func compile_start(c -> Compiler) -> Void {

    c.output_file.write("target triple = \"" + get_target_triple() + "\"\n\n");
    c.output_file.write("declare void @llvm.trap()\n\n");

    c.output_file.write("@.fmt_int = private unnamed_addr constant [4 x i8] c\"%d\\0A\\00\"\n");
    c.output_file.write("@.fmt_long = private unnamed_addr constant [6 x i8] c\"%lld\\0A\\00\"\n");
    c.output_file.write("@.fmt_float = private unnamed_addr constant [4 x i8] c\"%f\\0A\\00\"\n");
    c.output_file.write("@.fmt_str = private unnamed_addr constant [4 x i8] c\"%s\\0A\\00\"\n\n");
    c.output_file.write("@.fmt_char = private unnamed_addr constant [3 x i8] c\"%c\\00\"\n");
    c.output_file.write("@.fmt_hex_ptr = private unnamed_addr constant [3 x i8] c\"%p\\00\"\n");

    c.output_file.write("@.str_true = private unnamed_addr constant [5 x i8] c\"true\\00\"\n");
    c.output_file.write("@.str_false = private unnamed_addr constant [6 x i8] c\"false\\00\"\n");
    c.output_file.write("@.str_null = private unnamed_addr constant [5 x i8] c\"null\\00\"\n\n");
    c.output_file.write("@.str_newline = private unnamed_addr constant [2 x i8] c\"\\0A\\00\"\n");

    c.output_file.write("@.str_idx_err = private unnamed_addr constant [21 x i8] c\"Index out of bounds\\0A\\00\"\n\n");
    c.output_file.write("@.fmt_err_bounds = private unnamed_addr constant [66 x i8] c\"\\0ARuntimeError\\1B[0m: Index out of bounds\\0A    at Line %d, Column %d\\0A\\00\"\n\n");

    // print
    c.output_file.write("@.str_open_bracket = private unnamed_addr constant [2 x i8] c\"[\\00\"\n");
    c.output_file.write("@.str_close_bracket = private unnamed_addr constant [2 x i8] c\"]\\00\"\n");
    c.output_file.write("@.str_comma_space = private unnamed_addr constant [3 x i8] c\", \\00\"\n");
    c.output_file.write("@.str_open_paren = private unnamed_addr constant [2 x i8] c\"(\\00\"\n");
    c.output_file.write("@.str_close_paren = private unnamed_addr constant [2 x i8] c\")\\00\"\n");
    c.output_file.write("@.str_equal = private unnamed_addr constant [2 x i8] c\"=\\00\"\n");

    // for dict.wl
    let variant_id -> Int = c.type_counter;
    c.type_counter += 1;
    let v_fields -> Vector(Struct) = [];
    v_fields.append(FieldInfo(name="type_id", type=TYPE_UINT64, llvm_type="i64", offset=0));
    v_fields.append(FieldInfo(name="payload_low", type=TYPE_LONG, llvm_type="i64", offset=1));
    v_fields.append(FieldInfo(name="payload_high", type=TYPE_LONG, llvm_type="i64", offset=2));

    let variant_info -> StructInfo = StructInfo(
        name="$Variant", 
        type_id=variant_id, 
        fields=v_fields, 
        llvm_name="%struct.$Variant", 
        init_body=null, 
        is_class=false, 
        vtable_name="", 
        parent_id=0, 
        vtable=null, 
        ann_flags=FLAG_ANN_INTRINSIC,
        compiler_link_name="",
        is_enum=false,
        is_error=false,
        is_interface=false,
        interfaces=null
    );
    c.struct_table.put("$Variant", variant_info);
    c.struct_id_map.put("" + variant_id, variant_info);
    
    let string_info -> StructInfo = StructInfo(
        name="String", 
        type_id=TYPE_STRING, 
        fields=null, 
        llvm_name="%struct.$String", 
        init_body=null, is_class=false, 
        vtable_name="", 
        parent_id=0, 
        vtable=null, 
        ann_flags=FLAG_ANN_INTRINSIC,
        compiler_link_name="",
        is_enum=false,
        is_error=false,
        is_interface=false,
        interfaces=null
    );
    c.struct_table.put("String", string_info);
    c.struct_id_map.put("" + TYPE_STRING, string_info);

    c.output_file.write("; ====== COMPILER INTRINSICS ======\n");
    c.output_file.write("%struct.$Variant = type { i64, i64, i64 }\n");
    c.output_file.write("%struct.$String = type { i8*, i32, i32 }\n\n");
}

func compile(c -> Compiler, node -> Struct) -> Void {
    compile_start(c);

    let fake_path -> Token = Token(type=TOK_STR_LIT, value="dict", line=0, col=0);
    let fake_pos -> Position = Position(idx=0, ln=0, col=0, text="", fn="<prelude>");
    let star_tok -> Token = Token(type=TOK_MUL, value="*", line=0, col=0);
    let star_sym -> ImportSymbolNode = ImportSymbolNode(name_tok=star_tok, alias_tok=null);
    let fake_syms -> Vector(Struct) = [];
    fake_syms.append(star_sym);

    // error is a language-level prelude item, not part of the builtin namespace
    let fake_error_path -> Token = Token(type=TOK_STR_LIT, value="errors", line=0, col=0);
    let fake_error_import -> ImportNode = ImportNode(type=NODE_IMPORT, path_tok=fake_error_path, symbols=fake_syms, alias_tok=null, pos=fake_pos);
    compile_import(c, fake_error_import);

    // builtin is the prelude and carries the hooks required by generated code
    let fake_builtin_path -> Token = Token(type=TOK_STR_LIT, value="builtin", line=0, col=0);
    let fake_builtin_import -> ImportNode = ImportNode(type=NODE_IMPORT, path_tok=fake_builtin_path, symbols=fake_syms, alias_tok=null, pos=fake_pos);
    compile_import(c, fake_builtin_import);

    let fake_import -> ImportNode = ImportNode(type=NODE_IMPORT, path_tok=fake_path, symbols=fake_syms, alias_tok=null, pos=fake_pos);
    compile_import(c, fake_import);

    if (c.struct_table.get("dict.Variant") is null) {
        throw_import_error(fake_pos, "Missing required intrinsic item '@CompilerIntrinsic struct Variant'. The standard library 'dict.wl' may be corrupted or missing.");
        return;
    }

    precompile_ast(c, node, "<main>", "", c.current_dir);

    let mod_i -> Int = 0;
    while (mod_i < c.all_modules.length()) {
        let p_mod -> ParsedModule = c.all_modules[mod_i];
        c.current_file_visible_prefixes = p_mod.visible;
        c.current_file_namespaces       = p_mod.namespaces;
        c.current_file_type_aliases     = p_mod.types;
        c.current_file_func_aliases     = p_mod.funcs;
        c.current_file_global_aliases   = p_mod.globals;
        c.current_package_prefix        = p_mod.prefix;
        c.current_module_is_package     = p_mod.is_package;
        c.current_dir                   = p_mod.dir;
        bind_module_prelude(c, Position(idx=0, ln=0, col=0, text="", fn=p_mod.path));
        mod_i += 1;
    }

    c.is_precompile_phase = false;

    mod_i = 0;
    while (mod_i < c.all_modules.length()) {
        let p_mod -> ParsedModule = c.all_modules[mod_i];
        compile_ast_pass(c, p_mod);
        mod_i += 1;
    }
    emit_pending_generics(c);
    compile_end(c);
}

func emit_freestanding_memops(c -> Compiler) -> Void {
    let size_ty -> String = get_size_llvm_type();
    c.output_file.write("define i8* @memcpy(i8* %dest, i8* %src, " + size_ty + " %count) noinline optnone {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  br label %copy.cond\n\n");
    c.output_file.write("copy.cond:\n");
    c.output_file.write("  %index = phi " + size_ty + " [ 0, %entry ], [ %next, %copy.body ]\n");
    c.output_file.write("  %done = icmp uge " + size_ty + " %index, %count\n");
    c.output_file.write("  br i1 %done, label %copy.end, label %copy.body\n\n");
    c.output_file.write("copy.body:\n");
    c.output_file.write("  %source = getelementptr i8, i8* %src, " + size_ty + " %index\n");
    c.output_file.write("  %byte = load volatile i8, i8* %source\n");
    c.output_file.write("  %target = getelementptr i8, i8* %dest, " + size_ty + " %index\n");
    c.output_file.write("  store volatile i8 %byte, i8* %target\n");
    c.output_file.write("  %next = add " + size_ty + " %index, 1\n");
    c.output_file.write("  br label %copy.cond\n\n");
    c.output_file.write("copy.end:\n");
    c.output_file.write("  ret i8* %dest\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define i8* @memmove(i8* %dest, i8* %src, " + size_ty + " %count) noinline optnone {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %same = icmp eq i8* %dest, %src\n");
    c.output_file.write("  %empty = icmp eq " + size_ty + " %count, 0\n");
    c.output_file.write("  %trivial = or i1 %same, %empty\n");
    c.output_file.write("  br i1 %trivial, label %move.end, label %move.direction\n\n");
    c.output_file.write("move.direction:\n");
    c.output_file.write("  %dest.addr = ptrtoint i8* %dest to " + size_ty + "\n");
    c.output_file.write("  %src.addr = ptrtoint i8* %src to " + size_ty + "\n");
    c.output_file.write("  %before = icmp ult " + size_ty + " %dest.addr, %src.addr\n");
    c.output_file.write("  %distance = sub " + size_ty + " %dest.addr, %src.addr\n");
    c.output_file.write("  %separate = icmp uge " + size_ty + " %distance, %count\n");
    c.output_file.write("  %forward = or i1 %before, %separate\n");
    c.output_file.write("  br i1 %forward, label %forward.cond, label %backward.cond\n\n");
    c.output_file.write("forward.cond:\n");
    c.output_file.write("  %forward.index = phi " + size_ty + " [ 0, %move.direction ], [ %forward.next, %forward.body ]\n");
    c.output_file.write("  %forward.done = icmp uge " + size_ty + " %forward.index, %count\n");
    c.output_file.write("  br i1 %forward.done, label %move.end, label %forward.body\n\n");
    c.output_file.write("forward.body:\n");
    c.output_file.write("  %forward.src = getelementptr i8, i8* %src, " + size_ty + " %forward.index\n");
    c.output_file.write("  %forward.byte = load volatile i8, i8* %forward.src\n");
    c.output_file.write("  %forward.dest = getelementptr i8, i8* %dest, " + size_ty + " %forward.index\n");
    c.output_file.write("  store volatile i8 %forward.byte, i8* %forward.dest\n");
    c.output_file.write("  %forward.next = add " + size_ty + " %forward.index, 1\n");
    c.output_file.write("  br label %forward.cond\n\n");
    c.output_file.write("backward.cond:\n");
    c.output_file.write("  %remaining = phi " + size_ty + " [ %count, %move.direction ], [ %backward.index, %backward.body ]\n");
    c.output_file.write("  %backward.done = icmp eq " + size_ty + " %remaining, 0\n");
    c.output_file.write("  br i1 %backward.done, label %move.end, label %backward.body\n\n");
    c.output_file.write("backward.body:\n");
    c.output_file.write("  %backward.index = sub " + size_ty + " %remaining, 1\n");
    c.output_file.write("  %backward.src = getelementptr i8, i8* %src, " + size_ty + " %backward.index\n");
    c.output_file.write("  %backward.byte = load volatile i8, i8* %backward.src\n");
    c.output_file.write("  %backward.dest = getelementptr i8, i8* %dest, " + size_ty + " %backward.index\n");
    c.output_file.write("  store volatile i8 %backward.byte, i8* %backward.dest\n");
    c.output_file.write("  br label %backward.cond\n\n");
    c.output_file.write("move.end:\n");
    c.output_file.write("  ret i8* %dest\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define i8* @memset(i8* %dest, i32 %value, " + size_ty + " %count) noinline optnone {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %byte = trunc i32 %value to i8\n");
    c.output_file.write("  br label %set.cond\n\n");
    c.output_file.write("set.cond:\n");
    c.output_file.write("  %index = phi " + size_ty + " [ 0, %entry ], [ %next, %set.body ]\n");
    c.output_file.write("  %done = icmp uge " + size_ty + " %index, %count\n");
    c.output_file.write("  br i1 %done, label %set.end, label %set.body\n\n");
    c.output_file.write("set.body:\n");
    c.output_file.write("  %target = getelementptr i8, i8* %dest, " + size_ty + " %index\n");
    c.output_file.write("  store volatile i8 %byte, i8* %target\n");
    c.output_file.write("  %next = add " + size_ty + " %index, 1\n");
    c.output_file.write("  br label %set.cond\n\n");
    c.output_file.write("set.end:\n");
    c.output_file.write("  ret i8* %dest\n");
    c.output_file.write("}\n\n");
}

func emit_windows_x86_division_builtins(c -> Compiler) -> Void {
    // llvm lowers 64-bit division to these msvc helper symbols on x86
    c.output_file.write("define internal void @__wl_udivrem64(i64 %dividend, i64 %divisor, i64* %quotient.out, i64* %remainder.out) noinline {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %zero = icmp eq i64 %divisor, 0\n");
    c.output_file.write("  br i1 %zero, label %divide.zero, label %check.range\n\n");
    c.output_file.write("divide.zero:\n");
    c.output_file.write("  call void @llvm.trap()\n");
    c.output_file.write("  unreachable\n\n");
    c.output_file.write("check.range:\n");
    c.output_file.write("  %less = icmp ult i64 %dividend, %divisor\n");
    c.output_file.write("  br i1 %less, label %less.than.divisor, label %check.narrow\n\n");
    c.output_file.write("less.than.divisor:\n");
    c.output_file.write("  store i64 0, i64* %quotient.out\n");
    c.output_file.write("  store i64 %dividend, i64* %remainder.out\n");
    c.output_file.write("  ret void\n\n");
    c.output_file.write("check.narrow:\n");
    c.output_file.write("  %dividend.high = lshr i64 %dividend, 32\n");
    c.output_file.write("  %divisor.high = lshr i64 %divisor, 32\n");
    c.output_file.write("  %high.bits = or i64 %dividend.high, %divisor.high\n");
    c.output_file.write("  %narrow = icmp eq i64 %high.bits, 0\n");
    c.output_file.write("  br i1 %narrow, label %divide.narrow, label %loop\n\n");
    c.output_file.write("divide.narrow:\n");
    c.output_file.write("  %dividend.low = trunc i64 %dividend to i32\n");
    c.output_file.write("  %divisor.low = trunc i64 %divisor to i32\n");
    c.output_file.write("  %quotient.low = udiv i32 %dividend.low, %divisor.low\n");
    c.output_file.write("  %remainder.low = urem i32 %dividend.low, %divisor.low\n");
    c.output_file.write("  %quotient.wide = zext i32 %quotient.low to i64\n");
    c.output_file.write("  %remainder.wide = zext i32 %remainder.low to i64\n");
    c.output_file.write("  store i64 %quotient.wide, i64* %quotient.out\n");
    c.output_file.write("  store i64 %remainder.wide, i64* %remainder.out\n");
    c.output_file.write("  ret void\n\n");
    c.output_file.write("loop:\n");
    c.output_file.write("  %index = phi i32 [ 64, %check.narrow ], [ %next.index, %body ]\n");
    c.output_file.write("  %quotient = phi i64 [ 0, %check.narrow ], [ %next.quotient, %body ]\n");
    c.output_file.write("  %remainder = phi i64 [ 0, %check.narrow ], [ %next.remainder, %body ]\n");
    c.output_file.write("  %done = icmp eq i32 %index, 0\n");
    c.output_file.write("  br i1 %done, label %finish, label %body\n\n");
    c.output_file.write("body:\n");
    c.output_file.write("  %next.index = sub i32 %index, 1\n");
    c.output_file.write("  %shift = zext i32 %next.index to i64\n");
    c.output_file.write("  %shifted.dividend = lshr i64 %dividend, %shift\n");
    c.output_file.write("  %bit = and i64 %shifted.dividend, 1\n");
    c.output_file.write("  %shifted.remainder = shl i64 %remainder, 1\n");
    c.output_file.write("  %candidate = or i64 %shifted.remainder, %bit\n");
    c.output_file.write("  %fits = icmp uge i64 %candidate, %divisor\n");
    c.output_file.write("  %reduced = sub i64 %candidate, %divisor\n");
    c.output_file.write("  %next.remainder = select i1 %fits, i64 %reduced, i64 %candidate\n");
    c.output_file.write("  %quotient.bit = shl i64 1, %shift\n");
    c.output_file.write("  %with.bit = or i64 %quotient, %quotient.bit\n");
    c.output_file.write("  %next.quotient = select i1 %fits, i64 %with.bit, i64 %quotient\n");
    c.output_file.write("  br label %loop\n\n");
    c.output_file.write("finish:\n");
    c.output_file.write("  store i64 %quotient, i64* %quotient.out\n");
    c.output_file.write("  store i64 %remainder, i64* %remainder.out\n");
    c.output_file.write("  ret void\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define x86_stdcallcc i64 @\"\\01__aulldiv\"(i64 %dividend, i64 %divisor) noinline {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %quotient = alloca i64\n");
    c.output_file.write("  %remainder = alloca i64\n");
    c.output_file.write("  call void @__wl_udivrem64(i64 %dividend, i64 %divisor, i64* %quotient, i64* %remainder)\n");
    c.output_file.write("  %result = load i64, i64* %quotient\n");
    c.output_file.write("  ret i64 %result\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define x86_stdcallcc i64 @\"\\01__aullrem\"(i64 %dividend, i64 %divisor) noinline {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %quotient = alloca i64\n");
    c.output_file.write("  %remainder = alloca i64\n");
    c.output_file.write("  call void @__wl_udivrem64(i64 %dividend, i64 %divisor, i64* %quotient, i64* %remainder)\n");
    c.output_file.write("  %result = load i64, i64* %remainder\n");
    c.output_file.write("  ret i64 %result\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define x86_stdcallcc i64 @\"\\01__alldiv\"(i64 %dividend, i64 %divisor) noinline {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %dividend.negative = icmp slt i64 %dividend, 0\n");
    c.output_file.write("  %divisor.negative = icmp slt i64 %divisor, 0\n");
    c.output_file.write("  %negative.dividend = sub i64 0, %dividend\n");
    c.output_file.write("  %negative.divisor = sub i64 0, %divisor\n");
    c.output_file.write("  %magnitude.dividend = select i1 %dividend.negative, i64 %negative.dividend, i64 %dividend\n");
    c.output_file.write("  %magnitude.divisor = select i1 %divisor.negative, i64 %negative.divisor, i64 %divisor\n");
    c.output_file.write("  %quotient = alloca i64\n");
    c.output_file.write("  %remainder = alloca i64\n");
    c.output_file.write("  call void @__wl_udivrem64(i64 %magnitude.dividend, i64 %magnitude.divisor, i64* %quotient, i64* %remainder)\n");
    c.output_file.write("  %magnitude = load i64, i64* %quotient\n");
    c.output_file.write("  %negative = xor i1 %dividend.negative, %divisor.negative\n");
    c.output_file.write("  %negative.result = sub i64 0, %magnitude\n");
    c.output_file.write("  %result = select i1 %negative, i64 %negative.result, i64 %magnitude\n");
    c.output_file.write("  ret i64 %result\n");
    c.output_file.write("}\n\n");

    c.output_file.write("define x86_stdcallcc i64 @\"\\01__allrem\"(i64 %dividend, i64 %divisor) noinline {\n");
    c.output_file.write("entry:\n");
    c.output_file.write("  %dividend.negative = icmp slt i64 %dividend, 0\n");
    c.output_file.write("  %divisor.negative = icmp slt i64 %divisor, 0\n");
    c.output_file.write("  %negative.dividend = sub i64 0, %dividend\n");
    c.output_file.write("  %negative.divisor = sub i64 0, %divisor\n");
    c.output_file.write("  %magnitude.dividend = select i1 %dividend.negative, i64 %negative.dividend, i64 %dividend\n");
    c.output_file.write("  %magnitude.divisor = select i1 %divisor.negative, i64 %negative.divisor, i64 %divisor\n");
    c.output_file.write("  %quotient = alloca i64\n");
    c.output_file.write("  %remainder = alloca i64\n");
    c.output_file.write("  call void @__wl_udivrem64(i64 %magnitude.dividend, i64 %magnitude.divisor, i64* %quotient, i64* %remainder)\n");
    c.output_file.write("  %magnitude = load i64, i64* %remainder\n");
    c.output_file.write("  %negative.result = sub i64 0, %magnitude\n");
    c.output_file.write("  %result = select i1 %dividend.negative, i64 %negative.result, i64 %magnitude\n");
    c.output_file.write("  ret i64 %result\n");
    c.output_file.write("}\n\n");
}

func emit_windows_x86_stack_probe(c -> Compiler) -> Void {
    // x86 __chkstk probes the guard pages and returns on the allocated stack
    c.output_file.write("module asm \".text\"\n");
    c.output_file.write("module asm \".p2align 4, 0x90\"\n");
    c.output_file.write("module asm \".globl __chkstk\"\n");
    c.output_file.write("module asm \"__chkstk:\"\n");
    c.output_file.write("module asm \"pushl %ecx\"\n");
    c.output_file.write("module asm \"leal 8(%esp), %ecx\"\n");
    c.output_file.write("module asm \"cmpl $0x1000, %eax\"\n");
    c.output_file.write("module asm \"jb 2f\"\n");
    c.output_file.write("module asm \"1:\"\n");
    c.output_file.write("module asm \"subl $0x1000, %ecx\"\n");
    c.output_file.write("module asm \"testb $0, (%ecx)\"\n");
    c.output_file.write("module asm \"subl $0x1000, %eax\"\n");
    c.output_file.write("module asm \"cmpl $0x1000, %eax\"\n");
    c.output_file.write("module asm \"ja 1b\"\n");
    c.output_file.write("module asm \"2:\"\n");
    c.output_file.write("module asm \"subl %eax, %ecx\"\n");
    c.output_file.write("module asm \"testb $0, (%ecx)\"\n");
    c.output_file.write("module asm \"movl %esp, %eax\"\n");
    c.output_file.write("module asm \"movl %ecx, %esp\"\n");
    c.output_file.write("module asm \"movl (%eax), %ecx\"\n");
    c.output_file.write("module asm \"movl 4(%eax), %eax\"\n");
    c.output_file.write("module asm \"pushl %eax\"\n");
    c.output_file.write("module asm \"retl\"\n\n");
}

func emit_windows_x64_stack_probe(c -> Compiler) -> Void {
    // x64 callers adjust rsp after the probe returns
    c.output_file.write("module asm \".text\"\n");
    c.output_file.write("module asm \".p2align 4, 0x90\"\n");
    c.output_file.write("module asm \".globl __chkstk\"\n");
    c.output_file.write("module asm \".globl ___chkstk_ms\"\n");
    c.output_file.write("module asm \"__chkstk:\"\n");
    c.output_file.write("module asm \"___chkstk_ms:\"\n");
    c.output_file.write("module asm \"pushq %rcx\"\n");
    c.output_file.write("module asm \"pushq %rax\"\n");
    c.output_file.write("module asm \"cmpq $0x1000, %rax\"\n");
    c.output_file.write("module asm \"leaq 24(%rsp), %rcx\"\n");
    c.output_file.write("module asm \"jb 2f\"\n");
    c.output_file.write("module asm \"1:\"\n");
    c.output_file.write("module asm \"subq $0x1000, %rcx\"\n");
    c.output_file.write("module asm \"testb $0, (%rcx)\"\n");
    c.output_file.write("module asm \"subq $0x1000, %rax\"\n");
    c.output_file.write("module asm \"cmpq $0x1000, %rax\"\n");
    c.output_file.write("module asm \"ja 1b\"\n");
    c.output_file.write("module asm \"2:\"\n");
    c.output_file.write("module asm \"subq %rax, %rcx\"\n");
    c.output_file.write("module asm \"testb $0, (%rcx)\"\n");
    c.output_file.write("module asm \"popq %rax\"\n");
    c.output_file.write("module asm \"popq %rcx\"\n");
    c.output_file.write("module asm \"retq\"\n\n");
}

func emit_windows_stack_probe(c -> Compiler) -> Void {
    // keep target assembly private to the Windows backend until structured asm is available
    if (get_target_arch() == sys.Arch.X86) { emit_windows_x86_stack_probe(c); }
    else if (get_target_arch() == sys.Arch.X86_64) { emit_windows_x64_stack_probe(c); }
}

func emit_windows_abi(c -> Compiler) -> Void {
    if (get_target_os() != sys.Os.Windows) { return; }
    c.output_file.write("@_fltused = global i32 39029\n\n");
    c.output_file.write("define void @__main() {\nentry:\n  ret void\n}\n\n");
    emit_freestanding_memops(c);
    if (get_target_arch() == sys.Arch.X86) { emit_windows_x86_division_builtins(c); }
    emit_windows_stack_probe(c);
}

func emit_windows_entrypoint(c -> Compiler) -> Void {
    if (get_target_os() != sys.Os.Windows) { return; }
    if (c.is_shared) {
        let callconv -> String = "";
        if (get_target_arch() == sys.Arch.X86) { callconv = "x86_stdcallcc "; }
        c.output_file.write("define " + callconv + "i32 @DllMainCRTStartup(i8* %instance, i32 %reason, i8* %reserved) {\n");
        c.output_file.write("entry:\n");
        c.output_file.write("  ret i32 1\n");
        c.output_file.write("}\n\n");
        return;
    }

    let main_info -> FuncInfo = c.func_table.get("main");
    let exit_key -> String = c.compiler_link.get("process_exit");
    let exit_info -> FuncInfo = c.func_table.get(exit_key);
    if (main_info is null || exit_info is null) {
        throw_internal_compiler_error(null, "Missing compiler runtime hooks required by the native entry point.");
        return;
    }

    let argc -> Int = 0;
    if (main_info.arg_types is !null) { argc = main_info.arg_types.length(); }
    c.output_file.write("define void @mainCRTStartup() {\n");
    c.output_file.write("entry:\n");
    if (argc == 0) {
        c.output_file.write("  %status = call i32 @main()\n");
    } else {
        let args_key -> String = c.compiler_link.get("startup_args");
        let free_key -> String = c.compiler_link.get("startup_args_free");
        let args_info -> FuncInfo = c.func_table.get(args_key);
        let free_info -> FuncInfo = c.func_table.get(free_key);
        if (args_info is null || free_info is null) {
            throw_internal_compiler_error(null, "Missing compiler runtime hooks required by the Windows entry point.");
            return;
        }
        c.output_file.write("  %argc.addr = alloca i32\n");
        c.output_file.write("  store i32 0, i32* %argc.addr\n");
        c.output_file.write("  %argv.raw = call i8* @" + args_info.name + "(i32* %argc.addr)\n");
        c.output_file.write("  %argv.missing = icmp eq i8* %argv.raw, null\n");
        c.output_file.write("  br i1 %argv.missing, label %startup.failed, label %startup.ready\n\n");
        c.output_file.write("startup.failed:\n");
        c.output_file.write("  call void @" + exit_info.name + "(i32 127)\n");
        c.output_file.write("  unreachable\n\n");
        c.output_file.write("startup.ready:\n");
        c.output_file.write("  %argc = load i32, i32* %argc.addr\n");
        c.output_file.write("  %argv = bitcast i8* %argv.raw to %struct.$String**\n");
        c.output_file.write("  %status = call i32 @main(i32 %argc, %struct.$String** %argv)\n");
        c.output_file.write("  call void @" + free_info.name + "(i32 %argc, i8* %argv.raw)\n");
    }
    c.output_file.write("  call void @" + exit_info.name + "(i32 %status)\n");
    c.output_file.write("  unreachable\n");
    c.output_file.write("}\n\n");
}

func compile_end(c -> Compiler) -> Void {
    if (GLOBAL_ERROR_COUNT > 0) {
        c.output_file.close();
        return;
    }
    if (!c.has_main && !c.is_shared) {
        throw_missing_main_function();
        return;
    }
    compile_arc_hooks(c);
    emit_dict_key_helpers(c);
    emit_typed_dict_helpers(c);
    emit_erased_check_helpers(c);
    emit_windows_abi(c);
    emit_windows_entrypoint(c);

    let str_vec -> Vector(Struct) = c.string_list;
    let s_len -> Int = 0; if (str_vec is !null) { s_len = str_vec.length(); }
    let s_idx -> Int = 0;
    while (s_idx < s_len) {
        let curr -> StringConstant = str_vec[s_idx];
        let val -> String = curr.value;
        let escaped_val -> String = string_escape(val);
        let id -> Int = curr.id;
        let len -> Int = val.length() + 1;
        let real_len -> Int = len - 1; // excluding \0

        let bytes_def -> String = "@.str.bytes." + id + " = private unnamed_addr constant [" + len + " x i8] c\"" + escaped_val + "\\00\"\n";
        // use correct TYPE_STRING (5) instead of TYPE_GENERIC_CLASS (11)
        let struct_def -> String = "@.str." + id + " = private unnamed_addr constant { i32, i32, %struct.$String } { i32 -1, i32 5, %struct.$String { i8* getelementptr inbounds ([" + len + " x i8], [" + len + " x i8]* @.str.bytes." + id + ", i32 0, i32 0), i32 " + real_len + ", i32 " + real_len + " } }\n";

        c.output_file.write(bytes_def);
        c.output_file.write(struct_def);
        s_idx += 1;
    }

    c.output_file.write("; ====== Lambda Lifted Closures and Envs =====\n");
    c.output_file.write(c.global_buffer);
    c.output_file.write("\n");
    c.output_file.close();

    if (c.generic_type_defs.length() > 0) {
        let original -> file.File = file.open(c.output_file.path)?;
        catch(err) {
            throw_internal_compiler_error(null, "Cannot reopen generated LLVM IR while finalizing generic types.");
            return;
        }

        let body -> String = original.read_all()?;
        catch(err) {
            original.close();
            throw_internal_compiler_error(null, "Cannot read generated LLVM IR while finalizing generic types.");
            return;
        }
        original.close();

        let rewrite -> file.File = file.create(c.output_file.path)?;
        catch(err) {
            throw_internal_compiler_error(null, "Cannot rewrite generated LLVM IR while finalizing generic types.");
            return;
        }

        let line_end -> Int = 0;
        while (line_end < body.length() && body[line_end] != '\n') { line_end++; }
        if (line_end < body.length()) { line_end++; }
        rewrite.write(body.slice(0, line_end));
        rewrite.write(c.generic_type_defs);
        rewrite.write(body.slice(line_end, body.length()));
        rewrite.close();
    }
}

func emit_pending_generic_funcs(c -> Compiler) -> Void {
    let index -> Int = c.generic_func_emitted;
    while (index < c.generic_worklist.length()) {
        let instance -> GenericFuncInstance = c.generic_worklist[index];
        index++;
        c.generic_func_emitted = index;
        let template -> GenericTemplate = instance.template;
        let node -> FunctionDefNode = template.node;
        let previous_bindings -> Dict = c.generic_bindings;
        let previous -> GenericTemplate = use_generic_context(c, template, instance.bindings);
        let previous_key -> String = c.generic_func_key;
        let previous_depth -> Int = c.generic_depth;
        c.generic_func_key = instance.func_key;
        c.generic_depth = instance.depth;

        compile_func_def(c, node);

        c.generic_depth = previous_depth;
        c.generic_func_key = previous_key;
        restore_generic_context(c, previous, previous_bindings);
    }
}

func emit_pending_generic_classes(c -> Compiler) -> Void {
    let index -> Int = c.generic_class_emitted;
    while (index < c.generic_class_worklist.length()) {
        let instance -> GenericClassInstance = c.generic_class_worklist[index];
        index++;
        c.generic_class_emitted = index;
        let template -> GenericTemplate = instance.template;
        let node -> ClassDefNode = template.node;
        let previous_bindings -> Dict = c.generic_bindings;
        let previous -> GenericTemplate = use_generic_context(c, template, instance.bindings);
        let previous_type -> Int = c.generic_class_type;
        let previous_depth -> Int = c.generic_depth;
        c.generic_class_type = instance.type_id;
        c.generic_depth = instance.depth;

        compile_class_def(c, node);

        c.generic_depth = previous_depth;
        c.generic_class_type = previous_type;
        restore_generic_context(c, previous, previous_bindings);
    }
}

func emit_pending_generic_methods(c -> Compiler) -> Void {
    let index -> Int = c.generic_method_emitted;
    while (index < c.generic_method_worklist.length()) {
        let instance -> GenericMethodInstance = c.generic_method_worklist[index];
        index++;
        c.generic_method_emitted = index;
        let template -> GenericTemplate = instance.template;
        let node -> MethodDefNode = template.node;
        let previous_bindings -> Dict = c.generic_bindings;
        let previous -> GenericTemplate = use_generic_context(c, template, instance.bindings);
        let previous_key -> String = c.generic_method_key;
        let previous_depth -> Int = c.generic_depth;
        c.generic_method_key = instance.func_key;
        c.generic_depth = instance.depth;

        compile_method_def(c, instance.owner_name, node);

        c.generic_depth = previous_depth;
        c.generic_method_key = previous_key;
        restore_generic_context(c, previous, previous_bindings);
    }
}

func has_pending_generics(c -> Compiler) -> Bool {
    return c.generic_class_emitted < c.generic_class_worklist.length() || c.generic_func_emitted < c.generic_worklist.length() || c.generic_method_emitted < c.generic_method_worklist.length();
}

func emit_pending_generics(c -> Compiler) -> Void {
    while (has_pending_generics(c)) {
        emit_pending_generic_classes(c);
        emit_pending_generic_funcs(c);
        emit_pending_generic_methods(c);
    }
}
