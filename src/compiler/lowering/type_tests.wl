// src/compiler/lowering/type_tests.wl
import * from "../context.wl"
import * from "../type_tests.wl"
import * from "unions.wl"
import * from "../../frontend/diagnostics.wl"


func emit_class_test(ref c: Compiler, value: CompileResult, target: Int, instance: Bool) -> String {
// an upcast changes the view of an object, its allocation header still holds the concrete type
    let object = value.reg;
    let info = c.struct_id_map.lookup(get_repr_type(ref c, value.type));
    if ((info is !null) && info.is_interface) {
        object = next_reg(ref c);
        write_ir(ref c, c.indent + object + " = extractvalue " + get_llvm_type_str(ref c, value.type) + " " + value.reg + ", 0\n");
    } else if (get_llvm_type_str(ref c, value.type) != "i8*") {
        object = next_reg(ref c);
        write_ir(ref c, c.indent + object + " = bitcast " + get_llvm_type_str(ref c, value.type) + " " + value.reg + " to i8*\n");
    }

    if instance {
        let helper = "@__wl_is_instance_" + target;
        c.erased_checks.put("instance." + target, StringConstant(id=target, value=helper));
        let result = next_reg(ref c);
        write_ir(ref c, c.indent + result + " = call i1 " + helper + "(i8* " + object + ")\n");
        return result;
    }

    let slot = next_reg(ref c);
    let absent = next_reg(ref c);
    let inspect = next_label(ref c);
    let done = next_label(ref c);
    write_ir(ref c, c.indent + slot + " = alloca i1\n");
    write_ir(ref c, c.indent + "store i1 false, i1* " + slot + "\n");
    write_ir(ref c, c.indent + absent + " = icmp eq i8* " + object + ", null\n");
    write_ir(ref c, c.indent + "br i1 " + absent + ", label %" + done + ", label %" + inspect + "\n");
    write_ir(ref c, "\n" + inspect + ":\n");

    let bytes = next_reg(ref c);
    let address = next_reg(ref c);
    let tag = next_reg(ref c);
    let matches = next_reg(ref c);
    write_ir(ref c, c.indent + bytes + " = getelementptr i8, i8* " + object + ", i32 -4\n");
    write_ir(ref c, c.indent + address + " = bitcast i8* " + bytes + " to i32*\n");
    write_ir(ref c, c.indent + tag + " = load i32, i32* " + address + "\n");
    write_ir(ref c, c.indent + matches + " = icmp eq i32 " + tag + ", " + target + "\n");
    write_ir(ref c, c.indent + "store i1 " + matches + ", i1* " + slot + "\n");
    write_ir(ref c, c.indent + "br label %" + done + "\n");
    write_ir(ref c, "\n" + done + ":\n");
    let result = next_reg(ref c);
    write_ir(ref c, c.indent + result + " = load i1, i1* " + slot + "\n");
    return result;
}

func emit_type_test(ref c: Compiler, value: CompileResult, target: Int, instance: Bool) -> CompileResult {
    let result = "false";
    let found = get_union_type(ref c, value.type);
    if (found is null) {
        if (!instance && get_named_type(ref c, value.type) is !null) {
            if (value.type == target) { result = "true"; }
        } else if (type_test_class(ref c, value.type) || type_test_header(value.type)) {
            result = emit_class_test(ref c, value, target, instance);
        } else if (value.type == target) {
            result = "true";
        }
        return CompileResult(reg=result, type=TYPE_BOOL, origin_type=0, owns_ref=false, is_const_access=false);
    }
    let union: UnionInfo = found;

    let slot = next_reg(ref c);
    let tag = next_reg(ref c);
    let done = next_label(ref c);
    write_ir(ref c, c.indent + slot + " = alloca i1\n");
    write_ir(ref c, c.indent + "store i1 false, i1* " + slot + "\n");
    write_ir(ref c, c.indent + tag + " = extractvalue " + get_llvm_type_str(ref c, value.type) + " " + value.reg + ", 0\n");

    let i = 0;
    while (i < union.members.length()) {
        let member = union.members[i];
        let test = next_label(ref c);
        let next = next_label(ref c);
        let active = next_reg(ref c);
        write_ir(ref c, c.indent + active + " = icmp eq i32 " + tag + ", " + i + "\n");
        write_ir(ref c, c.indent + "br i1 " + active + ", label %" + test + ", label %" + next + "\n");
        write_ir(ref c, "\n" + test + ":\n");
        let matches = "false";
        if (!instance && get_named_type(ref c, member) is !null) {
            if (member == target) { matches = "true"; }
        } else if (type_test_class(ref c, member) || type_test_header(member)) {
            matches = emit_class_test(ref c, emit_union_read(ref c, value, member), target, instance);
        } else if (member == target) { matches = "true"; }
        write_ir(ref c, c.indent + "store i1 " + matches + ", i1* " + slot + "\n");
        write_ir(ref c, c.indent + "br label %" + done + "\n");
        write_ir(ref c, "\n" + next + ":\n");
        i++;
    }
    write_ir(ref c, c.indent + "unreachable\n");
    write_ir(ref c, "\n" + done + ":\n");
    result = next_reg(ref c);
    write_ir(ref c, c.indent + result + " = load i1, i1* " + slot + "\n");
    return CompileResult(reg=result, type=TYPE_BOOL, origin_type=0, owns_ref=false, is_const_access=false);
}
