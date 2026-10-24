// src/compiler/lowering/numeric.wl
import * from "../context.wl"


func promote_to_float(ref c: Compiler, res: CompileResult) -> CompileResult {
    if (res.type == TYPE_FLOAT) { return res; }
    let input_reg: String = res.reg;

    if (res.type == TYPE_FLOAT32) {
        let fpext_reg: String = next_reg(ref c);
        write_ir(ref c, c.indent + fpext_reg + " = fpext float " + input_reg + " to double\n");

        return CompileResult(reg=fpext_reg, type=TYPE_FLOAT, origin_type=0, owns_ref=false, is_const_access=false);
    }

    if (res.type == TYPE_BOOL) {
        let zext_reg: String = next_reg(ref c);
        write_ir(ref c, c.indent + zext_reg + " = zext i1 " + input_reg + " to i32\n");

        let uitofp_reg: String = next_reg(ref c);
        write_ir(ref c, c.indent + uitofp_reg + " = uitofp i32 " + zext_reg + " to double\n");

        return CompileResult(reg=uitofp_reg, type=TYPE_FLOAT, origin_type=0, owns_ref=false, is_const_access=false);
    }

    let ty_str: String = get_llvm_type_str(ref c, res.type);
    let fp_reg: String = next_reg(ref c);

    if (is_signed_integer(res.type)) {
        write_ir(ref c, c.indent + fp_reg + " = sitofp " + ty_str + " " + input_reg + " to double\n");

        return CompileResult(reg=fp_reg, type=TYPE_FLOAT, origin_type=0, owns_ref=false, is_const_access=false);
    }

    if (is_unsigned_integer(res.type)) {
        write_ir(ref c, c.indent + fp_reg + " = uitofp " + ty_str + " " + input_reg + " to double\n");

        return CompileResult(reg=fp_reg, type=TYPE_FLOAT, origin_type=0, owns_ref=false, is_const_access=false);
    }

    return res;
}
func promote_to_long(ref c: Compiler, res: CompileResult) -> CompileResult {
    let ty_str: String = get_llvm_type_str(ref c, res.type);

    if (ty_str == "i64" || ty_str == "i128" || ty_str == "double" || ty_str == "float" || res.type >= 100) {
        return res;
    }

    let input_reg: String = res.reg;
    let ext_reg: String = next_reg(ref c);

    if (res.type == TYPE_BOOL) {
        write_ir(ref c, c.indent + ext_reg + " = zext i1 " + input_reg + " to i64\n");

        return CompileResult(reg=ext_reg, type=TYPE_LONG, origin_type=0, owns_ref=false, is_const_access=false);
    }

    if (is_signed_integer(res.type)) {
        write_ir(ref c, c.indent + ext_reg + " = sext " + ty_str + " " + input_reg + " to i64\n");

        return CompileResult(reg=ext_reg, type=TYPE_LONG, origin_type=0, owns_ref=false, is_const_access=false);
    }

    if (is_unsigned_integer(res.type)) {
        write_ir(ref c, c.indent + ext_reg + " = zext " + ty_str + " " + input_reg + " to i64\n");

        return CompileResult(reg=ext_reg, type=TYPE_LONG, origin_type=0, owns_ref=false, is_const_access=false);
    }

    return res;
}
func promote_to_int(ref c: Compiler, res: CompileResult) -> CompileResult {
    let ty_str: String = get_llvm_type_str(ref c, res.type);

    if (ty_str == "i32" || ty_str == "i64" || ty_str == "i128" || ty_str == "double" || ty_str == "float" || res.type == TYPE_BOOL || res.type >= 100) {
        return res;
    }

    let input_reg: String = res.reg;
    let ext_reg: String = next_reg(ref c);

    if (is_signed_integer(res.type)) {
        write_ir(ref c, c.indent + ext_reg + " = sext " + ty_str + " " + input_reg + " to i32\n");
    } else {
        write_ir(ref c, c.indent + ext_reg + " = zext " + ty_str + " " + input_reg + " to i32\n");
    }

    return CompileResult(reg=ext_reg, type=TYPE_INT, origin_type=0, owns_ref=false, is_const_access=false);
}

func widen_int(ref c: Compiler, value: CompileResult, target: Int) -> CompileResult {
    if (!is_integer_type(value.type) || !is_integer_type(target)) { return value; }
    let source_bits: Int = get_type_bitwidth(value.type);
    let target_bits: Int = get_type_bitwidth(target);
    if (source_bits >= target_bits) { return value; }
    if (is_signed_integer(value.type) && is_unsigned_integer(target)) { return value; }
    let source_type: String = get_llvm_type_str(ref c, value.type);
    let target_type: String = get_llvm_type_str(ref c, target);
    let result: String = next_reg(ref c);
    let op: String = "zext";
    if (is_signed_integer(value.type)) { op = "sext"; }

    write_ir(ref c, c.indent + result + " = " + op + " " + source_type + " " + value.reg + " to " + target_type + "\n");

    return CompileResult(reg=result, type=target, origin_type=value.type, owns_ref=value.owns_ref, is_const_access=false);
}

func combine_i128_words(ref c: Compiler, low: String, high: String) -> String {
    let low_i128: String = next_reg(ref c);
    write_ir(ref c, c.indent + low_i128 + " = zext i64 " + low + " to i128\n");

    let high_i128: String = next_reg(ref c);
    write_ir(ref c, c.indent + high_i128 + " = zext i64 " + high + " to i128\n");

    let shifted_high: String = next_reg(ref c);
    write_ir(ref c, c.indent + shifted_high + " = shl i128 " + high_i128 + ", 64\n");

    let result: String = next_reg(ref c);
    write_ir(ref c, c.indent + result + " = or i128 " + low_i128 + ", " + shifted_high + "\n");

    return result;
}
