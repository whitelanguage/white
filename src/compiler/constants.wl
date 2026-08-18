// compiler/constants.wl
import * from "../frontend/ast.wl"
import * from "context.wl"
import * from "../frontend/tokens.wl"
import * from "../frontend/diagnostics.wl"
import * from "lowering/numeric.wl"

func check_layout_type(c: Compiler, type_id: Int, is_align: Bool, pos: Position) -> Bool {
    let property: String = "size";
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

func eval_const_long(c: Compiler, node: Struct, pos: Position) -> Long {
    if (node is null) { return 0L; }
    let base: Int = node_kind(node);
    
    if (base == NODE_INT) {
        let n: IntNode = node;
        return string_to_long(n.tok.value, n.pos);
    }

    if (base == NODE_VAR_ACCESS) {
        return get_const_integer(c, node, pos);
    }

    if (base == NODE_TYPE_LAYOUT) {
        let layout: TypeLayoutNode = node;
        let type_id: Int = resolve_type(c, layout.type_node);
        if (!check_layout_type(c, type_id, layout.is_align, layout.pos)) { return 0L; }
        if (layout.is_align) { return Long(get_type_align_bytes(c, type_id)); }
        return Long(get_type_size_bytes(c, type_id));
    }

    if (base == NODE_UNARYOP) {
        let u: UnaryOpNode = node;
        let op_str: String = u.op_tok.value;
        let val: Long = eval_const_long(c, u.node, pos);
        if (op_str == "-") { return 0L - val; }
        if (op_str == "~") { return val ^ -1L; }
        throw_type_error(pos, "Invalid unary operator for const integer.");
        return 0L;
    }

    if (base == NODE_BINOP) {
        let b: BinOpNode = node;
        let op_str: String = b.op_tok.value;
        let left: Long = eval_const_long(c, b.left, pos);
        let right: Long = eval_const_long(c, b.right, pos);
        
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

func get_const_symbol(c: Compiler, node: VarAccessNode, pos: Position) -> SymbolInfo {
    let info: SymbolInfo = find_symbol(c, node.name_tok.value);
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

func get_const_num(c: Compiler, node: VarAccessNode, pos: Position) -> Float {
    let info: SymbolInfo = get_const_symbol(c, node, pos);
    if (info is null) { return 0.0; }
    if (!c.constant_nums.contains_key(info.reg)) {
        throw_type_error(pos, "Constant '" + node.name_tok.value + "' is not numeric.");
        return 0.0;
    }
    return c.constant_nums.lookup(info.reg);
}

func get_const_integer(c: Compiler, node: VarAccessNode, pos: Position) -> Long {
    let info: SymbolInfo = get_const_symbol(c, node, pos);
    if (info is null) { return 0L; }
    if (!c.constant_integers.contains_key(info.reg)) {
        throw_type_error(pos, "Constant '" + node.name_tok.value + "' is not an integer.");
        return 0L;
    }
    return c.constant_integers.lookup(info.reg);
}

func get_const_wide_integer(c: Compiler, node: VarAccessNode, pos: Position) -> UInt128 {
    let info: SymbolInfo = get_const_symbol(c, node, pos);
    if (info is null) { return UInt128(0); }
    if (c.constant_wide_integers.contains_key(info.reg)) { return c.constant_wide_integers.lookup(info.reg); }
    if (c.constant_integers.contains_key(info.reg)) { let integer: Long = c.constant_integers.lookup(info.reg); return UInt128(integer); }
    throw_type_error(pos, "Constant '" + node.name_tok.value + "' is not an integer.");
    return UInt128(0);
}

func eval_const_float(c: Compiler, node: Struct, pos: Position) -> Float {
    if (node is null) { return 0.0; }
    let base: Int = node_kind(node);
    if (base == NODE_FLOAT) {
        let value: FloatNode = node;
        return parse_decimal_float_literal(value.tok.value);
    }
    if (base == NODE_INT) {
        let value_type: Int = get_expr_type(c, node);
        if (get_type_bitwidth(value_type) == 128) {
            throw_type_error(pos, "128-bit integers are not supported in floating-point constant expressions.");
            return 0.0;
        }
        return Float(eval_const_long(c, node, pos));
    }
    if (base == NODE_CHAR) {
        let value: CharNode = node;
        return Float(string_to_int(value.tok.value, value.pos));
    }
    if (base == NODE_BOOL) {
        let value: BooleanNode = node;
        return Float(value.value);
    }
    if (base == NODE_VAR_ACCESS) {
        return get_const_num(c, node, pos);
    }
    if (base == NODE_UNARYOP) {
        let unary: UnaryOpNode = node;
        let value: Float = eval_const_float(c, unary.node, pos);
        if (unary.op_tok.type == TOK_PLUS) { return value; }
        if (unary.op_tok.type == TOK_SUB) { return 0.0 - value; }
        throw_type_error(pos, "Invalid unary operator in floating-point constant expression.");
        return 0.0;
    }
    if (base == NODE_BINOP) {
        let binary: BinOpNode = node;
        let left: Float = eval_const_float(c, binary.left, pos);
        let right: Float = eval_const_float(c, binary.right, pos);
        let op: Int = binary.op_tok.type;
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

func llvm_float_literal(value: Float) -> String {
// emit the exact IEEE-754 bits instead of depending on host float formatting
    let raw: AnyPtr = AnyPtr(ref value);
    let ptr bits: UInt64 = raw;
    let encoded: UInt64 = deref bits;
    let digits: String = "0123456789ABCDEF";
    let result: String = "0x";
    let shift: Int = 60;
    while (shift >= 0) {
        let digit: Int = Int((encoded >> UInt64(shift)) & UInt64(15));
        result += digits.slice(digit, digit + 1);
        shift -= 4;
    }
    return result;
}

func parse_const_uint128(raw: String, pos: Position) -> UInt128 {
    let end: Int = raw.length();
    if (raw.ends_with("ULL") || raw.ends_with("ull")) { end -= 3; }
    else if (raw.ends_with("LL") || raw.ends_with("ll") || raw.ends_with("UL") || raw.ends_with("ul")) { end -= 2; }
    else if (raw.ends_with("U") || raw.ends_with("u") || raw.ends_with("L") || raw.ends_with("l")) { end -= 1; }

    let value: UInt128 = UInt128(0);
    let i: Int = 0;
    while (i < end) {
        let ch: Char = raw[i];
        if (ch != '_') {
            if (ch < '0' || ch > '9') {
                throw_invalid_syntax(pos, "Invalid 128-bit integer literal.");
                return UInt128(0);
            }
            let digit: Int = Int(ch) - 48;
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

func eval_const_wide(c: Compiler, node: Struct, pos: Position, is_unsigned: Bool) -> UInt128 {
    if (node is null) { return UInt128(0); }
    let base: Int = node_kind(node);

    if (base == NODE_INT) {
        let value: IntNode = node;
        let parsed: UInt128 = parse_const_uint128(value.tok.value, value.pos);
        if (!is_unsigned && parsed > 170141183460469231731687303715884105727ULL) {
            throw_overflow_error(value.pos, "Literal '" + value.tok.value + "' overflows Int128 valid range.");
            return UInt128(0);
        }
        return parsed;
    }
    if (base == NODE_VAR_ACCESS) {
        return get_const_wide_integer(c, node, pos);
    }
    if (base == NODE_TYPE_LAYOUT) {
        return UInt128(eval_const_long(c, node, pos));
    }
    if (base == NODE_UNARYOP) {
        let unary: UnaryOpNode = node;
        let value: UInt128 = eval_const_wide(c, unary.node, pos, is_unsigned);
        if (unary.op_tok.value == "-") { return UInt128(0) - value; }
        if (unary.op_tok.value == "~") { return value ^ 340282366920938463463374607431768211455ULL; }
        throw_type_error(pos, "Invalid unary operator for 128-bit constant integer.");
        return UInt128(0);
    }
    if (base == NODE_BINOP) {
        let binary: BinOpNode = node;
        let op: String = binary.op_tok.value;
        let left: UInt128 = eval_const_wide(c, binary.left, pos, is_unsigned);
        let right: UInt128 = eval_const_wide(c, binary.right, pos, is_unsigned);

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

            let signed_left: Int128 = Int128(left);
            let signed_right: Int128 = Int128(right);
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
func eval_const_bool(c: Compiler, node: Struct, pos: Position) -> Int {
    if (node is null) { return 0; }
    let base: Int = node_kind(node);

    if (base == NODE_BOOL) {
        let b: BooleanNode = node;
        return b.value;
    }
    if (base == NODE_VAR_ACCESS) {
        let value: Long = get_const_integer(c, node, pos);
        if (value == 0L) { return 0; }
        if (value == 1L) { return 1; }
        throw_type_error(pos, "Boolean constant expression requires a Bool value.");
        return 0;
    }
    if (base == NODE_UNARYOP) {
        let u: UnaryOpNode = node;
        let op_str: String = u.op_tok.value;
        if (op_str == "!") {
            let val: Int = eval_const_bool(c, u.node, pos);
            if (val == 1) { return 0; } else { return 1; }
        }
        throw_type_error(pos, "Invalid unary operator for const boolean.");
        return 0;
    }
    if (base == NODE_BINOP) {
        let b: BinOpNode = node;
        let op_str: String = b.op_tok.value;

        if (op_str == "&&") {
            let left: Int = eval_const_bool(c, b.left, pos);
            let right: Int = eval_const_bool(c, b.right, pos);
            if (left == 1 && right == 1) { return 1; } else { return 0; }
        }
        if (op_str == "||") {
            let left: Int = eval_const_bool(c, b.left, pos);
            let right: Int = eval_const_bool(c, b.right, pos);
            if (left == 1 || right == 1) { return 1; } else { return 0; }
        }

        if (op_str == "==" || op_str == "!=" || op_str == "<" || op_str == ">" || op_str == "<=" || op_str == ">=") {
            let left_type: Int = get_expr_type(c, b.left);
            let right_type: Int = get_expr_type(c, b.right);
            if (get_type_bitwidth(left_type) == 128 || get_type_bitwidth(right_type) == 128) {
                let use_unsigned: Bool = is_unsigned_integer(left_type) || is_unsigned_integer(right_type);
                let left_wide: UInt128 = eval_const_wide(c, b.left, pos, use_unsigned);
                let right_wide: UInt128 = eval_const_wide(c, b.right, pos, use_unsigned);
                if (op_str == "==") { if (left_wide == right_wide) { return 1; } else { return 0; } }
                if (op_str == "!=") { if (left_wide != right_wide) { return 1; } else { return 0; } }
                if use_unsigned {
                    if (op_str == "<") { if (left_wide < right_wide) { return 1; } else { return 0; } }
                    if (op_str == ">") { if (left_wide > right_wide) { return 1; } else { return 0; } }
                    if (op_str == "<=") { if (left_wide <= right_wide) { return 1; } else { return 0; } }
                    if (op_str == ">=") { if (left_wide >= right_wide) { return 1; } else { return 0; } }
                } else {
                    let signed_left: Int128 = Int128(left_wide);
                    let signed_right: Int128 = Int128(right_wide);
                    if (op_str == "<") { if (signed_left < signed_right) { return 1; } else { return 0; } }
                    if (op_str == ">") { if (signed_left > signed_right) { return 1; } else { return 0; } }
                    if (op_str == "<=") { if (signed_left <= signed_right) { return 1; } else { return 0; } }
                    if (op_str == ">=") { if (signed_left >= signed_right) { return 1; } else { return 0; } }
                }
            }
            let left: Long = eval_const_long(c, b.left, pos);
            let right: Long = eval_const_long(c, b.right, pos);
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

func parse_decimal_float_literal(raw: String) -> Float {
// keep literal parsing self-hosted; the compiler cannot assume libc is present
    let end: Int = raw.length();
    if (raw.ends_with("f") || raw.ends_with("F")) { end -= 1; }

    let result: Float = 0.0;
    let fraction_scale: Float = 0.1;
    let in_fraction: Bool = false;
    let i: Int = 0;
    while (i < end) {
        let ch: Char = raw[i];
        if (ch == '.') {
            in_fraction = true;
        } else if (ch != '_') {
            let digit: Int = Int(ch) - Int('0');
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

