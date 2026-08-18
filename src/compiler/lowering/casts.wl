// compiler/lowering/casts.wl
import * from "../../frontend/ast.wl"
import * from "../context.wl"
import * from "../../frontend/tokens.wl"
import * from "../../frontend/diagnostics.wl"
import * from "../target.wl"
import * from "dictionary.wl"
import * from "../validation.wl"
import * from "numeric.wl"
import * from "../constants.wl"
import * from "literals.wl"
import * from "errors.wl"
import * from "ownership.wl"

func emit_implicit_cast(c: Compiler, val_res: CompileResult, expected_type: Int, pos: Position) -> CompileResult {
    if (val_res is null || val_res.reg == "") {
        let dummy_reg: String = "0";
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
    if (callable_types_compatible(c, val_res.type, expected_type)) {
        val_res.type = expected_type;
        return val_res;
    }
    let origin: Int = val_res.origin_type;

    let variant_info: StructInfo = c.struct_table.lookup("$Variant");
    if (variant_info is !null && expected_type == variant_info.type_id) {
        let boxed_info: StructInfo = c.struct_id_map.lookup("" + val_res.type);
        let boxed_enum: Bool = boxed_info is !null && boxed_info.is_enum;
        let boxed_type_supported: Bool = val_res.type == TYPE_NULL ||
                                           is_primitive_type(val_res.type) ||
                                           is_ref_type(c, val_res.type) ||
                                           is_pointer_type(c, val_res.type) ||
                                           boxed_enum;
        if (!boxed_type_supported) {
            throw_type_error(pos, "Type " + get_type_name(c, val_res.type) + " cannot be stored in Dict.");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }

        let variant_llvm: String = variant_info.llvm_name;
        let box_ptr: String = emit_alloc_obj(c, "" + variant_payload_size(), "" + expected_type, variant_llvm + "*");

        let type_ptr: String = next_reg(c);
        c.output_file.write(c.indent + type_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + box_ptr + ", i32 0, i32 0\n");
        let boxed_tag: UInt64 = type_fingerprint(c, val_res.type);
        if (val_res.type == TYPE_NULL || val_res.type == TYPE_NULLPTR) { boxed_tag = UInt64(0); }
        c.output_file.write(c.indent + "store i64 " + boxed_tag + ", i64* " + type_ptr + "\n");

        let payload_low_ptr: String = next_reg(c);
        c.output_file.write(c.indent + payload_low_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + box_ptr + ", i32 0, i32 1\n");
        let payload_high_ptr: String = next_reg(c);
        c.output_file.write(c.indent + payload_high_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + box_ptr + ", i32 0, i32 2\n");

        let payload_low: String = "0";
        let payload_high: String = "0";

        if (val_res.type == TYPE_NULL || val_res.type == TYPE_NULLPTR) {
            payload_low = "0";
        } else if (boxed_info is !null && boxed_info.is_interface) {
            let interface_ty: String = get_llvm_type_str(c, val_res.type);
            let object_ptr: String = next_reg(c);
            c.output_file.write(c.indent + object_ptr + " = extractvalue " + interface_ty + " " + val_res.reg + ", 0\n");
            let table_ptr: String = next_reg(c);
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
            let shifted_high: String = next_reg(c);
            c.output_file.write(c.indent + shifted_high + " = lshr i128 " + val_res.reg + ", 64\n");
            payload_high = next_reg(c);
            c.output_file.write(c.indent + payload_high + " = trunc i128 " + shifted_high + " to i64\n");
        } else if (is_small_primitive_type(val_res.type)) {
            let prim_ty: String = get_llvm_type_str(c, val_res.type);
            payload_low = next_reg(c);
            if (is_signed_integer(val_res.type)) {
                c.output_file.write(c.indent + payload_low + " = sext " + prim_ty + " " + val_res.reg + " to i64\n");
            } else {
                c.output_file.write(c.indent + payload_low + " = zext " + prim_ty + " " + val_res.reg + " to i64\n");
            }
        } else if (val_res.type == TYPE_FLOAT32) {
            let fpext_reg: String = next_reg(c);
            c.output_file.write(c.indent + fpext_reg + " = fpext float " + val_res.reg + " to double\n");
            payload_low = next_reg(c);
            c.output_file.write(c.indent + payload_low + " = bitcast double " + fpext_reg + " to i64\n");
        } else if (val_res.type == TYPE_INTSIZE || val_res.type == TYPE_UINTSIZE) {
            let size_ty: String = get_size_llvm_type();
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
                let ptr_ty: String = get_llvm_type_str(c, val_res.type);
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

    let variant_info_check: StructInfo = c.struct_table.lookup("$Variant");
    if (variant_info_check is !null && val_res.type == variant_info_check.type_id) {
        let variant_llvm: String = variant_info_check.llvm_name;
        
        let read_box_label: String = "read_box_" + c.type_counter;
        let check_match_label: String = "check_match_" + c.type_counter;
        let unbox_label: String = "unbox_" + c.type_counter;
        let merge_label: String = "merge_" + c.type_counter;
        let fail_label: String = "unbox_fail_" + c.type_counter;
        let null_return_label: String = "ret_null_" + c.type_counter;
        c.type_counter += 1;

        let can_be_null: Bool = is_ref_type(c, expected_type) || is_pointer_type(c, expected_type);

        let is_null_ptr: String = next_reg(c);
        c.output_file.write(c.indent + is_null_ptr + " = icmp eq " + variant_llvm + "* " + val_res.reg + ", null\n");
        
        if can_be_null {
            c.output_file.write(c.indent + "br i1 " + is_null_ptr + ", label %" + null_return_label + ", label %" + read_box_label + "\n");
        } else {
            c.output_file.write(c.indent + "br i1 " + is_null_ptr + ", label %" + fail_label + ", label %" + read_box_label + "\n");
        }

        c.output_file.write("\n" + read_box_label + ":\n");
        let type_id_ptr: String = next_reg(c);
        c.output_file.write(c.indent + type_id_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + val_res.reg + ", i32 0, i32 0\n");
        let type_id_reg: String = next_reg(c);
        c.output_file.write(c.indent + type_id_reg + " = load i64, i64* " + type_id_ptr + "\n");

        let is_zero_tag: String = next_reg(c);
        c.output_file.write(c.indent + is_zero_tag + " = icmp eq i64 " + type_id_reg + ", 0\n");
        
        if can_be_null {
            c.output_file.write(c.indent + "br i1 " + is_zero_tag + ", label %" + null_return_label + ", label %" + check_match_label + "\n");
        } else {
            c.output_file.write(c.indent + "br i1 " + is_zero_tag + ", label %" + fail_label + ", label %" + check_match_label + "\n");
        }

        c.output_file.write("\n" + check_match_label + ":\n");
        let is_match: String = next_reg(c);
        
        if (expected_type == TYPE_GENERIC_STRUCT || expected_type == TYPE_GENERIC_CLASS) {
            let match_acc: String = "false";
            let candidate: Int = 1;
            while (candidate < c.type_counter) {
                let candidate_info: StructInfo = c.struct_id_map.lookup("" + candidate);
                let accepts: Bool = false;
                if (candidate == TYPE_STRING) { accepts = true; }
                if (candidate_info is !null && !candidate_info.is_enum && !candidate_info.is_interface) {
                    if (expected_type == TYPE_GENERIC_STRUCT && !candidate_info.is_class) { accepts = true; }
                    if (expected_type == TYPE_GENERIC_CLASS && candidate_info.is_class) { accepts = true; }
                }
                if accepts {
                    let candidate_match: String = next_reg(c);
                    c.output_file.write(c.indent + candidate_match + " = icmp eq i64 " + type_id_reg + ", " + type_fingerprint(c, candidate) + "\n");
                    if (match_acc == "false") {
                        match_acc = candidate_match;
                    } else {
                        let combined: String = next_reg(c);
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
        let payload_low_ptr: String = next_reg(c);
        c.output_file.write(c.indent + payload_low_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + val_res.reg + ", i32 0, i32 1\n");
        let payload_low: String = next_reg(c);
        c.output_file.write(c.indent + payload_low + " = load i64, i64* " + payload_low_ptr + "\n");
        let payload_high_ptr: String = next_reg(c);
        c.output_file.write(c.indent + payload_high_ptr + " = getelementptr inbounds " + variant_llvm + ", " + variant_llvm + "* " + val_res.reg + ", i32 0, i32 2\n");
        let payload_high: String = next_reg(c);
        c.output_file.write(c.indent + payload_high + " = load i64, i64* " + payload_high_ptr + "\n");
        
        let unboxed_reg: String = "";
        if (expected_type == TYPE_INT128 || expected_type == TYPE_UINT128) {
            unboxed_reg = combine_i128_words(c, payload_low, payload_high);
        } else if (is_small_primitive_type(expected_type)) {
            let prim_ty: String = get_llvm_type_str(c, expected_type);
            unboxed_reg = next_reg(c);
            c.output_file.write(c.indent + unboxed_reg + " = trunc i64 " + payload_low + " to " + prim_ty + "\n");
        } else if (expected_type == TYPE_FLOAT32) {
            let cast_double: String = next_reg(c);
            c.output_file.write(c.indent + cast_double + " = bitcast i64 " + payload_low + " to double\n");
            unboxed_reg = next_reg(c);
            c.output_file.write(c.indent + unboxed_reg + " = fptrunc double " + cast_double + " to float\n");
        } else if (expected_type == TYPE_INTSIZE || expected_type == TYPE_UINTSIZE) {
            let size_ty: String = get_size_llvm_type();
            unboxed_reg = next_reg(c);
            c.output_file.write(c.indent + unboxed_reg + " = trunc i64 " + payload_low + " to " + size_ty + "\n");
        } else if (expected_type == TYPE_LONG || expected_type == TYPE_UINT64) {
            unboxed_reg = next_reg(c);
            c.output_file.write(c.indent + unboxed_reg + " = add i64 0, " + payload_low + "\n");
        } else if (expected_type == TYPE_FLOAT) {
            unboxed_reg = next_reg(c);
            c.output_file.write(c.indent + unboxed_reg + " = bitcast i64 " + payload_low + " to double\n");
        } else {
            let exp_s_info: StructInfo = c.struct_id_map.lookup("" + expected_type);
            if (exp_s_info is !null && exp_s_info.is_interface) {
                let object_ptr: String = next_reg(c);
                c.output_file.write(c.indent + object_ptr + " = inttoptr i64 " + payload_low + " to i8*\n");
                let table_ptr: String = next_reg(c);
                c.output_file.write(c.indent + table_ptr + " = inttoptr i64 " + payload_high + " to i8*\n");
                let interface_ty: String = get_llvm_type_str(c, expected_type);
                let with_object: String = next_reg(c);
                c.output_file.write(c.indent + with_object + " = insertvalue " + interface_ty + " undef, i8* " + object_ptr + ", 0\n");
                unboxed_reg = next_reg(c);
                c.output_file.write(c.indent + unboxed_reg + " = insertvalue " + interface_ty + " " + with_object + ", i8* " + table_ptr + ", 1\n");
            } else if (exp_s_info is !null && exp_s_info.is_enum) {
                unboxed_reg = next_reg(c);
                c.output_file.write(c.indent + unboxed_reg + " = trunc i64 " + payload_low + " to i32\n");
            } else {
                let ptr_ty: String = get_llvm_type_str(c, expected_type);
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
        let final_val_reg: String = next_reg(c);
        let exp_ty_str: String = get_llvm_type_str(c, expected_type);
        
        if can_be_null {
            let zero_val: String = "0";
            if (expected_type == TYPE_FLOAT) {
                zero_val = "0.0";
            } else if (is_nullable_reference_type(c, expected_type)) {
                zero_val = "null";
            }
            let expected_info: StructInfo = c.struct_id_map.lookup("" + expected_type);
            if (expected_info is !null && expected_info.is_interface) {
                zero_val = "zeroinitializer";
            }
            
            c.output_file.write(c.indent + final_val_reg + " = phi " + exp_ty_str + " [ " + unboxed_reg + ", %" + unbox_label + " ], [ " + zero_val + ", %" + null_return_label + " ]\n");
        } else {
            c.output_file.write(c.indent + final_val_reg + " = phi " + exp_ty_str + " [ " + unboxed_reg + ", %" + unbox_label + " ]\n");
        }

        let result_owned: Bool = false;
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
        let ex_s: StructInfo = c.struct_id_map.lookup("" + expected_type);
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
        let widened_int: CompileResult = widen_int(c, val_res, expected_type);
        if (widened_int.type == expected_type) { return widened_int; }
    }
    if (expected_type == TYPE_CHAR && val_res.type == TYPE_BYTE) {
        let char_reg: String = next_reg(c);
        c.output_file.write(c.indent + char_reg + " = zext i8 " + val_res.reg + " to i32\n");
        return CompileResult(reg=char_reg, type=TYPE_CHAR, origin_type=TYPE_BYTE);
    }
    if (expected_type == TYPE_FLOAT && val_res.type == TYPE_INT) { return promote_to_float(c, val_res); }
    if (expected_type == TYPE_FLOAT && val_res.type == TYPE_LONG) { return promote_to_float(c, val_res); }
    if (expected_type == TYPE_FLOAT && val_res.type == TYPE_FLOAT32) { return promote_to_float(c, val_res); }

    if (expected_type == TYPE_GENERIC_ENUM) {
        if (val_res.type >= 100) {
            let s_info: StructInfo = c.struct_id_map.lookup("" + val_res.type);
            if (s_info is !null && s_info.is_enum) {
                return CompileResult(reg=val_res.reg, type=TYPE_GENERIC_ENUM, origin_type=val_res.type);
            }
        }
    }
    if (val_res.type == TYPE_GENERIC_ENUM && expected_type >= 100) {
        let s_info: StructInfo = c.struct_id_map.lookup("" + expected_type);
        if (s_info is !null && s_info.is_enum) {
            return CompileResult(reg=val_res.reg, type=expected_type, origin_type=origin);
        }
    }

    let ex_info: StructInfo = c.struct_id_map.lookup("" + expected_type);
    let val_info: StructInfo = c.struct_id_map.lookup("" + val_res.type);

    if (ex_info is !null && ex_info.is_interface) {
        if (val_info is !null && val_info.is_class) {
            if (interface_uses_self(ex_info)) {
                throw_type_error(pos, "interface '" + interface_diagnostic_name(c, expected_type) + "' uses Self and can only be used as a static constraint.");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            if (!class_has_interface(c, val_info, ex_info)) {
                throw_type_error(pos, "class '" + val_info.name + "' does not implement interface '" + ex_info.name + "'");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            let itable_name: String = "@itable." + val_info.name + "." + ex_info.name;
            let itable_len: Int = 0; if (ex_info.vtable is !null) { itable_len = ex_info.vtable.length(); }
            let obj_cast: String = next_reg(c);
            c.output_file.write(c.indent + obj_cast + " = bitcast " + val_info.llvm_name + "* " + val_res.reg + " to i8*\n");
            let s1: String = next_reg(c);
            let s2: String = next_reg(c);
            c.output_file.write(c.indent + s1 + " = insertvalue { i8*, i8* } undef, i8* " + obj_cast + ", 0\n");
            if (itable_len > 0) {
                let itable_ptr: String = next_reg(c);
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
            let cast_reg: String = next_reg(c);
            let src_ty: String = get_llvm_type_str(c, val_res.type);
            c.output_file.write(c.indent + cast_reg + " = bitcast " + src_ty + " " + val_res.reg + " to i8*\n");
            return CompileResult(reg=cast_reg, type=expected_type, origin_type=val_res.type, owns_ref=val_res.owns_ref, is_const_access=val_res.is_const_access);
        }
    }
    if ((val_res.type == TYPE_GENERIC_STRUCT || val_res.type == TYPE_GENERIC_CLASS) && expected_type >= 100) {
        if (c.struct_id_map.lookup("" + expected_type) is !null || c.vector_base_map.lookup("" + expected_type) is !null) {
            if (origin >= 100) {
                let compatible: Bool = origin == expected_type;
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
            } else {
                emit_erased_type_check(c, val_res.reg, expected_type, pos);
            }
            let cast_reg: String = next_reg(c);
            let dest_ty: String = get_llvm_type_str(c, expected_type);
            c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + val_res.reg + " to " + dest_ty + "\n");
            return CompileResult(reg=cast_reg, type=expected_type, origin_type=origin, owns_ref=val_res.owns_ref, is_const_access=val_res.is_const_access);
        }
    }

    if (is_pointer_type(c, expected_type) && is_pointer_type(c, val_res.type)) {
        if (is_void_ptr(c, expected_type) || is_void_ptr(c, val_res.type)) {
            let cast_reg: String = next_reg(c);
            let dest_ty: String = get_llvm_type_str(c, expected_type);
            let src_ty: String = get_llvm_type_str(c, val_res.type);
            if (dest_ty != src_ty) {
                c.output_file.write(c.indent + cast_reg + " = bitcast " + src_ty + " " + val_res.reg + " to " + dest_ty + "\n");
                return CompileResult(reg=cast_reg, type=expected_type, origin_type=origin);
            }
            return CompileResult(reg=val_res.reg, type=expected_type, origin_type=origin);
        }
    }

    if (is_void_ptr(c, expected_type)) {
        if (val_res.type == TYPE_STRING) {
            let cast_reg: String = next_reg(c);
            let dest_ty: String = get_llvm_type_str(c, expected_type);
            c.output_file.write(c.indent + cast_reg + " = bitcast %struct.$String* " + val_res.reg + " to " + dest_ty + "\n");
            return CompileResult(reg=cast_reg, type=expected_type, origin_type=val_res.type, owns_ref=val_res.owns_ref);
        }
    }

    if (is_void_ptr(c, val_res.type) && expected_type != TYPE_NULL && expected_type != TYPE_NULLPTR && !is_void_ptr(c, expected_type)) {
        if (expected_type == TYPE_STRING) {
            let cast_reg: String = next_reg(c);
            let src_ty: String = get_llvm_type_str(c, val_res.type);
            c.output_file.write(c.indent + cast_reg + " = bitcast " + src_ty + " " + val_res.reg + " to %struct.$String*\n");
            return CompileResult(reg=cast_reg, type=expected_type, origin_type=origin, owns_ref=val_res.owns_ref);
        }
    }

    if (expected_type == TYPE_GENERIC_FUNCTION) {
        if (val_res.type >= 100) {
            let f_check: SymbolInfo = c.func_ret_map.lookup("" + val_res.type);
            if (f_check is !null) {
                return CompileResult(reg=val_res.reg, type=expected_type, origin_type=val_res.type, owns_ref=val_res.owns_ref);
            }
        }
    }
    if (expected_type == TYPE_GENERIC_METHOD) {
        if (val_res.type >= 100) {
            let m_check: SymbolInfo = c.method_ret_map.lookup("" + val_res.type);
            if (m_check is !null) {
                return CompileResult(reg=val_res.reg, type=expected_type, origin_type=val_res.type, owns_ref=val_res.owns_ref);
            }
        }
    }
    if (val_res.type == TYPE_GENERIC_FUNCTION && expected_type >= 100) {
        if (c.func_ret_map.lookup("" + expected_type) is !null) {
            if (origin != 0 && !callable_types_compatible(c, origin, expected_type)) {
                throw_type_error(pos, "Cannot restore Function as " + get_type_name(c, expected_type));
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            emit_erased_type_check(c, val_res.reg, expected_type, pos);
            return CompileResult(reg=val_res.reg, type=expected_type, origin_type=origin, owns_ref=val_res.owns_ref);
        }
    }
    if (val_res.type == TYPE_GENERIC_METHOD && expected_type >= 100) {
        if (c.method_ret_map.lookup("" + expected_type) is !null) {
            if (origin != 0 && !callable_types_compatible(c, origin, expected_type)) {
                throw_type_error(pos, "Cannot restore Method as " + get_type_name(c, expected_type));
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            emit_erased_type_check(c, val_res.reg, expected_type, pos);
            return CompileResult(reg=val_res.reg, type=expected_type, origin_type=origin, owns_ref=val_res.owns_ref);
        }
    }

    if (val_res.type >= 100 && expected_type >= 100) {
        if (is_subclass(c, val_res.type, expected_type)) {
            let cast_reg: String = next_reg(c);
            let dest_ty: String = get_llvm_type_str(c, expected_type);
            let src_ty: String = get_llvm_type_str(c, val_res.type);
            c.output_file.write(c.indent + cast_reg + " = bitcast " + src_ty + " " + val_res.reg + " to " + dest_ty + "\n");
            return CompileResult(reg=cast_reg, type=expected_type, origin_type=val_res.origin_type, owns_ref=val_res.owns_ref);
        }
    }

    let expected_arr: ArrayInfo = c.array_info_map.lookup("" + expected_type);
    if (expected_arr is !null && expected_arr.size == -1) {
        let elem_type: Int = expected_arr.base_type;
        let elem_ty_str: String = get_llvm_type_str(c, elem_type);

        let val_arr: ArrayInfo = c.array_info_map.lookup("" + val_res.type);
        if (val_arr is !null && val_arr.size > 0 && val_arr.base_type == elem_type) {
            let data_ptr: String = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + val_arr.llvm_name + ", " + val_arr.llvm_name + "* " + val_res.reg + ", i32 0, i32 0\n");
            return emit_slice_copy(c, elem_type, data_ptr, "0", "" + val_arr.size, pos);
        }

        let val_vec: SymbolInfo = c.vector_base_map.lookup("" + val_res.type);
        if (val_vec is !null && val_vec.type == elem_type) {
            let vec_struct_ty: String = get_vector_llvm_type(c, elem_type);
            let size_ty: String = get_size_llvm_type();
            let size_ptr: String = next_reg(c);
            c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + vec_struct_ty + ", " + vec_struct_ty + "* " + val_res.reg + ", i32 0, i32 0\n");
            let size_val: String = next_reg(c);
            c.output_file.write(c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");
            
            let data_ptr_ptr: String = next_reg(c);
            c.output_file.write(c.indent + data_ptr_ptr + " = getelementptr inbounds " + vec_struct_ty + ", " + vec_struct_ty + "* " + val_res.reg + ", i32 0, i32 2\n");
            let data_ptr: String = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_ptr_ptr + "\n");

            let size_i32: String = size_val;
            if (size_ty != "i32") {
                size_i32 = next_reg(c);
                c.output_file.write(c.indent + size_i32 + " = trunc " + size_ty + " " + size_val + " to i32\n");
            }
            let copied: CompileResult = emit_slice_copy(c, elem_type, data_ptr, "0", size_i32, pos);
            emit_release_owned(c, val_res);
            return copied;
        }
    }

    throw_type_error(pos, "Type mismatch. Expected " + get_type_name(c, expected_type) + ", got " + get_type_name(c, val_res.type));
    return CompileResult(reg="0", type=expected_type, origin_type=expected_type);
}

func convert_to_string(c: Compiler, res: CompileResult) -> CompileResult {
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
        let widened: String = next_reg(c);
        c.output_file.write(c.indent + widened + " = sext " + get_size_llvm_type() + " " + res.reg + " to i64\n");
        res = CompileResult(reg=widened, type=TYPE_LONG);
    } else if (res.type == TYPE_INTSIZE) {
        res.type = TYPE_LONG;
    }
    if (res.type == TYPE_UINTSIZE && get_target_pointer_bits() < 64) {
        let widened: String = next_reg(c);
        c.output_file.write(c.indent + widened + " = zext " + get_size_llvm_type() + " " + res.reg + " to i64\n");
        res = CompileResult(reg=widened, type=TYPE_UINT64);
    }

    if (res.type == TYPE_INT128 || res.type == TYPE_UINT128) {
        let hook_name: String = "format_int128";
        if (res.type == TYPE_UINT128) {
            hook_name = "format_uint128";
        }
        let format_hook: String = get_mangled_symbol(c, hook_name, null);
        let result: String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + format_hook + "(i128 " + res.reg + ")\n");
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    if (res.type == TYPE_UINT64 || res.type == TYPE_UINTSIZE) {
        let format_hook: String = get_mangled_symbol(c, "format_uint64", null);
        let result: String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + format_hook + "(i64 " + res.reg + ")\n");
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    if (res.type == TYPE_INT || res.type == TYPE_BYTE) {
        let val_reg: String = res.reg;
        if (res.type == TYPE_BYTE) {
            val_reg = next_reg(c);
            c.output_file.write(c.indent + val_reg + " = zext i8 " + res.reg + " to i32\n");
        }

        let format_hook: String = get_mangled_symbol(c, "format_int", null);
        let result: String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + format_hook + "(i32 " + val_reg + ")\n");
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    if (res.type == TYPE_LONG) {
        let format_hook: String = get_mangled_symbol(c, "format_long", null);
        let result: String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + format_hook + "(i64 " + res.reg + ")\n");
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    if (res.type == TYPE_FLOAT) {
        let format_hook: String = get_mangled_symbol(c, "format_float", null);
        let result: String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + format_hook + "(double " + res.reg + ")\n");
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    if (res.type == TYPE_BOOL) {
        let true_id: Int = register_string_constant(c, "true");
        let false_id: Int = register_string_constant(c, "false");
        let result: String = next_reg(c);
        c.output_file.write(c.indent + result + " = select i1 " + res.reg + ", %struct.$String* " + get_string_object_ptr(true_id) + ", %struct.$String* " + get_string_object_ptr(false_id) + "\n");
        return CompileResult(reg=result, type=TYPE_STRING);
    }

    if (res.type == TYPE_CHAR) {
        let format_hook: String = get_mangled_symbol(c, "utf8_encode_char", null);
        let result: String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + format_hook + "(i32 " + res.reg + ")\n");
        return CompileResult(reg=result, type=TYPE_STRING, owns_ref=true);
    }

    // fallback for null uses an immortal string literal and requires no allocation.
    let null_id: Int = register_string_constant(c, "null");
    return CompileResult(reg=get_string_object_ptr(null_id), type=TYPE_STRING);
}

func integer_max_literal(type_id: Int) -> String {
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

func signed_negative_limit(type_id: Int) -> UInt128 {
    if (type_id == TYPE_INT8) { return UInt128(128); }
    if (type_id == TYPE_INT16) { return UInt128(32768); }
    if (type_id == TYPE_INT) { return UInt128(2147483648UL); }
    if (type_id == TYPE_INTSIZE && get_target_pointer_bits() == 32) { return UInt128(2147483648UL); }
    if (type_id == TYPE_LONG || type_id == TYPE_INTSIZE) { return UInt128(9223372036854775808UL); }
    if (type_id == TYPE_INT128) { return 170141183460469231731687303715884105728ULL; }
    return UInt128(0);
}

func positive_integer_limit(type_id: Int) -> UInt128 {
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

func float_integer_limit(type_id: Int) -> Float {
    let bits: Int = get_type_bitwidth(type_id);
    if (is_signed_integer(type_id)) { bits -= 1; }
    let limit: Float = 1.0;
    let i: Int = 0;
    while (i < bits) {
        limit *= 2.0;
        i += 1;
    }
    return limit;
}

func is_numeric_literal_expression(node: Struct) -> Bool {
    if (node is null) { return false; }
    let base: BaseNode = node;
    if (base.type == NODE_INT || base.type == NODE_FLOAT ||
        base.type == NODE_CHAR || base.type == NODE_BOOL) {
        return true;
    }
    if (base.type == NODE_UNARYOP) {
        let unary: UnaryOpNode = node;
        if (unary.op_tok.type == TOK_PLUS || unary.op_tok.type == TOK_SUB) {
            return is_numeric_literal_expression(unary.node);
        }
    }
    return false;
}

func validate_explicit_literal_cast(node: Struct, target_type: Int, pos: Position) -> Bool {
    if (node is null) { return true; }
    let base: BaseNode = node;
    let magnitude: UInt128 = UInt128(0);
    let negative: Bool = false;
    let literal_text: String = "";
    let is_float_literal: Bool = false;
    let float_value: Float = 0.0;

    if (base.type == NODE_INT) {
        let integer: IntNode = node;
        literal_text = integer.tok.value;
        magnitude = parse_const_uint128(integer.tok.value, integer.pos);
    } else if (base.type == NODE_FLOAT) {
        let float_node: FloatNode = node;
        literal_text = float_node.tok.value;
        float_value = parse_decimal_float_literal(float_node.tok.value);
        is_float_literal = true;
    } else if (base.type == NODE_CHAR) {
        let char_node: CharNode = node;
        literal_text = "'" + char_node.tok.value + "'";
        magnitude = UInt128(string_to_int(char_node.tok.value, char_node.pos));
    } else if (base.type == NODE_BOOL) {
        return true;
    } else if (base.type == NODE_UNARYOP) {
        let unary: UnaryOpNode = node;
        let inner_base: BaseNode = unary.node;
        if (unary.op_tok.type != TOK_SUB) { return true; }
        if (inner_base.type == NODE_INT) {
            let integer: IntNode = unary.node;
            literal_text = "-" + integer.tok.value;
            magnitude = parse_const_uint128(integer.tok.value, integer.pos);
            negative = magnitude != UInt128(0);
        } else if (inner_base.type == NODE_FLOAT) {
            let float_node: FloatNode = unary.node;
            literal_text = "-" + float_node.tok.value;
            float_value = 0.0 - parse_decimal_float_literal(float_node.tok.value);
            is_float_literal = true;
        } else {
            return true;
        }
    } else {
        return true;
    }

    let target_name: String = get_type_name(null, target_type);
    if is_float_literal {
        if (!is_integer_type(target_type) && target_type != TYPE_BOOL) { return true; }
        let valid: Bool = true;
        if (target_type == TYPE_BOOL) {
            valid = float_value == 0.0 || float_value == 1.0;
        } else if (target_type == TYPE_CHAR) {
            valid = float_value >= 0.0 && float_value < 1114112.0 &&
                    (float_value < 55296.0 || float_value >= 57344.0);
        } else {
            let limit: Float = float_integer_limit(target_type);
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
        let max_value: UInt128 = positive_integer_limit(target_type);
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
    let limit: UInt128 = signed_negative_limit(target_type);
    if (limit != UInt128(0) && magnitude > limit) {
        throw_overflow_error(pos, "Constant " + literal_text + " overflows " + target_name);
        return false;
    }
    return true;
}

func integer_upper_bound(type_id: Int) -> String {
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

func integer_lower_bound(type_id: Int) -> String {
    if (is_unsigned_integer(type_id)) { return "0.0"; }
    if (type_id == TYPE_INT8) { return "-128.0"; }
    if (type_id == TYPE_INT16) { return "-32768.0"; }
    if (type_id == TYPE_INT) { return "-2147483648.0"; }
    if (type_id == TYPE_INTSIZE && get_target_pointer_bits() == 32) { return "-2147483648.0"; }
    if (type_id == TYPE_LONG || type_id == TYPE_INTSIZE) { return "-9223372036854775808.0"; }
    if (type_id == TYPE_INT128) { return "-170141183460469231731687303715884105728.0"; }
    return "0.0";
}

func append_cast_condition(c: Compiler, current: String, next: String) -> String {
    if (current.length() == 0) { return next; }
    let combined: String = next_reg(c);
    c.output_file.write(c.indent + combined + " = and i1 " + current + ", " + next + "\n");
    return combined;
}

func emit_integer_cast_check(c: Compiler, value: String, source_type: Int, target_type: Int) -> String {
    let llvm_type: String = get_llvm_type_str(c, source_type);
    let signed_source: Bool = is_signed_integer(source_type);
    let source_bits: Int = get_type_bitwidth(source_type);
    let target_bits: Int = get_type_bitwidth(target_type);
    let valid: String = "";

    if (target_type == TYPE_BOOL) {
        let is_zero: String = next_reg(c);
        let is_one: String = next_reg(c);
        let result: String = next_reg(c);
        c.output_file.write(c.indent + is_zero + " = icmp eq " + llvm_type + " " + value + ", 0\n");
        c.output_file.write(c.indent + is_one + " = icmp eq " + llvm_type + " " + value + ", 1\n");
        c.output_file.write(c.indent + result + " = or i1 " + is_zero + ", " + is_one + "\n");
        return result;
    }

    if (target_type == TYPE_CHAR) {
        if signed_source {
            let non_negative: String = next_reg(c);
            c.output_file.write(c.indent + non_negative + " = icmp sge " + llvm_type + " " + value + ", 0\n");
            valid = append_cast_condition(c, valid, non_negative);
        }
        if (source_bits >= 32) {
            let below_limit: String = next_reg(c);
            let predicate: String = "ule";
            if signed_source {
                predicate = "sle";
            }

            c.output_file.write(c.indent + below_limit + " = icmp " + predicate + " " + llvm_type + " " + value + ", 1114111\n");
            valid = append_cast_condition(c, valid, below_limit);
        }
        let can_reach_surrogates: Bool = source_bits >= 32 ||
            (!signed_source && source_bits >= 16);
        if can_reach_surrogates {
            let below_surrogates: String = next_reg(c);
            let above_surrogates: String = next_reg(c);
            let outside_surrogates: String = next_reg(c);
            let less_predicate: String = "ult";
            let greater_predicate: String = "ugt";
            if signed_source {
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

    let source_unsigned: Bool = is_unsigned_integer(source_type);
    let target_unsigned: Bool = is_unsigned_integer(target_type);
    if (!source_unsigned && target_unsigned) {
        let non_negative: String = next_reg(c);
        c.output_file.write(c.indent + non_negative + " = icmp sge " + llvm_type + " " + value + ", 0\n");
        valid = append_cast_condition(c, valid, non_negative);
        if (target_bits < source_bits) {
            let below_max: String = next_reg(c);
            c.output_file.write(c.indent + below_max + " = icmp sle " + llvm_type + " " + value + ", " + integer_max_literal(target_type) + "\n");
            valid = append_cast_condition(c, valid, below_max);
        }
    } else if (source_unsigned && !target_unsigned) {
        let below_max: String = next_reg(c);
        c.output_file.write(c.indent + below_max + " = icmp ule " + llvm_type + " " + value + ", " + integer_max_literal(target_type) + "\n");
        valid = append_cast_condition(c, valid, below_max);
    } else if (source_bits > target_bits) {
        let below_max: String = next_reg(c);
        let predicate: String = "ule";
        if signed_source { predicate = "sle"; }
        c.output_file.write(c.indent + below_max + " = icmp " + predicate + " " + llvm_type + " " + value + ", " + integer_max_literal(target_type) + "\n");
        valid = append_cast_condition(c, valid, below_max);
        if signed_source {
            let above_min: String = next_reg(c);
            c.output_file.write(c.indent + above_min + " = icmp sge " + llvm_type + " " + value + ", " + get_signed_min_literal(target_type) + "\n");
            valid = append_cast_condition(c, valid, above_min);
        }
    }

    if (valid.length() == 0) { return "true"; }
    return valid;
}

func emit_float_cast_check(c: Compiler, value: String, source_type: Int, target_type: Int) -> String {
    let llvm_type: String = get_llvm_type_str(c, source_type);
    if (target_type == TYPE_BOOL) {
        let is_zero: String = next_reg(c);
        let is_one: String = next_reg(c);
        let valid: String = next_reg(c);
        c.output_file.write(c.indent + is_zero + " = fcmp oeq " + llvm_type + " " + value + ", 0.0\n");
        c.output_file.write(c.indent + is_one + " = fcmp oeq " + llvm_type + " " + value + ", 1.0\n");
        c.output_file.write(c.indent + valid + " = or i1 " + is_zero + ", " + is_one + "\n");
        return valid;
    }

    let valid: String = "";
    let lower: String = next_reg(c);
    let upper: String = next_reg(c);
    let lower_bound: String = integer_lower_bound(target_type);
    let upper_bound: String = integer_upper_bound(target_type);
    if (target_type == TYPE_CHAR) {
        lower_bound = "0.0";
        upper_bound = "1114112.0";
    }
    c.output_file.write(c.indent + lower + " = fcmp oge " + llvm_type + " " + value + ", " + lower_bound + "\n");
    c.output_file.write(c.indent + upper + " = fcmp olt " + llvm_type + " " + value + ", " + upper_bound + "\n");
    valid = append_cast_condition(c, valid, lower);
    valid = append_cast_condition(c, valid, upper);

    if (target_type == TYPE_CHAR) {
        let before_surrogates: String = next_reg(c);
        let after_surrogates: String = next_reg(c);
        let outside_surrogates: String = next_reg(c);
        c.output_file.write(c.indent + before_surrogates + " = fcmp olt " + llvm_type + " " + value + ", 55296.0\n");
        c.output_file.write(c.indent + after_surrogates + " = fcmp oge " + llvm_type + " " + value + ", 57344.0\n");
        c.output_file.write(c.indent + outside_surrogates + " = or i1 " + before_surrogates + ", " + after_surrogates + "\n");
        valid = append_cast_condition(c, valid, outside_surrogates);
    }
    return valid;
}

func standard_overflow_error(c: Compiler, pos: Position) -> CompileResult {
    let i: Int = 0;
    while (i < c.error_types.length()) {
        let info: StructInfo = c.error_types[i];
        if (info.compiler_link_name == "Error") {
            let field: FieldInfo = find_field(info, "Overflow");
            if (field is !null) {
                return emit_error_value(c, CompileResult(reg="" + field.offset, type=info.type_id, origin_type=info.type_id), pos);
            }
        }
        i += 1;
    }
    throw_internal_compiler_error(pos, "The standard Error enum does not define Overflow.");
    return CompileResult(reg="zeroinitializer", type=TYPE_ANY_ERROR);
}

func emit_fallible_cast(c: Compiler, value: CompileResult, valid: String, target_type: Int, pos: Position) -> CompileResult {
    let fail_label: String = next_label(c);
    let success_label: String = next_label(c);
    let end_label: String = next_label(c);
    let fallible_type: Int = get_fallible_type_id(c, target_type);
    let fallible_llvm: String = get_llvm_type_str(c, fallible_type);
    let target_llvm: String = get_llvm_type_str(c, target_type);

    c.output_file.write(c.indent + "br i1 " + valid + ", label %" + success_label + ", label %" + fail_label + "\n");

    c.output_file.write("\n" + fail_label + ":\n");
    let error_value: CompileResult = standard_overflow_error(c, pos);
    let fail_1: String = next_reg(c);
    let fail_2: String = next_reg(c);
    c.output_file.write(c.indent + fail_1 + " = insertvalue " + fallible_llvm + " undef, i1 true, 0\n");
    c.output_file.write(c.indent + fail_2 + " = insertvalue " + fallible_llvm + " " + fail_1 + ", { i64, i32 } " + error_value.reg + ", 1\n");
    c.output_file.write(c.indent + "br label %" + end_label + "\n");

    c.output_file.write("\n" + success_label + ":\n");
    let converted: CompileResult = compile_type_cast(c, value, target_type, pos);
    let success_1: String = next_reg(c);
    let success_2: String = next_reg(c);
    let success_3: String = next_reg(c);
    c.output_file.write(c.indent + success_1 + " = insertvalue " + fallible_llvm + " undef, i1 false, 0\n");
    c.output_file.write(c.indent + success_2 + " = insertvalue " + fallible_llvm + " " + success_1 + ", { i64, i32 } zeroinitializer, 1\n");
    c.output_file.write(c.indent + success_3 + " = insertvalue " + fallible_llvm + " " + success_2 + ", " + target_llvm + " " + converted.reg + ", 2\n");
    c.output_file.write(c.indent + "br label %" + end_label + "\n");

    c.output_file.write("\n" + end_label + ":\n");
    let result: String = next_reg(c);
    c.output_file.write(c.indent + result + " = phi " + fallible_llvm + " [ " + fail_2 + ", %" + fail_label + " ], [ " + success_3 + ", %" + success_label + " ]\n");
    return CompileResult(reg=result, type=fallible_type, origin_type=0, owns_ref=false);
}

func unwrap_conversion_or_panic(c: Compiler, value: CompileResult, source_type: Int, target_type: Int, pos: Position) -> CompileResult {
    let fallible_llvm: String = get_llvm_type_str(c, value.type);
    let failed: String = next_reg(c);
    let fail_label: String = next_label(c);
    let success_label: String = next_label(c);
    c.output_file.write(c.indent + failed + " = extractvalue " + fallible_llvm + " " + value.reg + ", 0\n");
    c.output_file.write(c.indent + "br i1 " + failed + ", label %" + fail_label + ", label %" + success_label + "\n");

    c.output_file.write("\n" + fail_label + ":\n");
    emit_runtime_error(c, pos, "conversion from " + get_type_name(c, source_type) + " to " + get_type_name(c, target_type) + " failed");

    c.output_file.write("\n" + success_label + ":\n");
    let result: String = next_reg(c);
    c.output_file.write(c.indent + result + " = extractvalue " + fallible_llvm + " " + value.reg + ", 2\n");
    return CompileResult(reg=result, type=target_type, origin_type=0, owns_ref=value.owns_ref && needs_drop(c, target_type));
}

func compile_explicit_type_cast(c: Compiler, value: CompileResult, target_type: Int, pos: Position, preserve_failure: Bool) -> CompileResult {
    if (value.type == TYPE_POISON) { return value; }

    if (value.type == TYPE_ANY_ERROR && is_integer_type(target_type)) {
        let code: String = next_reg(c);
        c.output_file.write(c.indent + code + " = extractvalue { i64, i32 } " + value.reg + ", 1\n");
        return compile_explicit_type_cast(c, CompileResult(reg=code, type=TYPE_INT), target_type, pos, preserve_failure);
    }

    if (!needs_explicit_cast(c, value.type, target_type)) {
        return compile_type_cast(c, value, target_type, pos);
    }

    let check_type: Int = value.type;
    let source_info: StructInfo = c.struct_id_map.lookup("" + check_type);
    if (source_info is !null && source_info.is_enum) { check_type = TYPE_INT; }

    let valid: String = "";
    if (is_integer_type(check_type)) {
        valid = emit_integer_cast_check(c, value.reg, check_type, target_type);
    } else if (check_type == TYPE_FLOAT || check_type == TYPE_FLOAT32) {
        valid = emit_float_cast_check(c, value.reg, check_type, target_type);
    } else {
        return compile_type_cast(c, value, target_type, pos);
    }

    if preserve_failure {
        return emit_fallible_cast(c, value, valid, target_type, pos);
    }

    let fail_label: String = next_label(c);
    let success_label: String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + valid + ", label %" + success_label + ", label %" + fail_label + "\n");
    c.output_file.write("\n" + fail_label + ":\n");
    emit_runtime_error(c, pos, "conversion from " + get_type_name(c, value.type) + " to " + get_type_name(c, target_type) + " is out of range");
    c.output_file.write("\n" + success_label + ":\n");
    return compile_type_cast(c, value, target_type, pos);
}

func compile_type_cast(c: Compiler, val_res: CompileResult, target_type: Int, pos: Position) -> CompileResult {
    if (val_res.type == TYPE_POISON) { return val_res; }
    if (val_res.type == target_type) { return val_res; }

    let src_ty_str: String = get_llvm_type_str(c, val_res.type);
    let dst_ty_str: String = get_llvm_type_str(c, target_type);
    let res_reg: String = next_reg(c);

    if (target_type == TYPE_STRING) {
        return convert_to_string(c, val_res);
    }

    if (val_res.type == TYPE_ANY_ERROR && is_integer_type(target_type)) {
        let code: String = next_reg(c);
        c.output_file.write(c.indent + code + " = extractvalue { i64, i32 } " + val_res.reg + ", 1\n");
        return compile_type_cast(c, CompileResult(reg=code, type=TYPE_INT), target_type, pos);
    }

    let src_is_float: Bool = val_res.type == TYPE_FLOAT || val_res.type == TYPE_FLOAT32;
    let dst_is_float: Bool = target_type == TYPE_FLOAT || target_type == TYPE_FLOAT32;

    let src_is_int: Bool = is_integer_type(val_res.type) || val_res.type == TYPE_BOOL;
    let dst_is_int: Bool = is_integer_type(target_type) || target_type == TYPE_BOOL;

    let src_info: StructInfo = c.struct_id_map.lookup("" + val_res.type);
    let src_is_enum: Bool = src_info is !null && src_info.is_enum;
    if (src_is_enum && is_integer_type(target_type)) {
        let dst_bits: Int = get_type_bitwidth(target_type);
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
    
    let src_is_erased_struct: Bool = val_res.type == TYPE_GENERIC_STRUCT;
    let src_is_ptr: Bool = is_pointer_type(c, val_res.type) || val_res.type == TYPE_STRING ||
                           val_res.type == TYPE_ANYPTR || val_res.type == TYPE_NULLPTR || src_is_erased_struct;
    let dst_is_ptr: Bool = is_pointer_type(c, target_type) || target_type == TYPE_STRING || target_type == TYPE_ANYPTR;

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
        let op: String = "sitofp";
        if (is_unsigned_integer(val_res.type) || val_res.type == TYPE_BOOL) { op = "uitofp"; }
        c.output_file.write(c.indent + res_reg + " = " + op + " " + src_ty_str + " " + val_res.reg + " to " + dst_ty_str + "\n");
        return CompileResult(reg=res_reg, type=target_type, origin_type=0);
    }
    if (src_is_float && dst_is_int) {
        let op: String = "fptosi";
        if (is_unsigned_integer(target_type) || target_type == TYPE_BOOL) { op = "fptoui"; }
        c.output_file.write(c.indent + res_reg + " = " + op + " " + src_ty_str + " " + val_res.reg + " to " + dst_ty_str + "\n");
        return CompileResult(reg=res_reg, type=target_type, origin_type=0);
    }

    if (src_is_int && dst_is_int) {
        let src_bits: Int = get_type_bitwidth(val_res.type);
        let dst_bits: Int = get_type_bitwidth(target_type);
        
        if (src_bits == dst_bits) {
            return CompileResult(reg=val_res.reg, type=target_type, origin_type=0);
        }
        if (src_bits > dst_bits) {
            c.output_file.write(c.indent + res_reg + " = trunc " + src_ty_str + " " + val_res.reg + " to " + dst_ty_str + "\n");
        } else {
            let op: String = "sext";
            if (is_unsigned_integer(val_res.type) || val_res.type == TYPE_BOOL) { op = "zext"; }
            c.output_file.write(c.indent + res_reg + " = " + op + " " + src_ty_str + " " + val_res.reg + " to " + dst_ty_str + "\n");
        }
        return CompileResult(reg=res_reg, type=target_type, origin_type=0);
    }

    throw_type_error(pos, "Unsupported explicit type cast.");
    return void_result();
}

