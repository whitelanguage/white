// compiler/lowering/errors.wl
import * from "../../frontend/ast.wl"
import * from "../context.wl"
import * from "../../frontend/diagnostics.wl"
import * from "dictionary.wl"

func emit_error_value(c: Compiler, value: CompileResult, pos: Position) -> CompileResult {
    // attach a stable error-domain id to a concrete error enum value
    if (value.type == TYPE_ANY_ERROR) { return value; }

    let error_type: Int = value.type;
    if (!is_error_type(c, error_type) && is_error_type(c, value.origin_type)) {
        error_type = value.origin_type;
    }
    if (!is_error_type(c, error_type)) {
        throw_type_error(pos, "Cannot use " + get_type_name(c, value.type) + " as an error");
        return void_result();
    }

    let with_domain: String = next_reg(c);
    c.output_file.write(c.indent + with_domain + " = insertvalue { i64, i32 } undef, i64 " + type_fingerprint(c, error_type) + ", 0\n");
    let result: String = next_reg(c);
    c.output_file.write(c.indent + result + " = insertvalue { i64, i32 } " + with_domain + ", i32 " + value.reg + ", 1\n");
    return CompileResult(reg=result, type=TYPE_ANY_ERROR);
}
