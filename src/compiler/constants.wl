// src/compiler/constants.wl
import * from "../frontend/ast.wl"
import * from "../frontend/arena.wl"
import * from "context.wl"
import * from "../frontend/tokens.wl"
import * from "../frontend/diagnostics.wl"
import * from "lowering/numeric.wl"


func check_layout_type(ref c: Compiler, type_id: Int, is_align: Bool, pos: Position) -> Bool {
    let property: String = "size";
    if is_align { property = "alignment"; }
    if (type_id == TYPE_POISON) { return false; }
    let found_union: Optional(UnionInfo) = get_union_type(ref c, get_repr_type(ref c, type_id));
    if (found_union is !null) {
        let union: UnionInfo = found_union;
        let i: Int = 0;
        while (i < union.members.length()) {
            if (!check_layout_type(ref c, union.members[i], is_align, pos)) { return false; }
            i++;
        }
        return get_union_layout(ref c, get_repr_type(ref c, type_id)).valid;
    }
    if (type_id == TYPE_VOID) {
        throw_type_error(pos, "Type 'Void' has no " + property + ".");
        return false;
    }
    if (type_id == TYPE_AUTO) {
        throw_type_error(pos, "Type 'Auto' must be resolved before its " + property + " can be determined.");
        return false;
    }
    if (type_id == TYPE_GENERIC_STRUCT || type_id == TYPE_GENERIC_FUNCTION || type_id == TYPE_GENERIC_CLASS || type_id == TYPE_GENERIC_METHOD || type_id == TYPE_GENERIC_ENUM) {
        throw_type_error(pos, "Type-erased '" + get_type_name(ref c, type_id) + "' has no defined " + property + ".");
        return false;
    }
    return true;
}

func eval_const_long(ref c: Compiler, node: NodeID, pos: Position) -> Long {
    if (!has_node(node)) {
        return 0L;
    }
    let base: Int = node_tag(node);

    if (base == NODE_INT) {
        let n: IntNode = get_int_node(ref c.arena, node);
        return string_to_long(n.tok.value, n.pos);
    }

    if (base == NODE_VAR_ACCESS) {
        return get_const_integer(ref c, get_var_access_node(ref c.arena, node), pos);
    }

    if (base == NODE_TYPE_LAYOUT) {
        let layout: TypeLayoutNode = get_type_layout_node(ref c.arena, node);
        let type_id: Int = resolve_type(ref c, layout.type_node);
        if (!check_layout_type(ref c, type_id, layout.is_align, layout.pos)) { return 0L; }
        if (layout.is_align) {
            return Long(get_type_align_bytes(ref c, type_id));
        }
        return Long(get_type_size_bytes(ref c, type_id));
    }

    if (base == NODE_UNARYOP) {
        let u: UnaryOpNode = get_unary_node(ref c.arena, node);
        let op_str: String = u.op_tok.value;
        let val: Long = eval_const_long(ref c, u.node, pos);
        if (op_str == "-") {
            return 0L - val;
        }
        if (op_str == "~") {
            return val ^ -1L;
        }
        throw_type_error(pos, "Invalid unary operator for const integer.");
        return 0L;
    }

    if (base == NODE_BINOP) {
        let b: BinOpNode = get_binop_node(ref c.arena, node);
        let op_str: String = b.op_tok.value;
        let left: Long = eval_const_long(ref c, b.left, pos);
        let right: Long = eval_const_long(ref c, b.right, pos);

        if (op_str == "+") { return left + right; }
        if (op_str == "-") {
            return left - right;
        }
        if (op_str == "*") { return left * right; }
        if (op_str == "/") {
            if (right == 0L) {
                throw_zero_division_error(pos, "Compile-time division by zero.");
                return 0L;
            }
            return left / right;
        }
        if (op_str == "%") {
            if (right == 0L) {
                throw_zero_division_error(pos, "Compile-time modulo by zero.");
                return 0L;
            }
            return left % right;
        }
        if (op_str == "<<") {
            return left << right;
        }
        if (op_str == ">>") {
            return left >> right;
        }
        if (op_str == "&") {
            return left & right;
        }
        if (op_str == "|") { return left | right; }
        if (op_str == "^") {
            return left ^ right;
        }

        throw_type_error(pos, "Invalid binary operator for const integer.");
        return 0L;
    }
    throw_invalid_syntax(pos, "Expression is not a compile-time constant integer.");
    return 0L;
}

func get_const_symbol(ref c: Compiler, node: VarAccessNode, pos: Position) -> Optional(SymbolInfo) {
    let info: Optional(SymbolInfo) = find_symbol(ref c, node.name_tok.value);
    if (!(info is !null)) {
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

func get_const_num(ref c: Compiler, node: VarAccessNode, pos: Position) -> Float {
    let info: Optional(SymbolInfo) = get_const_symbol(ref c, node, pos);
    if (!(info is !null)) {
        return 0.0;
    }
    let value = c.constant_nums.lookup(info.reg);
    if (value is null) {
        throw_type_error(pos, "Constant '" + node.name_tok.value + "' is not numeric.");
        return 0.0;
    }
    return value;
}

func get_const_integer(ref c: Compiler, node: VarAccessNode, pos: Position) -> Long {
    let info: Optional(SymbolInfo) = get_const_symbol(ref c, node, pos);
    if (!(info is !null)) { return 0L; }
    let value = c.constant_integers.lookup(info.reg);
    if (value is null) {
        throw_type_error(pos, "Constant '" + node.name_tok.value + "' is not an integer.");
        return 0L;
    }
    return value;
}

func get_const_wide_integer(ref c: Compiler, node: VarAccessNode, pos: Position) -> UInt128 {
    let info: Optional(SymbolInfo) = get_const_symbol(ref c, node, pos);
    if (!(info is !null)) {
        return UInt128(0);
    }
    let value = c.constant_wide_integers.lookup(info.reg);
    if (value is !null) { return value; }
    let integer: Optional(Long) = c.constant_integers.lookup(info.reg);
    if (integer is !null) { return UInt128(integer); }
    throw_type_error(pos, "Constant '" + node.name_tok.value + "' is not an integer.");
    return UInt128(0);
}

func eval_const_float(ref c: Compiler, node: NodeID, pos: Position) -> Float {
    if (!has_node(node)) {
        return 0.0;
    }
    let base: Int = node_tag(node);
    if (base == NODE_FLOAT) {
        let value: FloatNode = get_float_node(ref c.arena, node);
        return parse_decimal_float_literal(value.tok.value);
    }
    if (base == NODE_INT) {
        let value_type: Int = get_expr_type(ref c, node);
        if (get_type_bitwidth(value_type) == 128) {
            throw_type_error(pos, "128-bit integers are not supported in floating-point constant expressions.");
            return 0.0;
        }
        return Float(eval_const_long(ref c, node, pos));
    }
    if (base == NODE_CHAR) {
        let value: CharNode = get_char_node(ref c.arena, node);
        return Float(string_to_int(value.tok.value, value.pos));
    }
    if (base == NODE_BOOL) {
        let value: BooleanNode = get_bool_node(ref c.arena, node);
        return Float(value.value);
    }
    if (base == NODE_VAR_ACCESS) {
        return get_const_num(ref c, get_var_access_node(ref c.arena, node), pos);
    }
    if (base == NODE_UNARYOP) {
        let unary: UnaryOpNode = get_unary_node(ref c.arena, node);
        let value: Float = eval_const_float(ref c, unary.node, pos);
        if (unary.op_tok.type == TOK_PLUS) { return value; }
        if (unary.op_tok.type == TOK_SUB) {
            return 0.0 - value;
        }
        throw_type_error(pos, "Invalid unary operator in floating-point constant expression.");
        return 0.0;
    }
    if (base == NODE_BINOP) {
        let binary: BinOpNode = get_binop_node(ref c.arena, node);
        let left: Float = eval_const_float(ref c, binary.left, pos);
        let right: Float = eval_const_float(ref c, binary.right, pos);
        let op: Int = binary.op_tok.type;
        if (op == TOK_PLUS) { return left + right; }
        if (op == TOK_SUB) {
            return left - right;
        }
        if (op == TOK_MUL) { return left * right; }
        if (op == TOK_DIV) {
            if (right == 0.0) {
                throw_zero_division_error(pos, "Compile-time division by zero.");
                return 0.0;
            }
            return left / right;
        }
        if (op == TOK_MOD) {
            if (right == 0.0) {
                throw_zero_division_error(pos, "Compile-time modulo by zero.");
                return 0.0;
            }
            return left % right;
        }
        if (op == TOK_POW) {
            return left ** right;
        }
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
    else if (raw.ends_with("LL") || raw.ends_with("ll") || raw.ends_with("UL") || raw.ends_with("ul")) {
        end -= 2;
    }
    else if (raw.ends_with("U") || raw.ends_with("u") || raw.ends_with("L") || raw.ends_with("l")) {
        end -= 1;
    }

    let base: UInt128 = UInt128(10U);
    let i: Int = 0;
    if (end >= 2 && raw[0] == '0') {
        if (raw[1] == 'x' || raw[1] == 'X') {
            base = UInt128(16U);
            i = 2;
        }
        else if (raw[1] == 'b' || raw[1] == 'B') {
            base = UInt128(2U);
            i = 2;
        }
        else if (raw[1] == 'o' || raw[1] == 'O') {
            base = UInt128(8U);
            i = 2;
        }
    }
    if (i == end) {
        throw_invalid_syntax(pos, "Integer literal has no digits.");
        return UInt128(0);
    }

    let maximum: UInt128 = 340282366920938463463374607431768211455ULL;
    let value: UInt128 = UInt128(0);
    while (i != end) {
        let ch: Char = raw[i];
        if (ch != '_') {
            let digit: Int = -1;
            if (ch >= '0' && ch <= '9') { digit = Int(ch) - Int('0'); }
            else if (ch >= 'a' && ch <= 'f') { digit = Int(ch) - Int('a') + 10; }
            else if (ch >= 'A' && ch <= 'F') {
                digit = Int(ch) - Int('A') + 10;
            }
            if (digit == -1 || UInt128(digit) >= base) {
                throw_invalid_syntax(pos, "Invalid 128-bit integer literal.");
                return UInt128(0);
            }
            let wide_digit: UInt128 = UInt128(digit);
            if (value > (maximum - wide_digit) / base) {
                throw_overflow_error(pos, "128-bit integer literal is out of range.");
                return UInt128(0);
            }
            value = value * base + wide_digit;
        }
        i += 1;
    }
    return value;
}

func eval_const_wide(ref c: Compiler, node: NodeID, pos: Position, is_unsigned: Bool) -> UInt128 {
    if (!has_node(node)) {
        return UInt128(0);
    }
    let base: Int = node_tag(node);

    if (base == NODE_INT) {
        let value: IntNode = get_int_node(ref c.arena, node);
        let parsed: UInt128 = parse_const_uint128(value.tok.value, value.pos);
        if (!is_unsigned && parsed > 170141183460469231731687303715884105727ULL) {
            throw_overflow_error(value.pos, "Literal '" + value.tok.value + "' overflows Int128 valid range.");
            return UInt128(0);
        }
        return parsed;
    }
    if (base == NODE_VAR_ACCESS) {
        return get_const_wide_integer(ref c, get_var_access_node(ref c.arena, node), pos);
    }
    if (base == NODE_TYPE_LAYOUT) {
        return UInt128(eval_const_long(ref c, node, pos));
    }
    if (base == NODE_UNARYOP) {
        let unary: UnaryOpNode = get_unary_node(ref c.arena, node);
        let value: UInt128 = eval_const_wide(ref c, unary.node, pos, is_unsigned);
        if (unary.op_tok.value == "-") {
            return UInt128(0) - value;
        }
        if (unary.op_tok.value == "~") {
            return value ^ 340282366920938463463374607431768211455ULL;
        }
        throw_type_error(pos, "Invalid unary operator for 128-bit constant integer.");
        return UInt128(0);
    }
    if (base == NODE_BINOP) {
        let binary: BinOpNode = get_binop_node(ref c.arena, node);
        let op: String = binary.op_tok.value;
        let left: UInt128 = eval_const_wide(ref c, binary.left, pos, is_unsigned);
        let right: UInt128 = eval_const_wide(ref c, binary.right, pos, is_unsigned);

        if (op == "+") {
            return left + right;
        }
        if (op == "-") {
            return left - right;
        }
        if (op == "*") {
            return left * right;
        }
        if (op == "<<") {
            return left << right;
        }
        if (op == ">>") {
            if is_unsigned { return left >> right; }
            return UInt128(Int128(left) >> Int128(right));
        }
        if (op == "&") {
            return left & right;
        }
        if (op == "|") {
            return left | right;
        }
        if (op == "^") {
            return left ^ right;
        }
        if (op == "/" || op == "%") {
            if (right == UInt128(0)) {
                throw_zero_division_error(pos, "Compile-time division by zero.");
                return UInt128(0);
            }
            if is_unsigned {
                if (op == "/") {
                    return left / right;
                }
                return left % right;
            }

            let signed_left: Int128 = Int128(left);
            let signed_right: Int128 = Int128(right);
            if (signed_left == -170141183460469231731687303715884105727LL - Int128(1) && signed_right == Int128(-1)) {
                throw_overflow_error(pos, "Compile-time signed division overflow.");
                return UInt128(0);
            }
            if (op == "/") {
                return UInt128(signed_left / signed_right);
            }
            return UInt128(signed_left % signed_right);
        }

        throw_type_error(pos, "Invalid binary operator for 128-bit constant integer.");
        return UInt128(0);
    }

    throw_invalid_syntax(pos, "Expression is not a compile-time constant 128-bit integer.");
    return UInt128(0);
}
func eval_const_bool(ref c: Compiler, node: NodeID, pos: Position) -> Int {
    if (!has_node(node)) { return 0; }
    let base: Int = node_tag(node);

    if (base == NODE_BOOL) {
        let b: BooleanNode = get_bool_node(ref c.arena, node);
        return b.value;
    }
    if (base == NODE_VAR_ACCESS) {
        let value: Long = get_const_integer(ref c, get_var_access_node(ref c.arena, node), pos);
        if (value == 0L) { return 0; }
        if (value == 1L) { return 1; }
        throw_type_error(pos, "Boolean constant expression requires a Bool value.");
        return 0;
    }
    if (base == NODE_UNARYOP) {
        let u: UnaryOpNode = get_unary_node(ref c.arena, node);
        let op_str: String = u.op_tok.value;
        if (op_str == "!") {
            let val: Int = eval_const_bool(ref c, u.node, pos);
            if (val == 1) {
                return 0;
            } else {
                return 1;
            }
        }
        throw_type_error(pos, "Invalid unary operator for const boolean.");
        return 0;
    }
    if (base == NODE_BINOP) {
        let b: BinOpNode = get_binop_node(ref c.arena, node);
        let op_str: String = b.op_tok.value;

        if (op_str == "&&") {
            let left: Int = eval_const_bool(ref c, b.left, pos);
            let right: Int = eval_const_bool(ref c, b.right, pos);
            if (left == 1 && right == 1) {
                return 1;
            } else {
                return 0;
            }
        }
        if (op_str == "||") {
            let left: Int = eval_const_bool(ref c, b.left, pos);
            let right: Int = eval_const_bool(ref c, b.right, pos);
            if (left == 1 || right == 1) {
                return 1;
            } else {
                return 0;
            }
        }

        if (op_str == "==" || op_str == "!=" || op_str == "<" || op_str == ">" || op_str == "<=" || op_str == ">=") {
            let left_type: Int = get_expr_type(ref c, b.left);
            let right_type: Int = get_expr_type(ref c, b.right);
            if (get_type_bitwidth(left_type) == 128 || get_type_bitwidth(right_type) == 128) {
                let use_unsigned: Bool = is_unsigned_integer(left_type) || is_unsigned_integer(right_type);
                let left_wide: UInt128 = eval_const_wide(ref c, b.left, pos, use_unsigned);
                let right_wide: UInt128 = eval_const_wide(ref c, b.right, pos, use_unsigned);
                if (op_str == "==") {
                    if (left_wide == right_wide) { return 1; }
                    return 0;
                }
                if (op_str == "!=") {
                    if (left_wide != right_wide) { return 1; }
                    return 0;
                }
                if use_unsigned {
                    if (op_str == "<") {
                        if (left_wide < right_wide) { return 1; }
                        return 0;
                    }
                    if (op_str == ">") {
                        if (left_wide > right_wide) { return 1; }
                        return 0;
                    }
                    if (op_str == "<=") {
                        if (left_wide <= right_wide) { return 1; }
                        return 0;
                    }
                    if (op_str == ">=") {
                        if (left_wide >= right_wide) { return 1; }
                        return 0;
                    }
                } else {
                    let signed_left: Int128 = Int128(left_wide);
                    let signed_right: Int128 = Int128(right_wide);
                    if (op_str == "<") {
                        if (signed_left < signed_right) { return 1; }
                        return 0;
                    }
                    if (op_str == ">") {
                        if (signed_left > signed_right) { return 1; }
                        return 0;
                    }
                    if (op_str == "<=") {
                        if (signed_left <= signed_right) { return 1; }
                        return 0;
                    }
                    if (op_str == ">=") {
                        if (signed_left >= signed_right) { return 1; }
                        return 0;
                    }
                }
            }
            let left: Long = eval_const_long(ref c, b.left, pos);
            let right: Long = eval_const_long(ref c, b.right, pos);
            if (op_str == "==") {
                if (left == right) { return 1; }
                return 0;
            }
            if (op_str == "!=") {
                if (left != right) { return 1; }
                return 0;
            }
            if (op_str == "<") {
                if (left < right) { return 1; }
                return 0;
            }
            if (op_str == ">") {
                if (left > right) { return 1; }
                return 0;
            }
            if (op_str == "<=") {
                if (left <= right) { return 1; }
                return 0;
            }
            if (op_str == ">=") {
                if (left >= right) { return 1; }
                return 0;
            }
        }

        throw_type_error(pos, "Invalid binary operator for const boolean.");
        return 0;
    }

    throw_invalid_syntax(pos, "Expression is not a compile-time constant boolean.");
    return 0;
}

func decimal_uint64_to_float(value: UInt64) -> Float {
    let high: UInt32 = UInt32(value >> UInt64(32U));
    let low: UInt32 = UInt32(value & UInt64(4294967295U));
    return Float(high) * 4294967296.0 + Float(low);
}

func decimal_mul_small(words: Vector(UInt32), factor: UInt32, addend: UInt32) -> Void {
    let carry: UInt64 = UInt64(addend);
    let i: Int = 0;
    while (i < words.length()) {
        let product: UInt64 = UInt64(words[i]) * UInt64(factor) + carry;
        words[i] = UInt32(product & 4294967295UL);
        carry = product >> 32UL;
        i++;
    }
    if (carry != 0UL) { words.append(UInt32(carry)); }
}

func decimal_shift(words: Vector(UInt32), count: Int) -> Vector(UInt32) {
    let result: Vector(UInt32) = [];
    let i: Int = 0;
    while (i < count / 32) { result.append(0U); i++; }
    let shift: Int = count % 32;
    let carry: UInt64 = 0UL;
    i = 0;
    while (i < words.length()) {
        let word: UInt64 = (UInt64(words[i]) << UInt64(shift)) | carry;
        result.append(UInt32(word & 4294967295UL));
        carry = word >> 32UL;
        i++;
    }
    if (carry != 0UL) { result.append(UInt32(carry)); }
    return result;
}

func decimal_compare(left: Vector(UInt32), right: Vector(UInt32)) -> Int {
    let left_size: Int = left.length();
    let right_size: Int = right.length();
    while (left_size > 1 && left[left_size - 1] == 0U) { left_size--; }
    while (right_size > 1 && right[right_size - 1] == 0U) { right_size--; }
    if (left_size < right_size) { return -1; }
    if (left_size > right_size) { return 1; }
    let i: Int = left_size - 1;
    while (i >= 0) {
        if (left[i] < right[i]) { return -1; }
        if (left[i] > right[i]) { return 1; }
        i--;
    }
    return 0;
}

func decimal_subtract(left: Vector(UInt32), right: Vector(UInt32)) -> Void {
// division only calls this after comparing, so the difference stays unsigned
    let borrow: UInt64 = 0UL;
    let i: Int = 0;
    while (i < left.length()) {
        let sub: UInt64 = borrow;
        if (i < right.length()) { sub += UInt64(right[i]); }
        let word: UInt64 = UInt64(left[i]);
        left[i] = UInt32((word + 4294967296UL - sub) & 4294967295UL);
        borrow = 0UL;
        if (word < sub) { borrow = 1UL; }
        i++;
    }
}

func decimal_shift_right(words: Vector(UInt32)) -> Void {
    let carry: UInt32 = 0U;
    let i: Int = words.length() - 1;
    while (i >= 0) {
        let low: UInt32 = words[i] & 1U;
        words[i] = (words[i] >> 1U) | (carry << 31U);
        carry = low;
        i--;
    }
}

func decimal_bit_length(words: Vector(UInt32)) -> Int {
    let size: Int = words.length();
    while (size > 1 && words[size - 1] == 0U) { size--; }
    let top: UInt32 = words[size - 1];
    let bits: Int = (size - 1) * 32;
    while (top != 0U) { bits++; top >>= 1U; }
    return bits;
}

func decimal_round_ratio(numerator: Vector(UInt32), denominator: Vector(UInt32), sticky: Bool) -> UInt64 {
// retain the remainder until the final nearest-even decision, no intermediate Float rounding
    let bit: Int = decimal_bit_length(numerator) - decimal_bit_length(denominator);
    let quotient: UInt64 = 0UL;
    if (bit >= 0) {
        let divisor: Vector(UInt32) = decimal_shift(denominator, bit);
        while (bit >= 0) {
            if (decimal_compare(numerator, divisor) >= 0) {
                decimal_subtract(numerator, divisor);
                quotient |= 1UL << UInt64(bit);
            }
            decimal_shift_right(divisor);
            bit--;
        }
    }

    let halfway: Int = decimal_compare(decimal_shift(numerator, 1), denominator);
    if (halfway > 0 || (halfway == 0 && (sticky || (quotient & 1UL) != 0UL))) { quotient++; }
    return quotient;
}

func decimal_float_bits(bits: UInt64, narrow: Bool) -> Float {
    if narrow {
        let word: UInt32 = UInt32(bits);
        let ptr value: Float32 = AnyPtr(ref word);
        return Float(deref value);
    }
    let ptr value: Float = AnyPtr(ref bits);
    return deref value;
}

func parse_decimal_float_literal(raw: String) -> Float {
// use an exact ratio on the slow path, literals must round the same on every host
    let end: Int = raw.length();
    let narrow: Bool = raw.ends_with("f") || raw.ends_with("F");
    if narrow { end--; }
    let digits: Vector(Byte) = [];
    let point: Int = 0;
    let seen_point: Bool = false;
    let started: Bool = false;
    let sticky: Bool = false;
    let i: Int = 0;
    while (i < end) {
        let ch: Char = raw[i];
        if (ch == '.') {
            seen_point = true;
        } else if (ch != '_') {
            let digit: Byte = Byte(Int(ch) - Int('0'));
            if (!started && digit != Byte(0)) { started = true; }
            if started {
                // binary64 midpoints have fewer than 800 significant decimal digits
                if (digits.length() < 800) { digits.append(digit); }
                else if (digit != Byte(0)) { sticky = true; }
                if (!seen_point) { point++; }
            } else if seen_point { point--; }
        }
        i++;
    }
    if (!started) { return 0.0; }
    let count: Int = digits.length();
    while (count > 1 && digits[count - 1] == Byte(0)) { count--; }

    let precision: Int = 53;
    let bias: Int = 1023;
    let max_point: Int = 309;
    let min_point: Int = -323;
    if narrow { precision = 24; bias = 127; max_point = 39; min_point = -45; }
    if (point > max_point) { return decimal_float_bits(UInt64(bias * 2 + 1) << UInt64(precision - 1), narrow); }
    if (point < min_point) { return 0.0; }

    let decimal_scale: Int = point - count;
    if (!narrow && count <= 15 && decimal_scale >= -15 && decimal_scale <= 0) {
        // both integers fit exactly in binary64, one division supplies the rounding
        let number: UInt64 = 0UL;
        let scale: UInt64 = 1UL;
        i = 0;
        while (i < count) { number = number * 10UL + UInt64(digits[i]); i++; }
        i = decimal_scale;
        while (i < 0) { scale *= 10UL; i++; }
        return decimal_uint64_to_float(number) / decimal_uint64_to_float(scale);
    }

    let numerator: Vector(UInt32) = [0U];
    let denominator: Vector(UInt32) = [1U];
    i = 0;
    while (i < count) { decimal_mul_small(numerator, 10U, UInt32(digits[i])); i++; }
    i = 0;
    while (i < decimal_scale) { decimal_mul_small(numerator, 10U, 0U); i++; }
    while (i > decimal_scale) { decimal_mul_small(denominator, 10U, 0U); i--; }

    let exponent: Int = decimal_bit_length(numerator) - decimal_bit_length(denominator);
    let comparison: Int = 0;
    if (exponent >= 0) { comparison = decimal_compare(numerator, decimal_shift(denominator, exponent)); }
    else { comparison = decimal_compare(decimal_shift(numerator, -exponent), denominator); }
    if (comparison < 0) { exponent--; }

    let min_exponent: Int = 1 - bias;
    let normal: Bool = exponent >= min_exponent;
    let scale: Int = precision - 1 - exponent;
    if (!normal) { scale = precision - 1 - min_exponent; exponent = min_exponent; }
    if (scale >= 0) { numerator = decimal_shift(numerator, scale); }
    else { denominator = decimal_shift(denominator, -scale); }
    let mantissa: UInt64 = decimal_round_ratio(numerator, denominator, sticky);
    let hidden: UInt64 = 1UL << UInt64(precision - 1);
    if (mantissa == hidden * 2UL) { mantissa >>= 1UL; exponent++; }
    if (exponent > bias) { return decimal_float_bits(UInt64(bias * 2 + 1) << UInt64(precision - 1), narrow); }
    if (mantissa < hidden) { return decimal_float_bits(mantissa, narrow); }
    return decimal_float_bits((UInt64(exponent + bias) << UInt64(precision - 1)) | (mantissa - hidden), narrow);
}
