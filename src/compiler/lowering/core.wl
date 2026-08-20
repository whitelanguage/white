// compiler/lowering/core.wl
import "sys"
import "file"
import "process"
import Dict from "dict"

import * from "../../frontend/ast.wl"
import * from "../../frontend/arena.wl"
import * from "../context.wl"
import * from "../../frontend/tokens.wl"
import * from "../../frontend/diagnostics.wl"
import * from "../target.wl"
import Lexer, new_lexer, get_next_token from "../../frontend/lexer.wl"
import Parser, parse from "../../frontend/parser.wl"
import * from "dictionary.wl"
import * from "errors.wl"
import * from "../target_eval.wl"
import * from "numeric.wl"
import * from "../constants.wl"
import * from "casts.wl"
import * from "literals.wl"
import * from "../validation.wl"
import * from "../registration.wl"
import * from "ownership.wl"
import * from "../modules.wl"
import * from "../initialization.wl"
import * from "ffi.wl"
import * from "printing.wl"
import * from "../backend/windows.wl"


func compile_ast_pass(c: Compiler, p_mod: ParsedModule) -> Void {
// enum bodies go first because later declarations may use their members as constants
    c.current_file_visible_prefixes = p_mod.visible;
    c.current_file_namespaces       = p_mod.namespaces;
    c.current_file_type_aliases     = p_mod.types;
    c.current_file_func_aliases     = p_mod.funcs;
    c.current_file_global_aliases   = p_mod.globals;
    c.current_package_prefix        = p_mod.prefix;
    c.current_module_is_package     = p_mod.is_package;
    c.current_dir                   = p_mod.dir;

    let imports: Vector(NodeID) = p_mod.imports;
    let i_len: Int = 0; if (imports is !null) { i_len = imports.length(); }
    let i: Int = 0;
    while (i < i_len) {
        let imp: ImportNode = get_import_node(c.arena, imports[i]);
        if (imp.symbols is !null) {
            let raw_path: String = imp.path_tok.value;
            let final_path: String = resolve_import_path(c, raw_path, imp.pos);
            if (final_path is !null && final_path.length() > 0) {
                let loaded_module: StringConstant = c.imported_modules.lookup(final_path);
                if (has_string_constant(loaded_module)) {
                    bind_import_symbols(c, imp, loaded_module.value, true, false);
                }
            }
        }
        i += 1;
    }

    let block: BlockNode = get_block_node(c.arena, p_mod.ast);
    let stmts: Vector(NodeID) = block.stmts;
    let len: Int = 0;
    if (stmts is !null) { len = stmts.length(); }

    i = 0;
    while (i < len) {
        let base: Int = node_tag(stmts[i]);
        if (base == NODE_ENUM_DEF) {
            compile_node(c, stmts[i]);
        }
        i += 1;
    }

    i = 0;
    while (i < len) {
        let base: Int = node_tag(stmts[i]);
        if (base != NODE_IMPORT && base != NODE_ENUM_DEF) {
            compile_node(c, stmts[i]);
        }
        i += 1;
    }

    p_mod.ast = NO_NODE;
}

func discard_statement_result(c: Compiler, node: NodeID, result: CompileResult) -> Void {
    if (!has_node(node) || !has_result(result)) { return; }
    let base: Int = node_tag(node);
    if (base == NODE_VAR_ASSIGN || base == NODE_FIELD_ASSIGN || base == NODE_INDEX_ASSIGN || base == NODE_PTR_ASSIGN || base == NODE_CATCH) { return; }
    if (result.owns_ref) {
        emit_release_owned(c, result);
        result.owns_ref = false;
        return;
    }
    if (base == NODE_CALL && result_owns_value(c, result.type)) {
        emit_retain_value(c, result.reg, result.type);
        emit_drop_value(c, result.reg, result.type);
    }
}

func validate_fallible_call(c: Compiler, type_id: Int, handled: Bool, name: String, pos: Position) -> Bool {
    if (!is_fallible_type(c, type_id) || handled) { return true; }
    let message: String = "fallible call requires '?'";
    if (name is !null && name.length() > 0) { message = "call to fallible function '" + name + "' requires '?'"; }
    throw_type_error(pos, message);
    return false;
}

func compile_block(c: Compiler, node: BlockNode) -> CompileResult {
    let is_root: Bool = false;
    if (c.scope_depth == 0) {
        is_root = true;
    }

    if (!is_root) {
        enter_scope(c);
    }
    
    let stmts: Vector(NodeID) = node.stmts;
    let len: Int = 0;
    if (stmts is !null) { len = stmts.length(); }
    let i: Int = 0;
    
    let last_res: CompileResult = CompileResult();
    let terminated: Bool = false;
    while (i < len) {
        let stmt: Int = node_tag(stmts[i]);
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
            if (c.symbol_table.parent >= 0) {
                c.symbol_table = c.scope_stack[c.symbol_table.parent];
            }
            c.scope_depth -= 1;
        } else {
            exit_scope(c);
        }
    }
    
    if (!has_result(last_res)) { return void_result(); }
    return last_res;
}

func compile_var_decl(c: Compiler, node: VarDeclareNode) -> CompileResult {
    let target_type_id: Int = resolve_type(c, node.type_node);
    let const_access: Bool = node.is_const;

    if (target_type_id == TYPE_AUTO) {
        target_type_id = get_expr_type(c, node.value);
        if (target_type_id == TYPE_POISON) {
            let curr_scope: Scope = c.symbol_table;
            curr_scope.table.put(node.name_tok.value, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
            return void_result();
        }
        if (target_type_id == 0 || target_type_id == TYPE_AUTO) {
            throw_type_error(node.pos, "Failed to statically infer type for 'Auto'.");
            let curr_scope: Scope = c.symbol_table;
            curr_scope.table.put(node.name_tok.value, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
            return void_result();
        }
        if (target_type_id == TYPE_NULL || target_type_id == TYPE_NULLPTR || target_type_id == TYPE_VOID || target_type_id == TYPE_POISON) {
            throw_type_error(node.pos, "Cannot infer 'Auto' as null, Void");
            let curr_scope: Scope = c.symbol_table;
            curr_scope.table.put(node.name_tok.value, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
            return void_result();
        }
    }

    if (is_fallible_type(c, target_type_id)) {
        throw_type_error(node.pos, "Fallible values cannot be stored; handle the call with '?'");
        let curr_scope: Scope = c.symbol_table;
        curr_scope.table.put(node.name_tok.value, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
        return void_result();
    }

    if (target_type_id == TYPE_VOID || target_type_id == TYPE_POISON) {
        let curr_scope: Scope = c.symbol_table;
        curr_scope.table.put(node.name_tok.value, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
        return void_result();
    }

    let llvm_ty_str: String = get_llvm_type_str(c, target_type_id);
    let var_name: String = node.name_tok.value;

    if (c.scope_depth == 0) {
        let sys_anns: SystemAnnResult = consume_annotations(c, node.annotations, var_name);

        let full_var_name: String = var_name;
        if (c.current_package_prefix != "") {
            full_var_name = c.current_package_prefix + var_name;
        }

        if ((sys_anns.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
            let intrinsic: String = sys_anns.intrinsic_name;
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
                let target_info: StructInfo = c.struct_id_map.lookup("" + target_type_id);
                let enum_name: String = target_enum_name(intrinsic);
                if (!has_struct(target_info) || !target_info.is_enum || (target_info.name != enum_name && !target_info.name.ends_with("." + enum_name))) {
                    throw_type_error(node.pos, "Target intrinsics must use their target enum type.");
                    return void_result();
                }
            }
            c.global_symbol_table.put(full_var_name, SymbolInfo(reg="$intrinsic." + intrinsic, type=target_type_id, origin_type=target_type_id, is_const=true));
            return void_result();
        }

        let global_name: String = "@" + full_var_name;

        if ((sys_anns.ann_flags & FLAG_ANN_EXPORT) != 0) {
            global_name = "@" + var_name; 
        }

        let init_val_str: String = "0";
        let has_const_num: Bool = false;
        let const_num: Float = 0.0;
        if (is_nullable_reference_type(c, target_type_id)) { 
            let s_info: StructInfo = c.struct_id_map.lookup("" + target_type_id);
            if (has_struct(s_info) && s_info.is_interface) {
                init_val_str = "zeroinitializer";
            } else {
                init_val_str = "null"; 
            }
        } else if (is_value_struct(c, target_type_id)) {
            init_val_str = "zeroinitializer";
        }

        if (has_node(node.value)) {
            let value_node: NodeID = node.value;
            let target_repr: Int = get_repr_type(c, target_type_id);
            let named_target: NamedTypeInfo = get_named_type(c, target_type_id);
            let unwrapped_named_cast: Bool = false;
            if (has_named_type(named_target) && node_tag(value_node) == NODE_CALL) {
                let cast_call: CallNode = get_call_node(c.arena, value_node);
                if (node_tag(cast_call.callee) == NODE_VAR_ACCESS && cast_call.args is !null && cast_call.args.length() == 1) {
                    let cast_name: VarAccessNode = get_var_access_node(c.arena, cast_call.callee);
                    if (get_cast_target(c, cast_name.name_tok.value) == target_type_id) {
                        let cast_arg: ArgNode = cast_call.args[0];
                        value_node = cast_arg.val;
                        unwrapped_named_cast = true;
                    }
                }
            }
            if (has_named_type(named_target) && !unwrapped_named_cast) {
                throw_type_error(node.pos, "Type mismatch. Expected " + get_type_name(c, target_type_id) + ", got " + get_type_name(c, get_expr_type(c, value_node)) + ".");
                return void_result();
            }
            let val_node: Int = node_tag(value_node);
            if (val_node == NODE_STRING) {
                let s_node: StringNode = get_string_node(c.arena, value_node);
                let s_val: String = s_node.tok.value;
                let s_id: Int = register_string_constant(c, s_val);
                init_val_str = get_string_object_ptr(s_id);
            }
            else if (val_node == NODE_NULLPTR) {
                if (!is_pointer_type(c, target_type_id)) {
                    throw_invalid_syntax(node.pos, "Global 'nullptr' can only be assigned to pointer types.");
                    return void_result();
                }
                init_val_str = "null";
            }
            else if (val_node == NODE_NULL) {
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
            else if (is_integer_type(target_repr)) {
                let expr_type: Int = get_expr_type(c, value_node);
                if (get_type_bitwidth(target_repr) < 64 && expr_type == TYPE_LONG) {
                    throw_type_error(node.pos, "Type mismatch. Expected " + get_type_name(c, target_type_id) + ", got Long.");
                    return void_result();
                }

                let bits: Int = get_type_bitwidth(target_repr);
                if (bits == 128) {
                    let folded_wide: UInt128 = eval_const_wide(c, value_node, node.pos, is_unsigned_integer(target_repr));
                    if (is_unsigned_integer(target_repr)) {
                        init_val_str = "" + folded_wide;
                    } else {
                        init_val_str = "" + Int128(folded_wide);
                    }
                    if (node.is_const) { c.constant_wide_integers.put(global_name, folded_wide); }
                } else {
                    let folded_val: Long = eval_const_long(c, value_node, node.pos);
                    const_num = Float(folded_val);
                    has_const_num = true;
                    if (node.is_const) { c.constant_integers.put(global_name, folded_val); }
                    let is_overflow: Bool = false;
                    
                    if (bits == 8) {
                        if (is_unsigned_integer(target_repr)) {
                            if (folded_val < 0L || folded_val > 255L) { is_overflow = true; }
                        } else {
                            if (folded_val < -128L || folded_val > 127L) { is_overflow = true; }
                        }
                    } else if (bits == 16) {
                        if (is_unsigned_integer(target_repr)) {
                            if (folded_val < 0L || folded_val > 65535L) { is_overflow = true; }
                        } else {
                            if (folded_val < -32768L || folded_val > 32767L) { is_overflow = true; }
                        }
                    } else if (bits == 32) {
                        if (is_unsigned_integer(target_repr)) {
                            if (folded_val < 0L || folded_val > 4294967295L) { is_overflow = true; }
                        } else {
                            if (folded_val < -2147483648L || folded_val > 2147483647L) { is_overflow = true; }
                        }
                    }

                    if is_overflow {
                        throw_overflow_error(node.pos, "Global constant overflows " + get_type_name(c, target_type_id) + " valid range.");
                        return void_result();
                    }
                    
                    init_val_str = "" + folded_val;
                }
            }
            else if (target_repr == TYPE_CHAR) {
                if (val_node != NODE_CHAR) {
                    throw_type_error(node.pos, "Type mismatch. Expected Char literal for Char type.");
                    return void_result();
                }
                let cn: CharNode = get_char_node(c.arena, value_node);
                init_val_str = "" + string_to_int(cn.tok.value, cn.pos);
                const_num = Float(string_to_int(cn.tok.value, cn.pos));
                has_const_num = true;
                if (node.is_const) { c.constant_integers.put(global_name, Long(string_to_int(cn.tok.value, cn.pos))); }
            }
            else if (target_repr == TYPE_BOOL) {
                let folded_val: Int = eval_const_bool(c, value_node, node.pos);
                if (folded_val == 1) { init_val_str = "1"; } else { init_val_str = "0"; }
                const_num = Float(folded_val);
                has_const_num = true;
                if (node.is_const) { c.constant_integers.put(global_name, Long(folded_val)); }
            }
            else if (target_repr == TYPE_FLOAT || target_repr == TYPE_FLOAT32) {
                const_num = eval_const_float(c, value_node, node.pos);
                if (target_repr == TYPE_FLOAT32) { const_num = Float(Float32(const_num)); }
                init_val_str = llvm_float_literal(const_num);
                has_const_num = true;
            } else {
                throw_invalid_syntax(node.pos, "Global variable initialisation must be a compile-time constant expression. ");
                return void_result();
            }
        }

        let linkage: String = "";
    if (c.is_shared && get_target_os() == sys.Os.Windows) {
            if ((sys_anns.ann_flags & FLAG_ANN_EXPORT) != 0) {
                linkage = "dllexport ";
            } else {
                linkage = "hidden ";
            }
        }

        let storage: String = "global";
        if (node.is_const) { storage = "constant"; }
        c.output_file.write(global_name + " = " + linkage + storage + " " + llvm_ty_str + " " + init_val_str + "\n");
        c.global_symbol_table.put(full_var_name, SymbolInfo(reg=global_name, type=target_type_id, origin_type=target_type_id, is_const=node.is_const));
        if (node.is_const && has_const_num) { c.constant_nums.put(global_name, const_num); }
        return void_result();
    }

    let local_scope: Scope = c.symbol_table;
    if (has_symbol(local_scope.table.lookup(var_name))) {
        throw_name_error(node.pos, "Variable '" + var_name + "' is already declared in this scope");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    let ptr_reg: String = c.alloc_regs[node.alloc_id];
    let origin_id: Int = target_type_id;

    if (!has_node(node.value)) {
        let s_info: StructInfo = c.struct_id_map.lookup("" + target_type_id);
        let is_valid_struct: Bool = false;
        
        if (has_struct(s_info)) {
            if (!has_array_info(c.array_info_map.lookup("" + target_type_id)) && 
                !has_symbol(c.vector_base_map.lookup("" + target_type_id)) && 
                !has_symbol(c.func_ret_map.lookup("" + target_type_id)) &&
                !s_info.is_enum) {
                is_valid_struct = true;
            }
        }

        if is_valid_struct {
            let fake_args: Vector(ArgNode) = [];
            let fake_call: CallNode = CallNode(type=NODE_CALL, callee=NO_NODE, args=fake_args, type_args=null, pos=node.pos, preserve_fallible=false);
            let val_res: CompileResult = CompileResult();
            
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
            let curr_scope: Scope = c.symbol_table;
            curr_scope.table.put(node.name_tok.value, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
            return void_result();
        }
    } else {
        let is_array_init: Bool = false;
        let val_base: Int = node_tag(node.value);
        let target_arr: ArrayInfo = c.array_info_map.lookup("" + target_type_id);
        if (has_array_info(target_arr) && val_base == NODE_VECTOR_LIT) {
            if (target_arr.size == -1) {
                throw_type_error(node.pos, "Cannot initialise Array(Type) slice directly from a literal.");
                return void_result();
            }

            is_array_init = true;
            let lit_node: VectorLitNode = get_vector_lit_node(c.arena, node.value);
            
            if (lit_node.count > target_arr.size) {
                throw_type_error(node.pos, "Array literal too large: expected " + target_arr.size + " elements.");
                return void_result();
            }

            compile_array_literal(c, lit_node, target_type_id, ptr_reg);
        }

        if (!is_array_init) {
            c.expected_type = target_type_id;
            let val_res: CompileResult = compile_node(c, node.value);
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

    let curr_scope: Scope = c.symbol_table;
    curr_scope.table.put(var_name, SymbolInfo(reg=ptr_reg, type=target_type_id, origin_type=origin_id, is_const=node.is_const, is_const_access=const_access));

    if (c.scope_depth > 0) {
        if (needs_drop(c, target_type_id)) {
            curr_scope.gc_vars.append(GCTracker(reg = ptr_reg, type = target_type_id));
        }
    }

    return void_result(); 
}
func compile_var_assign(c: Compiler, node: VarAssignNode) -> CompileResult {
    let var_name: String = node.name_tok.value;
    let info: SymbolInfo = find_symbol(c, var_name);
    if (!has_symbol(info)) {
        throw_name_error(node.pos, "Undefined variable '" + var_name + "'.");
        let curr_scope: Scope = c.symbol_table;
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
    let val_res: CompileResult = compile_node(c, node.value);
    c.expected_type = 0;

    val_res = emit_implicit_cast(c, val_res, info.type, node.pos);
    info.is_const_access = val_res.is_const_access;

    if (result_owns_value(c, info.type)) {
        if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, info.type); }
        emit_drop_slot(c, info.reg, info.type);
    }
    
    let ty_str: String = get_llvm_type_str(c, info.type);
    c.output_file.write(c.indent + "store " + ty_str + " " + val_res.reg + ", " + ty_str + "* " + info.reg + "\n");
    return val_res; 
}

func compile_if(c: Compiler, node: IfNode) -> CompileResult {
    let platform_value: Int = fold_target_cond(c, node.condition);
    if (platform_value == 1) {
        compile_node(c, node.body);
        return void_result();
    }
    if (platform_value == 0) {
        if (has_node(node.else_body)) { compile_node(c, node.else_body); }
        return void_result();
    }

    let cond_res: CompileResult = compile_node(c, node.condition);
    if (has_result(cond_res) && cond_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    if (cond_res.type != TYPE_BOOL) {
        throw_type_error(node.pos, "If condition must be a Bool. ");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    
    let label_then: String = next_label(c);
    let label_else: String = next_label(c);
    let label_merge: String = next_label(c);

    let then_terminates: Bool = must_terminate(c, node.body);
    let else_terminates: Bool = false;
    if (has_node(node.else_body)) {
        else_terminates = must_terminate(c, node.else_body);
    }

    let needs_merge: Bool = true;
    if (has_node(node.else_body) && then_terminates && else_terminates) {
        needs_merge = false;
    }
    
    let target_else: String = label_else;
    if (!has_node(node.else_body)) {
        target_else = label_merge;
    }
    
    c.output_file.write(c.indent + "br i1 " + cond_res.reg + ", label %" + label_then + ", label %" + target_else + "\n");
    
    c.output_file.write("\n" + label_then + ":\n");
    compile_node(c, node.body);
    if (!then_terminates) {
        c.output_file.write(c.indent + "br label %" + label_merge + "\n");
    }
    
    if (has_node(node.else_body)) {
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

func compile_while(c: Compiler, node_id: NodeID) -> CompileResult {
    let node: WhileNode = get_while_node(c.arena, node_id);
    let label_cond: String = next_label(c);
    let label_body: String = next_label(c);
    let label_end: String = next_label(c);

    let current_scope: LoopScope = LoopScope(label_continue=label_cond, label_break=label_end, parent=c.loop_stack, loop_scope=c.symbol_table);
    c.loop_stack = current_scope;

    c.output_file.write(c.indent + "br label %" + label_cond + "\n");
    c.output_file.write("\n" + label_cond + ":\n");
    
    let cond_res: CompileResult = compile_node(c, node.condition);
    if (has_result(cond_res) && cond_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
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
    if (must_terminate(c, node_id)) {
        c.output_file.write(c.indent + "unreachable\n");
    }
    c.loop_stack = current_scope.parent;
    return void_result();
}

func compile_for(c: Compiler, node_id: NodeID) -> CompileResult {
    let node: ForNode = get_for_node(c.arena, node_id);
    enter_scope(c);
    if (has_node(node.init)) {
        let init_res: CompileResult = compile_node(c, node.init);
        discard_statement_result(c, node.init, init_res);
    }
    let label_cond: String = next_label(c);
    let label_body: String = next_label(c);
    let label_step: String = next_label(c);
    let label_end: String = next_label(c);

    let current_scope: LoopScope = LoopScope(label_continue=label_step, label_break=label_end, parent=c.loop_stack, loop_scope=c.symbol_table);
    c.loop_stack = current_scope;
    
    c.output_file.write(c.indent + "br label %" + label_cond + "\n");
    c.output_file.write("\n" + label_cond + ":\n");
    if (has_node(node.cond)) {
        let cond_res: CompileResult = compile_node(c, node.cond);
        if (has_result(cond_res) && cond_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
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
    if (has_node(node.step)) {
        let step_res: CompileResult = compile_node(c, node.step);
        discard_statement_result(c, node.step, step_res);
    }
    c.output_file.write(c.indent + "br label %" + label_cond + "\n");
    c.output_file.write("\n" + label_end + ":\n");
    c.loop_stack = current_scope.parent;
    exit_scope(c);
    if (must_terminate(c, node_id)) { c.output_file.write(c.indent + "unreachable\n"); }
    
    return void_result();
}

func compile_ptr_assign(c: Compiler, node: PtrAssignNode) -> CompileResult {
    let d_node: DerefNode = get_deref_node(c.arena, node.pointer);
    if (reject_const_write(c, d_node.node, node.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let ptr_res: CompileResult = compile_node(c, d_node.node);

    let i: Int = 0;
    let curr_reg: String = ptr_res.reg;
    let curr_type: Int = ptr_res.type;

    while (i < d_node.level - 1) {
        if (curr_type == TYPE_NULL) { 
            throw_type_error(node.pos, "Cannot dereference 'nullptr'.");
            return void_result(); 
        }
        let base_info: SymbolInfo = c.ptr_base_map.lookup("" + curr_type);
        if (!has_symbol(base_info)) { 
            throw_type_error(node.pos, "Cannot dereference non-pointer.");
            return void_result(); 
        }
        
        let next_type: Int = base_info.type;
        if (next_type == TYPE_VOID) {
            throw_type_error(d_node.pos, "Cannot dereference 'ptr Void'. Cast it to a specific pointer type first.");
            return void_result();
        }
        emit_pointer_null_check(c, curr_reg, curr_type, node.pos);
        let ty_str: String = get_llvm_type_str(c, next_type);
        let next_reg: String = next_reg(c);
        c.output_file.write(c.indent + next_reg + " = load " + ty_str + ", " + ty_str + "* " + curr_reg + "\n");
        
        curr_reg = next_reg;
        curr_type = next_type;
        i += 1;
    }

    if (curr_type == TYPE_NULL) {
        throw_null_dereference_error(node.pos, "Cannot dereference 'nullptr'. ");
        return void_result();
    }

    let final_base_info: SymbolInfo = c.ptr_base_map.lookup("" + curr_type);
    if (!has_symbol(final_base_info)) { 
        throw_type_error(node.pos, "Cannot assign to non-pointer.");
        return void_result(); 
    }
    
    let target_type_id: Int = final_base_info.type;
    emit_pointer_null_check(c, curr_reg, curr_type, node.pos);

    c.expected_type = target_type_id;
    let val_res: CompileResult = compile_node(c, node.value);
    c.expected_type = 0;
    
    val_res = emit_implicit_cast(c, val_res, target_type_id, node.pos);
    
    let llvm_ty: String = get_llvm_type_str(c, target_type_id);

    if (result_owns_value(c, target_type_id)) {
        if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, target_type_id); }
        emit_drop_slot(c, curr_reg, target_type_id);
    }
    
    c.output_file.write(c.indent + "store " + llvm_ty + " " + val_res.reg + ", " + llvm_ty + "* " + curr_reg + "\n");

    return val_res;
}

func emit_print_text(c: Compiler, value: CompileResult, fallback: String, pos: Position) -> Void {
    if (has_result(value)) {
        compile_print(c, value.reg, TYPE_STRING, pos, TYPE_STRING);
        return;
    }
    let hook: String = get_mangled_symbol(c, "print_bytes", pos);
    let id: Int = register_string_constant(c, fallback);
    c.output_file.write(c.indent + "call void @" + hook + "(i8* " + get_string_ptr(id, fallback) + ", i32 " + fallback.length() + ")\n");
}

func emit_print_item(c: Compiler, reg: String, type_id: Int, origin_id: Int, printed: String, separator: CompileResult, pos: Position) -> Void {
    let has_value: String = next_reg(c);
    c.output_file.write(c.indent + has_value + " = load i1, i1* " + printed + "\n");
    let separator_label: String = next_label(c);
    let value_label: String = next_label(c);
    let done_label: String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + has_value + ", label %" + separator_label + ", label %" + value_label + "\n");
    c.output_file.write("\n" + separator_label + ":\n");
    emit_print_text(c, separator, " ", pos);
    c.output_file.write(c.indent + "br label %" + value_label + "\n");
    c.output_file.write("\n" + value_label + ":\n");
    compile_print(c, reg, type_id, pos, origin_id);
    c.output_file.write(c.indent + "store i1 true, i1* " + printed + "\n");
    c.output_file.write(c.indent + "br label %" + done_label + "\n");
    c.output_file.write("\n" + done_label + ":\n");
}

func compile_print_call(c: Compiler, node: CallNode) -> CompileResult {
    let values: Vector(Struct) = [];
    let separator: CompileResult = CompileResult();
    let ending: CompileResult = CompileResult();
    let saw_named: Bool = false;
    let i: Int = 0;
    while (node.args is !null && i < node.args.length()) {
        let arg: ArgNode = node.args[i];
        if (arg.name is !null && arg.name.length() > 0) {
            saw_named = true;
            if (arg.name != "sep" && arg.name != "end") {
                throw_name_error(node.pos, "Unknown print argument '" + arg.name + "'.");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            if ((arg.name == "sep" && has_result(separator)) || (arg.name == "end" && has_result(ending))) {
                throw_name_error(node.pos, "Argument '" + arg.name + "' is specified more than once.");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            let old_expected: Int = c.expected_type;
            c.expected_type = TYPE_STRING;
            let text: CompileResult = compile_node(c, arg.val);
            c.expected_type = old_expected;
            text = emit_implicit_cast(c, text, TYPE_STRING, node.pos);
            if (text.type == TYPE_POISON) { return text; }
            if (arg.name == "sep") { separator = text; }
            else { ending = text; }
            i += 1;
            continue;
        }
        if saw_named {
            throw_invalid_syntax(node.pos, "Positional argument cannot follow a named argument.");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }

        let old_expected: Int = c.expected_type;
        c.expected_type = 0;
        let value: CompileResult = compile_node(c, arg.val);
        c.expected_type = old_expected;
        if (!has_result(value) || value.type == TYPE_POISON) {
            return CompileResult(reg="poison", type=TYPE_POISON);
        }

        let length: String = "1";
        let data: String = "";
        let elem_type: Int = value.type;
        if (arg.is_spread) {
            let array_info: ArrayInfo = c.array_info_map.lookup("" + value.type);
            let vector_info: SymbolInfo = c.vector_base_map.lookup("" + value.type);
            let size_ty: String = get_size_llvm_type();
            if (has_array_info(array_info)) {
                elem_type = array_info.base_type;
                let elem_ty: String = get_llvm_type_str(c, elem_type);
                if (array_info.size == -1) {
                    let parts: SliceParts = emit_slice_parts(c, value.reg, value.type, node.pos);
                    length = parts.length;
                    data = next_reg(c);
                    c.output_file.write(c.indent + data + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + parts.data + ", " + size_ty + " " + parts.start + "\n");
                } else {
                    length = "" + array_info.size;
                    data = next_reg(c);
                    c.output_file.write(c.indent + data + " = getelementptr inbounds " + array_info.llvm_name + ", " + array_info.llvm_name + "* " + value.reg + ", i32 0, i32 0\n");
                }
            } else if (has_symbol(vector_info)) {
                elem_type = vector_info.type;
                let elem_ty: String = get_llvm_type_str(c, elem_type);
                let vector_ty: String = get_vector_llvm_type(c, elem_type);
                let size_slot: String = next_reg(c);
                c.output_file.write(c.indent + size_slot + " = getelementptr inbounds " + vector_ty + ", " + vector_ty + "* " + value.reg + ", i32 0, i32 0\n");
                length = next_reg(c);
                c.output_file.write(c.indent + length + " = load " + size_ty + ", " + size_ty + "* " + size_slot + "\n");
                let data_slot: String = next_reg(c);
                c.output_file.write(c.indent + data_slot + " = getelementptr inbounds " + vector_ty + ", " + vector_ty + "* " + value.reg + ", i32 0, i32 2\n");
                data = next_reg(c);
                c.output_file.write(c.indent + data + " = load " + elem_ty + "*, " + elem_ty + "** " + data_slot + "\n");
            } else {
                throw_type_error(node.pos, "Only an Array or Vector can be expanded into print.");
                emit_release_owned(c, value);
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
        }
        if (!is_printable_type(c, elem_type)) {
            throw_type_error(node.pos, "Type " + get_type_name(c, elem_type) + " cannot be printed.");
            emit_release_owned(c, value);
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        values.append(PrintArgument(value=value, spread=arg.is_spread, length=length, data=data, elem_type=elem_type));
        i += 1;
    }

    let printed: String = next_reg(c);
    c.output_file.write(c.indent + printed + " = alloca i1\n");
    c.output_file.write(c.indent + "store i1 false, i1* " + printed + "\n");
    i = 0;
    while (i < values.length()) {
        let item: PrintArgument = values[i];
        if (!item.spread) {
            emit_print_item(c, item.value.reg, item.elem_type, item.value.origin_type, printed, separator, node.pos);
        } else {
            let size_ty: String = get_size_llvm_type();
            let elem_ty: String = get_llvm_type_str(c, item.elem_type);
            let index: String = next_reg(c);
            c.output_file.write(c.indent + index + " = alloca " + size_ty + "\n");
            c.output_file.write(c.indent + "store " + size_ty + " 0, " + size_ty + "* " + index + "\n");
            let cond_label: String = next_label(c);
            let body_label: String = next_label(c);
            let done_label: String = next_label(c);
            c.output_file.write(c.indent + "br label %" + cond_label + "\n");
            c.output_file.write("\n" + cond_label + ":\n");
            let current: String = next_reg(c);
            c.output_file.write(c.indent + current + " = load " + size_ty + ", " + size_ty + "* " + index + "\n");
            let more: String = next_reg(c);
            c.output_file.write(c.indent + more + " = icmp ult " + size_ty + " " + current + ", " + item.length + "\n");
            c.output_file.write(c.indent + "br i1 " + more + ", label %" + body_label + ", label %" + done_label + "\n");
            c.output_file.write("\n" + body_label + ":\n");
            let slot: String = next_reg(c);
            c.output_file.write(c.indent + slot + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + item.data + ", " + size_ty + " " + current + "\n");
            let value_reg: String = slot;
            let nested_array: ArrayInfo = c.array_info_map.lookup("" + item.elem_type);
            if (!has_array_info(nested_array) || nested_array.size < 0) {
                value_reg = next_reg(c);
                c.output_file.write(c.indent + value_reg + " = load " + elem_ty + ", " + elem_ty + "* " + slot + "\n");
            }
            emit_print_item(c, value_reg, item.elem_type, item.elem_type, printed, separator, node.pos);
            let next: String = next_reg(c);
            c.output_file.write(c.indent + next + " = add " + size_ty + " " + current + ", 1\n");
            c.output_file.write(c.indent + "store " + size_ty + " " + next + ", " + size_ty + "* " + index + "\n");
            c.output_file.write(c.indent + "br label %" + cond_label + "\n");
            c.output_file.write("\n" + done_label + ":\n");
        }
        emit_release_owned(c, item.value);
        i += 1;
    }
    emit_print_text(c, ending, "\n", node.pos);
    emit_release_owned(c, separator);
    emit_release_owned(c, ending);
    return void_result();
}

func compile_variadic_pack(c: Compiler, args: Vector(ArgNode), elem_type: Int, pos: Position) -> CompileResult {
    let sources: Vector(Struct) = [];
    let size_ty: String = get_size_llvm_type();
    let elem_ty: String = get_llvm_type_str(c, elem_type);
    let elem_size_ptr: String = next_reg(c);
    c.output_file.write(c.indent + elem_size_ptr + " = getelementptr " + elem_ty + ", " + elem_ty + "* null, " + size_ty + " 1\n");

    let elem_size: String = next_reg(c);
    c.output_file.write(c.indent + elem_size + " = ptrtoint " + elem_ty + "* " + elem_size_ptr + " to " + size_ty + "\n");

    let max_capacity: String = next_reg(c);
    c.output_file.write(c.indent + max_capacity + " = udiv " + size_ty + " -1, " + elem_size + "\n");

    let total: String = "0";
    let i: Int = 0;

    while (args is !null && i < args.length()) {
        let arg: ArgNode = args[i];
        let old_expected: Int = c.expected_type;
        c.expected_type = 0;
        if (!arg.is_spread) { c.expected_type = elem_type; }
        let value: CompileResult = compile_node(c, arg.val);
        c.expected_type = old_expected;
        if (!has_result(value) || value.type == TYPE_POISON) {
            return CompileResult(reg="poison", type=TYPE_POISON);
        }

        let length: String = "1";
        let data: String = "";
        if (arg.is_spread) {
            let source_elem: Int = 0;
            let array_info: ArrayInfo = c.array_info_map.lookup("" + value.type);
            let vector_info: SymbolInfo = c.vector_base_map.lookup("" + value.type);
            if (has_array_info(array_info)) {
                source_elem = array_info.base_type;
                if (array_info.size == -1) {
                    let parts: SliceParts = emit_slice_parts(c, value.reg, value.type, pos);
                    length = parts.length;
                    data = next_reg(c);
                    c.output_file.write(c.indent + data + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + parts.data + ", " + size_ty + " " + parts.start + "\n");
                } else {
                    length = "" + array_info.size;
                    data = next_reg(c);
                    c.output_file.write(c.indent + data + " = getelementptr inbounds " + array_info.llvm_name + ", " + array_info.llvm_name + "* " + value.reg + ", i32 0, i32 0\n");
                }
            } else if (has_symbol(vector_info)) {
                source_elem = vector_info.type;
                let vector_ty: String = get_vector_llvm_type(c, source_elem);
                let length_slot: String = next_reg(c);
                c.output_file.write(c.indent + length_slot + " = getelementptr inbounds " + vector_ty + ", " + vector_ty + "* " + value.reg + ", i32 0, i32 0\n");
                length = next_reg(c);
                c.output_file.write(c.indent + length + " = load " + size_ty + ", " + size_ty + "* " + length_slot + "\n");
                let data_slot: String = next_reg(c);
                c.output_file.write(c.indent + data_slot + " = getelementptr inbounds " + vector_ty + ", " + vector_ty + "* " + value.reg + ", i32 0, i32 2\n");
                data = next_reg(c);
                c.output_file.write(c.indent + data + " = load " + elem_ty + "*, " + elem_ty + "** " + data_slot + "\n");
            } else {
                throw_type_error(pos, "Only an Array or Vector can be expanded into a variadic argument.");
                emit_release_owned(c, value);
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            if (source_elem != elem_type) {
                throw_type_error(pos, "Cannot expand " + get_type_name(c, value.type) + " into a variadic parameter of " + get_type_name(c, elem_type) + ".");
                emit_release_owned(c, value);
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
        } else {
            value = emit_implicit_cast(c, value, elem_type, pos);
        }

        let remaining: String = next_reg(c);
        c.output_file.write(c.indent + remaining + " = sub " + size_ty + " " + max_capacity + ", " + total + "\n");
        let overflow: String = next_reg(c);
        c.output_file.write(c.indent + overflow + " = icmp ugt " + size_ty + " " + length + ", " + remaining + "\n");
        let fail_label: String = next_label(c);
        let next_label_: String = next_label(c);
        c.output_file.write(c.indent + "br i1 " + overflow + ", label %" + fail_label + ", label %" + next_label_ + "\n");
        c.output_file.write("\n" + fail_label + ":\n");
        c.output_file.write(c.indent + "call void @__wl_oom()\n");
        c.output_file.write(c.indent + "unreachable\n");
        c.output_file.write("\n" + next_label_ + ":\n");
        let next_total: String = next_reg(c);
        c.output_file.write(c.indent + next_total + " = add " + size_ty + " " + total + ", " + length + "\n");
        total = next_total;
        sources.append(VariadicSource(value=value, spread=arg.is_spread, length=length, data=data));
        i += 1;
    }

    let vector_type: Int = get_vector_type_id(c, elem_type);
    let vector_ty: String = get_vector_llvm_type(c, elem_type);
    let vector_size_ptr: String = next_reg(c);
    c.output_file.write(c.indent + vector_size_ptr + " = getelementptr " + vector_ty + ", " + vector_ty + "* null, i32 1\n");
    let vector_size: String = next_reg(c);
    c.output_file.write(c.indent + vector_size + " = ptrtoint " + vector_ty + "* " + vector_size_ptr + " to " + size_ty + "\n");
    let vector: String = emit_alloc_obj(c, vector_size, "" + vector_type, vector_ty + "*");

    let empty: String = next_reg(c);
    c.output_file.write(c.indent + empty + " = icmp eq " + size_ty + " " + total + ", 0\n");
    let alloc_count: String = next_reg(c);
    c.output_file.write(c.indent + alloc_count + " = select i1 " + empty + ", " + size_ty + " 1, " + size_ty + " " + total + "\n");
    let bytes: String = next_reg(c);
    c.output_file.write(c.indent + bytes + " = mul " + size_ty + " " + alloc_count + ", " + elem_size + "\n");
    let alloc_hook: String = get_mangled_symbol(c, "memory_alloc", pos);
    let raw_data: String = next_reg(c);
    c.output_file.write(c.indent + raw_data + " = call i8* @" + alloc_hook + "(" + size_ty + " " + bytes + ")\n");
    emit_alloc_check(c, raw_data);
    let storage: String = next_reg(c);
    c.output_file.write(c.indent + storage + " = bitcast i8* " + raw_data + " to " + elem_ty + "*\n");

    let size_slot: String = next_reg(c);
    c.output_file.write(c.indent + size_slot + " = getelementptr inbounds " + vector_ty + ", " + vector_ty + "* " + vector + ", i32 0, i32 0\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + total + ", " + size_ty + "* " + size_slot + "\n");
    let cap_slot: String = next_reg(c);
    c.output_file.write(c.indent + cap_slot + " = getelementptr inbounds " + vector_ty + ", " + vector_ty + "* " + vector + ", i32 0, i32 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + total + ", " + size_ty + "* " + cap_slot + "\n");
    let data_slot: String = next_reg(c);
    c.output_file.write(c.indent + data_slot + " = getelementptr inbounds " + vector_ty + ", " + vector_ty + "* " + vector + ", i32 0, i32 2\n");
    c.output_file.write(c.indent + "store " + elem_ty + "* " + storage + ", " + elem_ty + "** " + data_slot + "\n");

    let dest_index: String = next_reg(c);
    c.output_file.write(c.indent + dest_index + " = alloca " + size_ty + "\n");
    c.output_file.write(c.indent + "store " + size_ty + " 0, " + size_ty + "* " + dest_index + "\n");
    i = 0;
    while (i < sources.length()) {
        let source: VariadicSource = sources[i];
        if (!source.spread) {
            let index: String = next_reg(c);
            c.output_file.write(c.indent + index + " = load " + size_ty + ", " + size_ty + "* " + dest_index + "\n");
            let slot: String = next_reg(c);
            c.output_file.write(c.indent + slot + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + storage + ", " + size_ty + " " + index + "\n");
            if (result_owns_value(c, elem_type) && !source.value.owns_ref) {
                emit_retain_value(c, source.value.reg, elem_type);
            }
            c.output_file.write(c.indent + "store " + elem_ty + " " + source.value.reg + ", " + elem_ty + "* " + slot + "\n");
            let next: String = next_reg(c);
            c.output_file.write(c.indent + next + " = add " + size_ty + " " + index + ", 1\n");
            c.output_file.write(c.indent + "store " + size_ty + " " + next + ", " + size_ty + "* " + dest_index + "\n");
        } else {
            let source_index: String = next_reg(c);
            c.output_file.write(c.indent + source_index + " = alloca " + size_ty + "\n");
            c.output_file.write(c.indent + "store " + size_ty + " 0, " + size_ty + "* " + source_index + "\n");
            let cond_label: String = next_label(c);
            let body_label: String = next_label(c);
            let done_label: String = next_label(c);
            c.output_file.write(c.indent + "br label %" + cond_label + "\n");
            c.output_file.write("\n" + cond_label + ":\n");
            let source_i: String = next_reg(c);
            c.output_file.write(c.indent + source_i + " = load " + size_ty + ", " + size_ty + "* " + source_index + "\n");
            let more: String = next_reg(c);
            c.output_file.write(c.indent + more + " = icmp ult " + size_ty + " " + source_i + ", " + source.length + "\n");
            c.output_file.write(c.indent + "br i1 " + more + ", label %" + body_label + ", label %" + done_label + "\n");
            c.output_file.write("\n" + body_label + ":\n");
            let source_slot: String = next_reg(c);
            c.output_file.write(c.indent + source_slot + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + source.data + ", " + size_ty + " " + source_i + "\n");
            let item: String = next_reg(c);
            c.output_file.write(c.indent + item + " = load " + elem_ty + ", " + elem_ty + "* " + source_slot + "\n");
            let target_i: String = next_reg(c);
            c.output_file.write(c.indent + target_i + " = load " + size_ty + ", " + size_ty + "* " + dest_index + "\n");
            let target_slot: String = next_reg(c);
            c.output_file.write(c.indent + target_slot + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + storage + ", " + size_ty + " " + target_i + "\n");
            c.output_file.write(c.indent + "store " + elem_ty + " " + item + ", " + elem_ty + "* " + target_slot + "\n");
            if (result_owns_value(c, elem_type)) { emit_retain_value(c, item, elem_type); }
            let next_source: String = next_reg(c);
            c.output_file.write(c.indent + next_source + " = add " + size_ty + " " + source_i + ", 1\n");
            c.output_file.write(c.indent + "store " + size_ty + " " + next_source + ", " + size_ty + "* " + source_index + "\n");
            let next_target: String = next_reg(c);
            c.output_file.write(c.indent + next_target + " = add " + size_ty + " " + target_i + ", 1\n");
            c.output_file.write(c.indent + "store " + size_ty + " " + next_target + ", " + size_ty + "* " + dest_index + "\n");
            c.output_file.write(c.indent + "br label %" + cond_label + "\n");
            c.output_file.write("\n" + done_label + ":\n");
            emit_release_owned(c, source.value);
        }
        i += 1;
    }

    let owner: String = next_reg(c);
    c.output_file.write(c.indent + owner + " = bitcast " + vector_ty + "* " + vector + " to i8*\n");
    return emit_make_slice(c, elem_type, owner, data_slot, size_slot, "0", total);
}

func compile_func_def(c: Compiler, node: FunctionDefNode) -> CompileResult {
    if (node.type_params is !null && node.type_params.length() > 0 && 
        c.generic_func_key.length() == 0) {
        return void_result();
    }
    let raw_name: String = node.name_tok.value;

    let func_name: String = raw_name;
    if (c.generic_func_key.length() > 0) {
        func_name = c.generic_func_key;
    } else if (raw_name != "main") {
        func_name = c.current_package_prefix + raw_name;
    }

    if (raw_name == "main") {
        c.has_main = true;
    }

    let f_info: FuncInfo = c.func_table.lookup(func_name);
    if (!has_func(f_info)) {
        return void_result();
    }
    if (f_info.compiler_link_name == "dict_key_hash" || f_info.compiler_link_name == "dict_keys_equal") { return void_result(); }
    if ((f_info.ann_flags & FLAG_ANN_INTRINSIC) != 0) { return void_result(); }
    let ret_type_id: Int = f_info.ret_type;
    let llvm_ret_type: String = get_llvm_type_str(c, ret_type_id);

    c.current_ret_type = ret_type_id;

    let params_str: String = "";
    let params: Vector(ParamNode) = node.params;
    let p_len: Int = 0;
    if (params is !null) { p_len = params.length(); }
    let arg_idx: Int = 0;
    
    while (arg_idx < p_len) {
        let p: ParamNode = params[arg_idx];
        let p_type_id: Int = callable_param_type(c, p);
        let p_llvm_type: String = get_llvm_type_str(c, p_type_id);
        if (arg_idx > 0) { params_str = params_str + ", "; }
        params_str += p_llvm_type + " %arg" + arg_idx;
        arg_idx += 1;
    }

    let linkage: String = "internal ";
    if (raw_name == "main" || (f_info.ann_flags & FLAG_ANN_EXPORT) != 0) {
        linkage = "";
        if (c.is_shared && (f_info.ann_flags & FLAG_ANN_EXPORT) != 0 && get_target_os() == sys.Os.Windows) {
            linkage = "dllexport ";
        }
    }

    // keep compiler-link hooks out of line to avoid cloning their loops at call sites
    let func_attrs: String = "";
    if ((f_info.ann_flags & FLAG_ANN_COMP_LINK) != 0) {
        func_attrs = "noinline ";
    }

    c.output_file.write("define " + linkage + llvm_ret_type + " @" + f_info.name + "(" + params_str + ") " + func_attrs + "{\n");
    c.output_file.write("entry:\n");

    let old_sym: Scope = c.symbol_table;
    c.symbol_table = Scope(table=Dict(), parent=-1, gc_vars=[], depth=0);
    c.scope_stack = [];
    
    c.reg_count = 0; 
    c.scope_depth = 1;
    c.curr_func = f_info;
    arg_idx = 0;
    while (arg_idx < p_len) {
        let p: ParamNode = params[arg_idx];
        let p_name: String = p.name_tok.value;
        
        let target_type_id: Int = callable_param_type(c, p);
        let llvm_ty: String = get_llvm_type_str(c, target_type_id);
        let addr_reg: String = next_reg(c); 
        c.output_file.write(c.indent + addr_reg + " = alloca " + llvm_ty + "\n");
        c.output_file.write(c.indent + "store " + llvm_ty + " %arg" + arg_idx + ", " + llvm_ty + "* " + addr_reg + "\n");
        let curr_scope: Scope = c.symbol_table;
        curr_scope.table.put(p_name, SymbolInfo(reg=addr_reg, type=target_type_id, origin_type=target_type_id));
        if (needs_drop(c, target_type_id)) {
            emit_retain_slot(c, addr_reg, target_type_id);
            curr_scope.gc_vars.append(GCTracker(reg=addr_reg, type=target_type_id));
        }
        
        arg_idx += 1;
    }

    c.hoist_scope = Scope(parent=-1, table=Dict(), gc_vars=[], depth=0);
    c.alloc_regs = [];
    hoist_allocas(c, node.body);
    check_local_init(c, node.body);

    compile_node(c, node.body);

    let has_term: Bool = must_terminate(c, node.body);

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
    
    c.curr_func = FuncInfo();
    
    return void_result();
}

func compile_method_def(c: Compiler, class_name: String, node: MethodDefNode) -> CompileResult {
    let raw_name: String = method_base_name(c, node);
    let m_name: String = class_name + "_" + raw_name;
    if (c.generic_method_key.length() > 0) {
        m_name = c.generic_method_key;
    }
    
    let f_info: FuncInfo = c.func_table.lookup(m_name);
    if (!has_func(f_info)) {
        return void_result();
    }
    f_info.mutates_self = method_mutates_self(c, node.body);
    c.func_table.put(m_name, f_info);
    if (f_info.compiler_link_name == "hash_value" || f_info.compiler_link_name == "values_equal" || 
        f_info.compiler_link_name == "zero_value") {
        return void_result();
    }
    let ret_type_id: Int = f_info.ret_type;
    let llvm_ret_type: String = get_llvm_type_str(c, ret_type_id);

    c.current_ret_type = ret_type_id;

    let c_info: StructInfo = c.struct_table.lookup(class_name);
    let class_type_id: Int = c_info.type_id;
    let class_ptr_llvm: String = get_llvm_type_str(c, class_type_id); 

    let params_str: String = class_ptr_llvm + " %arg0";
    
    let params: Vector(ParamNode) = node.params;
    let p_len: Int = 0; if (params is !null) { p_len = params.length(); }
    let arg_idx: Int = 0;
    
    while (arg_idx < p_len) {
        let p: ParamNode = params[arg_idx];
        let p_type_id: Int = callable_param_type(c, p);
        let p_llvm_type: String = get_llvm_type_str(c, p_type_id);
        let arg_num: Int = arg_idx + 1;
        params_str = params_str + ", " + p_llvm_type + " %arg" + arg_num;
        arg_idx += 1;
    }

    c.output_file.write("define internal " + llvm_ret_type + " @" + f_info.name + "(" + params_str + ") {\n");
    c.output_file.write("entry:\n");

    let old_sym: Scope = c.symbol_table;
    c.symbol_table = Scope(table=Dict(), parent=-1, gc_vars=[], depth=0);
    c.scope_stack = [];
    
    c.reg_count = 0; 
    c.scope_depth = 1;
    c.curr_func = f_info;
    
    let self_addr: String = next_reg(c);
    c.output_file.write(c.indent + self_addr + " = alloca " + class_ptr_llvm + "\n");
    c.output_file.write(c.indent + "store " + class_ptr_llvm + " %arg0, " + class_ptr_llvm + "* " + self_addr + "\n");
    let curr_scope: Scope = c.symbol_table;
    curr_scope.table.put("self", SymbolInfo(reg=self_addr, type=class_type_id, origin_type=class_type_id, is_const=false));

    arg_idx = 0;
    while (arg_idx < p_len) {
        let p: ParamNode = params[arg_idx];
        let p_name: String = p.name_tok.value;
        let target_type_id: Int = callable_param_type(c, p);
        let llvm_ty: String = get_llvm_type_str(c, target_type_id);
        let addr_reg: String = next_reg(c); 
        c.output_file.write(c.indent + addr_reg + " = alloca " + llvm_ty + "\n");
        let arg_num: Int = arg_idx + 1;
        c.output_file.write(c.indent + "store " + llvm_ty + " %arg" + arg_num + ", " + llvm_ty + "* " + addr_reg + "\n");
        curr_scope.table.put(p_name, SymbolInfo(reg=addr_reg, type=target_type_id, origin_type=target_type_id, is_const=false));
        if (needs_drop(c, target_type_id)) {
            emit_retain_slot(c, addr_reg, target_type_id);
            curr_scope.gc_vars.append(GCTracker(reg=addr_reg, type=target_type_id));
        }
        arg_idx += 1;
    }

    c.hoist_scope = Scope(parent=-1, table=Dict(), gc_vars=[], depth=0);
    c.alloc_regs = [];
    hoist_allocas(c, node.body);
    check_local_init(c, node.body);
    compile_node(c, node.body);

    let has_term: Bool = must_terminate(c, node.body);

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
    c.curr_func = FuncInfo();
    
    return void_result();
}

func emit_method_nullcheck(c: Compiler, obj_ptr: String, class_llvm_ty: String, method_name: String, pos: Position) -> Void {
    let is_null: String = next_reg(c);
    c.output_file.write(c.indent + is_null + " = icmp eq " + class_llvm_ty + "* " + obj_ptr + ", null\n");
    let panic_lbl: String = next_label(c);
    let cont_lbl: String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + is_null + ", label %" + panic_lbl + ", label %" + cont_lbl + "\n");
    
    c.output_file.write("\n" + panic_lbl + ":\n");
    let msg: String = "Cannot call method '" + method_name + "' on null object.";
    emit_runtime_error(c, pos, msg);
    
    c.output_file.write("\n" + cont_lbl + ":\n");
}

func can_access_private_method(c: Compiler, owner: StructInfo) -> Bool {
    let class_prefix: String = "";
    let dot_idx: Int = owner.name.length() - 1;
    while (dot_idx >= 0) {
        if (owner.name[dot_idx] == '.') {
            class_prefix = owner.name.slice(0, dot_idx + 1);
            break;
        }
        dot_idx -= 1;
    }
    if (c.current_package_prefix == class_prefix) {
        return true;
    }
    if (!has_func(c.curr_func) || c.curr_func.arg_types is null || c.curr_func.arg_types.length() == 0) {
        return false;
    }
    let receiver: TypeListNode = c.curr_func.arg_types[0];
    return receiver.type == owner.type_id;
}

func compile_class_method_call(c: Compiler, s_info: StructInfo, obj_res: CompileResult, method_name: String, n_call: CallNode) -> CompileResult {
    if (method_name.starts_with("__") && !can_access_private_method(c, s_info)) {
        throw_name_error(n_call.pos, "Method '" + method_name + "' is private to class '" + s_info.name + "'.");
        return void_result();
    }

    let vtable_vec: Vector(Struct) = s_info.vtable;
    let v_len: Int = 0; if (vtable_vec is !null) { v_len = vtable_vec.length(); }
    
    let m_idx: Int = 0;
    let found: Bool = false;
    let f_info: FuncInfo = FuncInfo();
    let generic_method: Bool = false;
    let method_template: GenericTemplate = c.generic_methods.lookup(s_info.name + "_" + method_name);

    if (has_template(method_template)) {
        if (s_info.is_interface) {
            throw_type_error(n_call.pos, "Generic methods cannot be called through an interface value.");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        let types: Vector(Struct) = resolve_generic_method_args(c, method_template, n_call.type_args, n_call.args, n_call.pos);
        if (types is null) { return CompileResult(reg="poison", type=TYPE_POISON); }
        f_info = register_generic_method(c, method_template, s_info, types, n_call.pos);
        if (!has_func(f_info)) { return CompileResult(reg="poison", type=TYPE_POISON); }
        found = true;
        generic_method = true;
    }
    
    while (!found && m_idx < v_len) {
        if (s_info.is_interface) {
            let m: MethodDefNode = vtable_vec[m_idx];
            if (m.name_tok.value == method_name) {
                found = true;
                break;
            }
        } else {
            let m: FuncInfo = vtable_vec[m_idx];
            if (m.base_name == method_name) {
                f_info = m;
                found = true;
                break;
            }
        }
        m_idx += 1;
    }

    if (!found && !s_info.is_interface) {
        let direct: FuncInfo = c.func_table.lookup(s_info.name + "_" + method_name);
        if (has_func(direct) && direct.compiler_link_name is !null && 
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
    if (has_func(f_info) && (f_info.compiler_link_name == "hash_value" || f_info.compiler_link_name == "values_equal")) {
        let args: Vector(ArgNode) = n_call.args;
        let expected_count: Int = 1;
        if (f_info.compiler_link_name == "values_equal") {
            expected_count = 2;
        }

        let actual_count: Int = 0;
        if (args is !null) {
            actual_count = args.length();
        }
        if (actual_count != expected_count) { throw_type_error(n_call.pos, "Argument count mismatch. Expected " + expected_count + ", got " + actual_count); return CompileResult(reg="poison", type=TYPE_POISON); }

        let key_type_node: TypeListNode = f_info.arg_types[1];
        let key_type: Int = key_type_node.type;
        c.hash_types.put("" + key_type, StringConstant(id=key_type, value=""));
        let llvm_type: String = get_llvm_type_str(c, key_type);
        let values: Vector(Struct) = [];

        let index: Int = 0;
        while (index < actual_count) {
            let arg: ArgNode = args[index];
            let value: CompileResult = emit_implicit_cast(c, compile_node(c, arg.val), key_type, n_call.pos);
            values.append(value);
            index++;
        }

        let result: String = next_reg(c);
        if (f_info.compiler_link_name == "hash_value") {
            let value: CompileResult = values[0];
            c.output_file.write(c.indent + result + " = call i32 @__wl_hash_value_" + key_type + "(" + llvm_type + " " + value.reg + ")\n");
            emit_release_owned(c, value);
        } else {
            let left: CompileResult = values[0];
            let right: CompileResult = values[1];
            c.output_file.write(c.indent + result + " = call i1 @__wl_values_equal_" + key_type + "(" + llvm_type + " " + left.reg + ", " + llvm_type + " " + right.reg + ")\n");
            emit_release_owned(c, left); emit_release_owned(c, right);
        }

        emit_release_owned(c, obj_res);
        return CompileResult(reg=result, type=f_info.ret_type);
    }

    if (has_func(f_info) && f_info.compiler_link_name == "zero_value") {
        let result: CompileResult = zero_value(c, f_info, n_call);
        emit_release_owned(c, obj_res);
        return result;
    }
    if (has_func(f_info)) { queue_generic_class_method(c, s_info, f_info.base_name); }
    if (obj_res.is_const_access && (s_info.is_interface || (has_func(f_info) && f_info.mutates_self))) {
        throw_type_error(n_call.pos, "Cannot call mutating method '" + method_name + "' through const value");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    
    let func_ptr: String = "";
    let sig: String = "";
    let args_str: String = "";
    let expected_types: Vector(Struct) = null;
    let interface_params: Vector(ParamNode) = null;
    let ret_type: Int = 0;
    
    if (s_info.is_interface) {
        let m_node: MethodDefNode = vtable_vec[m_idx];
        sig = interface_method_sig(c, s_info, m_node);
        ret_type = interface_method_type(c, s_info, m_node.return_type);
        interface_params = m_node.params;
        
        let obj_box: String = obj_res.reg;
        let obj_ptr: String = next_reg(c);
        c.output_file.write(c.indent + obj_ptr + " = extractvalue { i8*, i8* } " + obj_box + ", 0\n");
        let itable_ptr: String = next_reg(c);
        c.output_file.write(c.indent + itable_ptr + " = extractvalue { i8*, i8* } " + obj_box + ", 1\n");
        
        emit_method_nullcheck(c, obj_ptr, "i8", method_name, n_call.pos);
        
        let itable_typed_ptr: String = next_reg(c);
        let itable_type: String = "[ " + v_len + " x i8* ]";
        c.output_file.write(c.indent + itable_typed_ptr + " = bitcast i8* " + itable_ptr + " to " + itable_type + "*\n");
        
        let method_i8ptr_addr: String = next_reg(c);
        c.output_file.write(c.indent + method_i8ptr_addr + " = getelementptr inbounds " + itable_type + ", " + itable_type + "* " + itable_typed_ptr + ", i32 0, i32 " + m_idx + "\n");
        
        let method_i8ptr: String = next_reg(c);
        c.output_file.write(c.indent + method_i8ptr + " = load i8*, i8** " + method_i8ptr_addr + "\n");
        
        func_ptr = next_reg(c);
        c.output_file.write(c.indent + func_ptr + " = bitcast i8* " + method_i8ptr + " to " + sig + "\n");
        
        args_str = "i8* " + obj_ptr;
    } else {
        sig = get_func_sig_str(c, f_info);
        ret_type = f_info.ret_type;
        expected_types = f_info.arg_types;
        
        let class_llvm_ty: String = s_info.llvm_name;
        let obj_ptr: String = obj_res.reg;
        
        emit_method_nullcheck(c, obj_ptr, class_llvm_ty, method_name, n_call.pos);
        if (is_generic_class(c, s_info) || generic_method) {
            func_ptr = "@" + f_info.name;
        } else {
            let vptr_addr: String = next_reg(c);
            c.output_file.write(c.indent + vptr_addr + " = getelementptr inbounds " + class_llvm_ty + ", " + class_llvm_ty + "* " + obj_ptr + ", i32 0, i32 0\n");
        
            let vtable_i8ptr: String = next_reg(c);
            c.output_file.write(c.indent + vtable_i8ptr + " = load i8*, i8** " + vptr_addr + "\n");

            let vtable_ptr: String = next_reg(c);
            c.output_file.write(c.indent + vtable_ptr + " = bitcast i8* " + vtable_i8ptr + " to " + class_vtable_type(c, s_info) + "*\n");

            let method_i8ptr_addr: String = next_reg(c);
            c.output_file.write(c.indent + method_i8ptr_addr + " = getelementptr inbounds " + class_vtable_type(c, s_info) + ", " + class_vtable_type(c, s_info) + "* " + vtable_ptr + ", i32 0, i32 " + m_idx + "\n");

            let method_i8ptr: String = next_reg(c);
            c.output_file.write(c.indent + method_i8ptr + " = load i8*, i8** " + method_i8ptr_addr + "\n");

            func_ptr = next_reg(c);
            c.output_file.write(c.indent + func_ptr + " = bitcast i8* " + method_i8ptr + " to " + sig + "\n");
        }
        
        let self_type_node: TypeListNode = expected_types[0];
        let self_expected_type: Int = self_type_node.type;
        
        c.expected_type = self_expected_type;
        let casted_obj: CompileResult = emit_implicit_cast(c, obj_res, self_expected_type, n_call.pos);
        c.expected_type = 0;
        
        args_str = get_llvm_type_str(c, self_expected_type) + " " + casted_obj.reg;
    }

    if (!validate_fallible_call(c, ret_type, n_call.preserve_fallible, method_name, n_call.pos)) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    
    let args: Vector(ArgNode) = n_call.args;
    let a_len: Int = 0; if (args is !null) { a_len = args.length(); }
    let owned_args: Vector(Struct) = [];
    
    let exp_len: Int = 0;
    if (s_info.is_interface) {
        if (interface_params is !null) { exp_len = interface_params.length(); }
    } else if (expected_types is !null) {
        exp_len = expected_types.length();
    }
    if (!s_info.is_interface && exp_len > 0) { exp_len -= 1; }
    
    let native_args: BoundCallArgs = BoundCallArgs();
    if (!s_info.is_interface && has_func(f_info)) {
        native_args = bind_native_args(args, f_info, 1, n_call.pos);
        if (!has_bound_args(native_args)) { return CompileResult(reg="poison", type=TYPE_POISON); }
        args = native_args.ordered;
        a_len = exp_len;
    } else if (a_len != exp_len) {
        throw_type_error(n_call.pos, "Argument count mismatch in method call. Expected " + exp_len + ", got " + a_len);
        return CompileResult(reg="0", type=ret_type, origin_type=0);
    }
    if (s_info.is_interface) {
        let interface_names: Vector(String) = [];
        let name_index: Int = 0;
        while (interface_params is !null && name_index < interface_params.length()) { let param: ParamNode = interface_params[name_index]; interface_names.append(param.name_tok.value); name_index += 1; }
        args = bind_call_args(args, interface_names, 0, n_call.pos);
        if (args is null && exp_len > 0) { return CompileResult(reg="poison", type=TYPE_POISON); }
    }

    let arg_idx: Int = 0;
    while (arg_idx < a_len) {
        if (!s_info.is_interface && f_info.variadic_param > 0 && arg_idx == f_info.variadic_param - 1) {
            let pack_type: TypeListNode = expected_types[arg_idx + 1];
            let pack_info: ArrayInfo = c.array_info_map.lookup("" + pack_type.type);
            let pack: CompileResult = compile_variadic_pack(c, native_args.variadic, pack_info.base_type, n_call.pos);
            if (pack.type == TYPE_POISON) { return pack; }
            args_str += ", " + get_llvm_type_str(c, pack.type) + " " + pack.reg;
            arg_idx += 1;
            continue;
        }
        let arg_node_curr: ArgNode = args[arg_idx];
        let expected_type: Int = 0;
        
        if (s_info.is_interface) {
            let p_node: ParamNode = interface_params[arg_idx];
            expected_type = interface_method_type(c, s_info, p_node.type_tok);
        } else {
            let expected_type_node: TypeListNode = expected_types[arg_idx + 1];
            expected_type = expected_type_node.type;
        }
        
        c.expected_type = expected_type;
        let arg_val: CompileResult = compile_node(c, arg_node_curr.val);
        c.expected_type = 0;
        if (has_result(arg_val) && arg_val.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
        let dynamic_key_arg: Bool = arg_idx == 0 && is_dynamic_dict(s_info) && is_dynamic_dict_key_method(method_name);
        if (dynamic_key_arg && has_result(arg_val) && arg_val.type != expected_type && !is_dict_key_type(c, arg_val.type)) {
            throw_type_error(n_call.pos, "Type " + get_type_name(c, arg_val.type) + " cannot be used as a Dict key");
            emit_release_owned(c, arg_val);
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        arg_val = emit_implicit_cast(c, arg_val, expected_type, n_call.pos);
        
        let ty_str: String = get_llvm_type_str(c, arg_val.type);
        args_str = args_str + ", " + ty_str + " " + arg_val.reg;
        if (arg_val.owns_ref) { owned_args.append(arg_val); }
        
        arg_idx += 1;
    }
    
    let llvm_ret_type: String = get_llvm_type_str(c, ret_type);
    if (ret_type == TYPE_VOID) {
        c.output_file.write(c.indent + "call " + llvm_ret_type + " " + func_ptr + "(" + args_str + ")\n");
        emit_release_owned_args(c, owned_args);
        emit_release_owned(c, obj_res);
        return CompileResult(reg="", type=TYPE_VOID, origin_type=0);
    } else {
        let call_res: String = next_reg(c);
        c.output_file.write(c.indent + call_res + " = call " + llvm_ret_type + " " + func_ptr + "(" + args_str + ")\n");
        emit_release_owned_args(c, owned_args);
        emit_release_owned(c, obj_res);
        return CompileResult(reg=call_res, type=ret_type, origin_type=0, owns_ref=result_owns_value(c, ret_type), is_const_access=obj_res.is_const_access);
    }
}

func compile_dict_intrinsic(c: Compiler, info: FuncInfo, node: CallNode) -> CompileResult {
    let args: Vector(ArgNode) = node.args;
    let count: Int = 0;
    if (args is !null) { count = args.length(); }
    let expected: Int = 1;
    if (info.compiler_link_name == "dict_keys_equal") { expected = 2; }
    if (count != expected) {
        throw_type_error(node.pos, "Argument count mismatch. Expected " + expected + ", got " + count);
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    if (reject_named_args(args, node.pos, "a compiler intrinsic")) { return CompileResult(reg="poison", type=TYPE_POISON); }

    let variant_info: StructInfo = c.struct_table.lookup("$Variant");
    if (!has_struct(variant_info)) {
        throw_internal_compiler_error(node.pos, "Variant is not registered.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let values: Vector(Struct) = [];
    let i: Int = 0;
    while (i < count) {
        let arg: ArgNode = args[i];
        let old_expected: Int = c.expected_type;
        c.expected_type = variant_info.type_id;
        let value: CompileResult = compile_node(c, arg.val);
        c.expected_type = old_expected;
        if (!has_result(value) || value.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
        value = emit_implicit_cast(c, value, variant_info.type_id, node.pos);
        values.append(value);
        i++;
    }

    let result: String = next_reg(c);
    if (info.compiler_link_name == "dict_key_hash") {
        let value: CompileResult = values[0];
        c.output_file.write(c.indent + result + " = call i32 @__wl_dict_key_hash(%struct.$Variant* " + value.reg + ")\n");
        emit_release_owned(c, value);
        return CompileResult(reg=result, type=TYPE_INT);
    }

    let left: CompileResult = values[0];
    let right: CompileResult = values[1];
    c.output_file.write(c.indent + result + " = call i1 @__wl_dict_keys_equal(%struct.$Variant* " + left.reg + ", %struct.$Variant* " + right.reg + ")\n");
    emit_release_owned(c, left);
    emit_release_owned(c, right);
    return CompileResult(reg=result, type=TYPE_BOOL);
}

func compile_local_closure(c: Compiler, func_def: FunctionDefNode) -> CompileResult {
    let scope: CaptureScope = CaptureScope(local_vars=Dict(), captured_vars=Dict(), captured_list=[]);
    let params: Vector(ParamNode) = func_def.params;
    let p_len: Int = 0; if (params is !null) { p_len = params.length(); }
    let local_variadic: Int = variadic_param_index(params);
    let p_i: Int = 0;
    while (p_i < p_len) {
        let p_node: ParamNode = params[p_i];
        if (has_node(p_node.default_val)) {
            throw_type_error(p_node.pos, "A local function value cannot declare default parameters.");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        scope.local_vars.put(p_node.name_tok.value, true);
        p_i += 1;
    }
    if (func_def.name_tok.value.length() > 0) { scope.local_vars.put(func_def.name_tok.value, true); }

    analyze_captures(c.arena, func_def.body, scope);
    
    let captures: Vector(String) = [];
    let capture_types: Vector(Struct) = [];
    
    let c_i: Int = 0;
    let cap_len: Int = scope.captured_list.length();
    while (c_i < cap_len) {
        let v_name: String = scope.captured_list[c_i];
        let is_global: Bool = false;
        if (has_symbol(c.global_symbol_table.lookup(v_name))) { is_global = true; }
        if (has_func(c.func_table.lookup(v_name))) { is_global = true; }
        if (has_struct(c.struct_table.lookup(v_name))) { is_global = true; }
        if (c.current_file_global_aliases.lookup(v_name) is !null) { is_global = true; }
        if (c.current_file_func_aliases.lookup(v_name) is !null) { is_global = true; }
        if (c.current_file_type_aliases.lookup(v_name) is !null) { is_global = true; }
        if (c.current_package_prefix != "") {
            if (has_symbol(c.global_symbol_table.lookup(c.current_package_prefix + v_name))) { is_global = true; }
            if (has_func(c.func_table.lookup(c.current_package_prefix + v_name))) { is_global = true; }
            if (has_struct(c.struct_table.lookup(c.current_package_prefix + v_name))) { is_global = true; }
        }
        if (is_visible_namespace(c, v_name)) { is_global = true; }

        if (!is_global) {
            let info: SymbolInfo = find_symbol(c, v_name);
            if (!has_symbol(info)) {
                throw_name_error(func_def.pos, "Cannot capture undefined variable '" + v_name + "'.");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            captures.append(v_name); 
            capture_types.append(TypeListNode(type=info.type));
        }
        c_i += 1;
    }

    let env_id: Int = c.type_counter;
    c.type_counter += 1;

    let t_len: Int = captures.length();
    let env_struct_name: String = "env." + env_id;
    let env_body: String = "";
    let env_fields: Vector(Struct) = [];
    let t_i: Int = 0;
    while (t_i < t_len) {
        let t_node: TypeListNode = capture_types[t_i];
        let f_llvm: String = get_llvm_type_str(c, t_node.type);
        if (t_i > 0) { env_body += ", "; }
        env_body += f_llvm;
        env_fields.append(FieldInfo(name=captures[t_i], type=t_node.type, llvm_type=f_llvm, offset=t_i));
        t_i += 1;
    }
    let llvm_env_name: String = "{ " + env_body + " }";

    let env_info: StructInfo = StructInfo(name=env_struct_name, type_id=env_id, fields=env_fields, llvm_name=llvm_env_name, init_body=NO_NODE, is_class=false, vtable_name="", parent_id=0, vtable=null, is_enum=false, is_error=false, is_interface=false, interfaces=null, ann_flags=0, compiler_link_name="");
    c.struct_id_map.put("" + env_id, env_info);
    c.type_drop_list.append(TypeListNode(type=env_id));

    let size_ptr: String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr " + llvm_env_name + ", " + llvm_env_name + "* null, i32 1\n");
    let env_size: String = next_reg(c);
    c.output_file.write(c.indent + env_size + " = ptrtoint " + llvm_env_name + "* " + size_ptr + " to " + get_size_llvm_type() + "\n");
    let env_payload: String = emit_alloc_obj(c, env_size, "" + env_id, llvm_env_name + "*");

    let env_payload_i8: String = next_reg(c);
    c.output_file.write(c.indent + env_payload_i8 + " = bitcast " + llvm_env_name + "* " + env_payload + " to i8*\n");

    t_i = 0;
    while (t_i < t_len) {
        let v_name: String = captures[t_i];
        let t_node: TypeListNode = capture_types[t_i];
        let v_type: Int = t_node.type;
        let llvm_ty: String = get_llvm_type_str(c, v_type);
        let info: SymbolInfo = find_symbol(c, v_name);
        
        let val_reg: String = next_reg(c);
        c.output_file.write(c.indent + val_reg + " = load " + llvm_ty + ", " + llvm_ty + "* " + info.reg + "\n");
        
        let slot_ptr: String = next_reg(c);
        c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + llvm_env_name + ", " + llvm_env_name + "* " + env_payload + ", i32 0, i32 " + t_i + "\n");
        c.output_file.write(c.indent + "store " + llvm_ty + " " + val_reg + ", " + llvm_ty + "* " + slot_ptr + "\n");
        if (needs_drop(c, v_type)) { emit_retain_slot(c, slot_ptr, v_type); }
        t_i += 1;
    }

    let old_file: file.File = c.output_file;

    let temp_dir: String = "";
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

    let tmp_name: String = temp_dir + "wl_lambda_tmp_" + process.id() + "_" + env_id + ".ll";
    
    c.output_file = file.create(tmp_name)?;
    catch(err) {
        throw_internal_compiler_error(func_def.pos, "Cannot create closure IR file '" + tmp_name + "' (error " + Int(err) + ").");
        return void_result();
    }
    
    let lambda_name: String = "lambda." + func_def.name_tok.value + "." + env_id;
    let ret_type_id: Int = resolve_type(c, func_def.ret_type_tok);
    if (ret_type_id == TYPE_AUTO) { throw_type_error(func_def.pos, "Auto return type deduction is not supported in closures."); return void_result(); }
    let ret_ty_str: String = get_llvm_type_str(c, ret_type_id);
    let arg_types: Vector(Struct) = [];
    p_i = 0;
    while (p_i < p_len) {
        let p_node: ParamNode = params[p_i];
        arg_types.append(TypeListNode(type=callable_param_type(c, p_node)));
        p_i += 1;
    }
    let specific_type_id: Int = get_func_type_id(c, arg_types, ret_type_id, local_variadic, callable_param_names(params));
    let sig_def: String = "i8* %raw_env";
    let sig_ty: String = "i8*";
    p_i = 0;
    while (p_i < p_len) {
        let p_node: ParamNode = params[p_i];
        let p_ty: String = get_llvm_type_str(c, callable_param_type(c, p_node));
        sig_def = sig_def + ", " + p_ty + " %arg" + p_i;
        sig_ty = sig_ty + ", " + p_ty;
        p_i += 1;
    }
    
    c.output_file.write("define internal " + ret_ty_str + " @" + lambda_name + "(" + sig_def + ") {\nentry:\n");
    let old_sym: Scope = c.symbol_table;
    let old_depth: Int = c.scope_depth;
    let old_reg: Int = c.reg_count;
    let old_ret: Int = c.current_ret_type;
    let old_alloc_regs: Vector(String) = c.alloc_regs;
    let old_hoist_scope: Scope = c.hoist_scope;
    
    c.symbol_table = Scope(table=Dict(), parent=-1, gc_vars=[], depth=0);
    c.scope_stack = [];
    c.scope_depth = 1;
    c.reg_count = 1;
    c.current_ret_type = ret_type_id;

    if (func_def.name_tok.value.length() > 0) {
        let self_storage: String = next_reg(c);
        let self_function_slot: String = next_reg(c);
        let self_environment_slot: String = next_reg(c);
        let self_function: String = next_reg(c);
        let self_closure: String = next_reg(c);
        let self_address: String = next_reg(c);
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

    let lambda_env_ptr: String = "%lambda_env_ptr";
    c.output_file.write("  " + lambda_env_ptr + " = bitcast i8* %raw_env to " + llvm_env_name + "*\n");

    t_i = 0;
    while (t_i < t_len) {
        let v_name: String = captures[t_i];
        let t_node: TypeListNode = capture_types[t_i];
        let v_type: Int = t_node.type;
        let llvm_ty: String = get_llvm_type_str(c, v_type);

        let slot_ptr: String = "%env.slot." + t_i;
        c.output_file.write("  " + slot_ptr + " = getelementptr inbounds " + llvm_env_name + ", " + llvm_env_name + "* " + lambda_env_ptr + ", i32 0, i32 " + t_i + "\n");

        c.symbol_table.table.put(v_name, SymbolInfo(reg=slot_ptr, type=v_type, origin_type=v_type, is_const=false));
        t_i += 1;
    }
    
    p_i = 0;
    while (p_i < p_len) {
        let p_node: ParamNode = params[p_i];
        let p_ty_id: Int = callable_param_type(c, p_node);
        let p_ty: String = get_llvm_type_str(c, p_ty_id);
        let addr_reg: String = next_reg(c);
        c.output_file.write("  " + addr_reg + " = alloca " + p_ty + "\n");
        c.output_file.write("  store " + p_ty + " %arg" + p_i + ", " + p_ty + "* " + addr_reg + "\n");
        c.symbol_table.table.put(p_node.name_tok.value, SymbolInfo(reg=addr_reg, type=p_ty_id, origin_type=p_ty_id, is_const=false));
        if (needs_drop(c, p_ty_id)) {
            emit_retain_slot(c, addr_reg, p_ty_id);
            c.symbol_table.gc_vars.append(GCTracker(reg=addr_reg, type=p_ty_id));
        }
        p_i += 1;
    }
    
    c.hoist_scope = Scope(parent=-1, table=Dict(), gc_vars=[], depth=0);
    c.alloc_regs = [];
    hoist_allocas(c, func_def.body);
    check_local_init(c, func_def.body);
    let lambda_terminates: Bool = must_terminate(c, func_def.body);
    compile_node(c, func_def.body);
    
    if (!lambda_terminates) {
        cleanup_all_scopes(c);
        if (ret_type_id == TYPE_VOID) {
            c.output_file.write("  ret void\n");
        } else {
            let zero_val: String = "0";
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
    let tmp_read: file.File = file.open(tmp_name)?;
    catch(err) {
        throw_internal_compiler_error(func_def.pos, "Cannot reopen closure IR file '" + tmp_name + "' (error " + Int(err) + ").");
        return void_result();
    }
    let lambda_ir: String = tmp_read.read_all()?;
    catch(err) {
        throw_internal_compiler_error(func_def.pos, "Cannot read closure IR file '" + tmp_name + "' (error " + Int(err) + ").");
        return void_result();
    }
    tmp_read.close();
    file.remove(tmp_name)?;
    catch(err) { }

    c.global_buffer = c.global_buffer + lambda_ir;

    let clo_payload: String = emit_alloc_closure(c, specific_type_id);

    let clo_func_ptr: String = next_reg(c);
    c.output_file.write(c.indent + clo_func_ptr + " = bitcast i8* " + clo_payload + " to i8**\n");
    
    let lambda_casted: String = next_reg(c);
    c.output_file.write(c.indent + lambda_casted + " = bitcast " + ret_ty_str + " (" + sig_ty + ")* @" + lambda_name + " to i8*\n");
    c.output_file.write(c.indent + "store i8* " + lambda_casted + ", i8** " + clo_func_ptr + "\n");

    let clo_env_ptr_i8: String = next_reg(c);
    c.output_file.write(c.indent + clo_env_ptr_i8 + " = getelementptr inbounds i8, i8* " + clo_payload + ", i32 " + closure_env_offset() + "\n");
    let clo_env_ptr: String = next_reg(c);
    c.output_file.write(c.indent + clo_env_ptr + " = bitcast i8* " + clo_env_ptr_i8 + " to i8**\n");
    c.output_file.write(c.indent + "store i8* " + env_payload_i8 + ", i8** " + clo_env_ptr + "\n");
    c.output_file.write(c.indent + "call void @__wl_retain(i8* " + env_payload_i8 + ")\n");

    emit_retain(c, clo_payload, specific_type_id);
    return CompileResult(reg=clo_payload, type=specific_type_id, origin_type=ret_type_id);
}

func compile_return(c: Compiler, node: ReturnNode) -> CompileResult {
    if (has_node(node.value)) {
        // return void check
        if (c.current_ret_type == TYPE_VOID) {
            throw_type_error(node.pos, "Void function cannot return a value. ");
            return void_result();
        }

        c.expected_type = c.current_ret_type;
        let res: CompileResult = compile_node(c, node.value);
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

        let is_ret_fallible: Bool = is_fallible_type(c, c.current_ret_type);
        let inner_ret_type: Int = c.current_ret_type;
        if is_ret_fallible {
            inner_ret_type = get_inner_fallible_type(c, c.current_ret_type);
        }

        if is_ret_fallible {
            res = emit_implicit_cast(c, res, inner_ret_type, node.pos);
        } else {
            res = emit_implicit_cast(c, res, c.current_ret_type, node.pos);
        }

        let ret_val_reg: String = res.reg;
        let target_ty: String = get_llvm_type_str(c, c.current_ret_type);

        if is_ret_fallible {
            let ret_val_1: String = next_reg(c);
            c.output_file.write(c.indent + ret_val_1 + " = insertvalue " + target_ty + " undef, i1 false, 0\n");
            let ret_val_2: String = next_reg(c);
            c.output_file.write(c.indent + ret_val_2 + " = insertvalue " + target_ty + " " + ret_val_1 + ", { i64, i32 } zeroinitializer, 1\n");
            
            if (inner_ret_type != TYPE_VOID) {
                let ret_val_3: String = next_reg(c);
                let inner_llvm_ty: String = get_llvm_type_str(c, inner_ret_type);
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
                let inner: Int = get_inner_fallible_type(c, c.current_ret_type);
                if (inner == TYPE_VOID) {
                    let target_ty: String = get_llvm_type_str(c, c.current_ret_type);
                    let ret_val_1: String = next_reg(c);
                    c.output_file.write(c.indent + ret_val_1 + " = insertvalue " + target_ty + " undef, i1 false, 0\n");
                    let ret_val_2: String = next_reg(c);
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

func compile_struct_def(c: Compiler, node: StructDefNode) -> CompileResult {
    if (node.type_params is !null && node.type_params.length() > 0) { return void_result(); }

    let raw_name: String = node.name_tok.value;
    let struct_name: String = c.current_package_prefix + raw_name;

    let info: StructInfo = c.struct_table.lookup(struct_name);
    if (!has_struct(info)) {
        throw_type_error(node.pos, "Struct info missing for '" + struct_name + "'.");
        return void_result();
    }

    if ((info.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
        return void_result();
    }

    let full_name: String = "struct." + struct_name;
    if (has_struct(c.struct_table.lookup(full_name))) {
        throw_import_error(node.pos, "Struct '" + struct_name + "' is already defined in another module.");
        return void_result();
    }

    let llvm_body: String = "";
    let fields_vec: Vector(Struct) = [];
    
    let fields: Vector(ParamNode) = node.fields;
    let f_len: Int = 0; if (fields is !null) { f_len = fields.length(); }
    let idx: Int = 0;
    let field_names: Dict(String, StringConstant) = Dict();
    
    while (idx < f_len) {
        let p: ParamNode = fields[idx];
        let f_name: String = p.name_tok.value;
        if (field_names.contains_key(f_name)) { throw_name_error(p.pos, "field '" + f_name + "' is already defined in struct '" + struct_name + "'"); return void_result(); }
        field_names.put(f_name, StringConstant(id=0, value=f_name));
        let f_type_id: Int = resolve_type(c, p.type_tok);
        if (f_type_id == TYPE_AUTO) {
            throw_type_error(node.pos, "struct fields cannot use 'Auto' because they lack initializers for static deduction.");
            return void_result();
        }
        if (f_type_id == TYPE_POISON) { return void_result(); }
        if (value_layout_contains(c, f_type_id, info.type_id, [])) {
            throw_type_error(p.pos, "Struct '" + struct_name + "' contains itself by value through field '" + f_name + "'. Use a pointer for recursive storage.");
            return void_result();
        }

        let f_llvm_type: String = get_llvm_type_str(c, f_type_id);
        if (idx > 0) { llvm_body = llvm_body + ", "; }
        llvm_body += f_llvm_type;
        
        fields_vec.append(FieldInfo(name=f_name, type=f_type_id, llvm_type=f_llvm_type, offset=idx, is_const=false));
        idx += 1;
    }

    info.fields = fields_vec;
    store_struct(c, info);
    if (fields_vec.length() == 0) { llvm_body = "i8"; }

    // %struct.Test = type { i32, i32 }
    let def_str: String = info.llvm_name + " = type { " + llvm_body + " }\n\n";
    c.generic_type_defs += def_str;
    
    return void_result();
}

func compile_struct_init(c: Compiler, s_info: StructInfo, n_call: CallNode) -> CompileResult {
    let obj_ptr: String = next_reg(c);
    c.output_file.write(c.indent + obj_ptr + " = alloca " + s_info.llvm_name + "\n");
    c.output_file.write(c.indent + "store " + s_info.llvm_name + " zeroinitializer, " + s_info.llvm_name + "* " + obj_ptr + "\n");

    let fields_vec: Vector(Struct) = s_info.fields;
    let f_len: Int = 0;
    if (fields_vec is !null) { f_len = fields_vec.length(); }

    if (has_node(s_info.init_body)) {
        let template: GenericTemplate = c.generic_instance_templates.lookup("" + s_info.type_id);
        let previous_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
        let previous: GenericTemplate = GenericTemplate();
        if (has_template(template)) {
            let bindings: Dict(String, SymbolInfo) = c.generic_instance_bindings.lookup("" + s_info.type_id);
            previous = use_generic_context(c, template, bindings);
        }
        enter_scope(c);
        c.symbol_table.table.put("this", SymbolInfo(reg=obj_ptr, type=s_info.type_id, origin_type=s_info.type_id));
        compile_node(c, s_info.init_body);
        exit_scope(c);
        if (has_template(template)) {
            restore_generic_context(c, previous, previous_bindings);
        }
    }

    let args: Vector(ArgNode) = n_call.args;
    let a_len: Int = 0;
    if (args is !null) { a_len = args.length(); }
    if (a_len > f_len) {
        throw_type_error(n_call.pos, "struct '" + s_info.name + "' accepts at most " + f_len + " arguments, got " + a_len);
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    let arg_idx: Int = 0;
    let assigned_fields: Dict(String, StringConstant) = Dict();
    let saw_named: Bool = false;
    
    while (arg_idx < a_len) {
        let arg_curr: ArgNode = args[arg_idx];

        let target_f: FieldInfo = FieldInfo();
        if (arg_curr.name is !null) {
            saw_named = true;
            target_f = find_field(s_info, arg_curr.name);
            if (!has_field(target_f)) { throw_name_error(n_call.pos, "struct '" + s_info.name + "' has no field '" + arg_curr.name + "'"); return CompileResult(reg="poison", type=TYPE_POISON); }
        } else {
            if saw_named { throw_invalid_syntax(n_call.pos, "Positional argument cannot follow a named argument"); return CompileResult(reg="poison", type=TYPE_POISON); }
            target_f = get_field_by_index(s_info, arg_idx);
        }
        if (!has_field(target_f)) { throw_type_error(n_call.pos, "Too many arguments for struct '" + s_info.name + "'"); return CompileResult(reg="poison", type=TYPE_POISON); }
        if (assigned_fields.contains_key(target_f.name)) { throw_name_error(n_call.pos, "Field '" + target_f.name + "' is initialized more than once"); return CompileResult(reg="poison", type=TYPE_POISON); }
        assigned_fields.put(target_f.name, StringConstant(id=0, value=target_f.name));

        if (has_field(target_f)) { c.expected_type = target_f.type; }
        let val_res: CompileResult = compile_node(c, arg_curr.val);
        c.expected_type = 0;

        if (has_field(target_f)) {
            val_res = emit_implicit_cast(c, val_res, target_f.type, n_call.pos);
            if (val_res.type != TYPE_POISON) {
                let f_ptr: String = next_reg(c);
                c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + obj_ptr + ", i32 0, i32 " + target_f.offset + "\n");
                if (result_owns_value(c, target_f.type) && !val_res.owns_ref) {
                    emit_retain_value(c, val_res.reg, target_f.type);
                }
                c.output_file.write(c.indent + "store " + target_f.llvm_type + " " + val_res.reg + ", " + target_f.llvm_type + "* " + f_ptr + "\n");
            }
        }
        arg_idx += 1;
    }
    let result: String = next_reg(c);
    c.output_file.write(c.indent + result + " = load " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + obj_ptr + "\n");

    return CompileResult(reg=result, type=s_info.type_id, owns_ref=needs_drop(c, s_info.type_id));
}

func zero_value(c: Compiler, info: FuncInfo, node: CallNode) -> CompileResult {
    if (node.args is !null && node.args.length() != 0) { throw_type_error(node.pos, "Argument count mismatch. Expected 0, got " + node.args.length()); return CompileResult(reg="poison", type=TYPE_POISON); }

    let type_id: Int = info.ret_type;
    let value: String = "0";
    if (type_id == TYPE_FLOAT || type_id == TYPE_FLOAT32) {
        value = "0.0";
    } else if (is_nullable_reference_type(c, type_id) || is_pointer_type(c, type_id)) {
        value = "null";
    } else {
        let type_info: StructInfo = c.struct_id_map.lookup("" + type_id);
        let array_info: ArrayInfo = c.array_info_map.lookup("" + type_id);
        if ((has_struct(type_info) && type_info.is_interface) ||
            (has_array_info(array_info) && array_info.size >= 0) ||
            is_fallible_type(c, type_id) || is_value_struct(c, type_id)) {
            value = "zeroinitializer";
        }
    }
    return CompileResult(reg=value, type=type_id);
}

func compile_class_init(c: Compiler, s_info: StructInfo, n_call: CallNode) -> CompileResult {
    let size_ty: String = get_size_llvm_type();
    let size_ptr: String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr " + s_info.llvm_name + ", " + s_info.llvm_name + "* null, " + size_ty + " 1\n");
    let object_size: String = next_reg(c);
    c.output_file.write(c.indent + object_size + " = ptrtoint " + s_info.llvm_name + "* " + size_ptr + " to " + size_ty + "\n");
    let obj_ptr: String = emit_alloc_obj(c, object_size, "" + s_info.type_id, s_info.llvm_name + "*");

    let fields_vec: Vector(Struct) = s_info.fields;
    let f_len: Int = 0;
    if (fields_vec is !null) { f_len = fields_vec.length(); }
    let f_idx: Int = 0;

    while (f_idx < f_len) {
        let f_curr: FieldInfo = fields_vec[f_idx];
        let f_ptr: String = next_reg(c);
        c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + obj_ptr + ", i32 0, i32 " + f_curr.offset + "\n");
        
        if (f_curr.name == "_vptr") {
            let vtable_cast: String = next_reg(c);
            c.output_file.write(c.indent + vtable_cast + " = bitcast " + class_vtable_type(c, s_info) + "* " + s_info.vtable_name + " to i8*\n");
            c.output_file.write(c.indent + "store i8* " + vtable_cast + ", i8** " + f_ptr + "\n");
        } else {
            let zero_val: String = "0";
            if (f_curr.type == TYPE_FLOAT) { zero_val = "0.0"; }
            else {
                let field_info: StructInfo = c.struct_id_map.lookup("" + f_curr.type);
                let field_array: ArrayInfo = c.array_info_map.lookup("" + f_curr.type);
                if (is_fallible_type(c, f_curr.type) ||
                    is_value_struct(c, f_curr.type) ||
                    (has_struct(field_info) && field_info.is_interface) ||
                    (has_array_info(field_array) && field_array.size >= 0)) {
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

    let init_name: String = s_info.name + "_$init";
    let init_func: FuncInfo = c.func_table.lookup(init_name);
    
    if (has_func(init_func)) {
        queue_generic_class_method(c, s_info, "$init");
        let args_str: String = s_info.llvm_name + "* " + obj_ptr;
        let args: Vector(ArgNode) = n_call.args;
        let a_len: Int = 0; if (args is !null) { a_len = args.length(); }
        let arg_idx: Int = 0;
        let owned_args: Vector(Struct) = [];
        let arg_types: Vector(Struct) = init_func.arg_types;
        
        let expected_arg_count: Int = 0;
        if (arg_types is !null) { expected_arg_count = arg_types.length() - 1; }
        
        let native_args: BoundCallArgs = bind_native_args(args, init_func, 1, n_call.pos);
        if (!has_bound_args(native_args)) { return CompileResult(reg="poison", type=TYPE_POISON); }
        args = native_args.ordered;
        a_len = expected_arg_count;

        while (arg_idx < a_len) {
            if (init_func.variadic_param > 0 && arg_idx == init_func.variadic_param - 1) {
                let pack_type: TypeListNode = arg_types[arg_idx + 1];
                let pack_info: ArrayInfo = c.array_info_map.lookup("" + pack_type.type);
                let pack: CompileResult = compile_variadic_pack(c, native_args.variadic, pack_info.base_type, n_call.pos);
                if (pack.type == TYPE_POISON) { return pack; }
                args_str += ", " + get_llvm_type_str(c, pack.type) + " " + pack.reg;
                arg_idx += 1;
                continue;
            }
            let arg_node_curr: ArgNode = args[arg_idx];
            let type_node_curr: TypeListNode = arg_types[arg_idx + 1]; // +1 skip self
            let expected_type: Int = type_node_curr.type;

            c.expected_type = expected_type;
            let arg_val: CompileResult = compile_node(c, arg_node_curr.val);
            c.expected_type = 0;
            arg_val = emit_implicit_cast(c, arg_val, expected_type, n_call.pos);

            let ty_str: String = get_llvm_type_str(c, arg_val.type);
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
        let args: Vector(ArgNode) = n_call.args;
        let a_len: Int = 0; if (args is !null) { a_len = args.length(); }
        if (a_len > 0) {
            throw_type_error(n_call.pos, "Class '" + s_info.name + "' has no init method, but arguments were provided.");
            return void_result();
        }
    }

    return CompileResult(reg=obj_ptr, type=s_info.type_id);
}

func register_class_methods(c: Compiler, class_name: String, class_type_id: Int, methods: Vector(Struct)) -> Bool {
    let index: Int = 0;
    while (methods is !null && index < methods.length()) {
        let method_node: MethodDefNode = methods[index];
        let method_name: String = method_base_name(c, method_node);

        let ret_type: Int = resolve_type(c, method_node.return_type);
        if (ret_type == TYPE_AUTO) {
            throw_type_error(method_node.pos, "Auto return type deduction is not supported in methods.");
            return false;
        }
        if (method_node.name_tok.value == "$type") {
            let target: Int = ret_type;
            if (is_fallible_type(c, target)) {
                target = get_inner_fallible_type(c, target);
            }
            if (!is_conversion_target(c, target)) {
                throw_type_error(method_node.pos, "Conversion target " + get_type_name(c, target) + " is not a built-in value type");
                return false;
            }
        }

        let arg_types: Vector(Struct) = [TypeListNode(type=class_type_id)];
        let arg_names: Vector(String) = ["self"];
        if (!check_duplicate_params(method_node.params, "method '" + method_name + "'", method_node.pos)) {
            return false;
        }

        let param_index: Int = 0;
        while (method_node.params is !null && param_index < method_node.params.length()) {
            let param: ParamNode = method_node.params[param_index];
            let param_type: Int = callable_param_type(c, param);
            if (param_type == TYPE_AUTO) {
                throw_type_error(param.pos, "Auto cannot be used in method parameters.");
                return false;
            }

            arg_types.append(TypeListNode(type=param_type));
            arg_names.append(param.name_tok.value);
            param_index += 1;
        }

        let key: String = class_name + "_" + method_name;
        if (has_func(c.func_table.lookup(key))) { throw_name_error(method_node.pos, "Method '" + key + "' is already defined."); return false; }
        let symbol: String = mangle_wl_name(c, class_name + ".", method_name, arg_types);
        c.func_table.put(key, FuncInfo(name=symbol, base_name=method_name, ret_type=ret_type, arg_types=arg_types, arg_names=arg_names, is_varargs=false, mutates_self=method_mutates_self(c, method_node.body), variadic_param=variadic_param_index(method_node.params), default_args=param_defaults(method_node.params)));
        index += 1;
    }
    return true;
}

func compile_class_def(c: Compiler, node: ClassDefNode) -> CompileResult {
    if (node.type_params is !null && 
        node.type_params.length() > 0 && 
        c.generic_class_type == 0) {
        return void_result();
    }

    let raw_name: String = node.name_tok.value;
    let class_name: String = c.current_package_prefix + raw_name;
    if (c.generic_class_type != 0) {
        let generic_info: StructInfo = c.struct_id_map.lookup("" + c.generic_class_type);
        class_name = generic_info.name;
    }

    let full_name: String = "class." + class_name;
    if (has_struct(c.struct_table.lookup(full_name))) {
        throw_import_error(node.pos, "Class '" + class_name + "' is already defined.");
        return void_result();
    }

    let info: StructInfo = c.struct_table.lookup(class_name);
    let parent_info: StructInfo = StructInfo();
    if (has_node(node.parent_tok)) {
        let parent_type: Int = resolve_type(c, node.parent_tok);
        parent_info = c.struct_id_map.lookup("" + parent_type);
        if (!has_struct(parent_info) || !parent_info.is_class) {
            throw_type_error(node.pos, "Type " + get_type_name(c, parent_type) + " is not a class.");
            return void_result();
        }
        info.parent_id = parent_info.type_id;
    }

    let effective_interfaces: Vector(Struct) = [];
    if (has_struct(parent_info)) {
        let inherited_idx: Int = 0;
        while (parent_info.interfaces is !null && inherited_idx < parent_info.interfaces.length()) {
            let inherited: TypeListNode = parent_info.interfaces[inherited_idx];
            if (!add_interface_type(c, effective_interfaces, inherited.type, node.pos)) { return void_result(); }
            inherited_idx += 1;
        }
    }
    let declared_idx: Int = 0;
    while (node.interfaces is !null && declared_idx < node.interfaces.length()) {
        let declared: NodeID = node.interfaces[declared_idx];
        if (!add_interface(c, effective_interfaces, declared, node.pos)) { return void_result(); }
        declared_idx += 1;
    }
    info.interfaces = effective_interfaces;
    store_struct(c, info);

    check_class_initialization(c, class_name, node, parent_info);

    let llvm_body: String = "";
    let fields_vec: Vector(Struct) = [];
    let vtable_vec: Vector(Struct) = [];
    let current_offset: Int = 0;

    if (has_struct(parent_info)) {
        let p_fields: Vector(Struct) = parent_info.fields;
        let pf_len: Int = p_fields.length();
        let pf_i: Int = 0;
        while (pf_i < pf_len) {
            let pf: FieldInfo = p_fields[pf_i];
            fields_vec.append(FieldInfo(name=pf.name, type=pf.type, llvm_type=pf.llvm_type, offset=pf.offset, is_const=pf.is_const));
            if (pf_i > 0) { llvm_body += ", "; }
            llvm_body += pf.llvm_type;
            current_offset += 1;
            pf_i += 1;
        }

        let p_vt: Vector(Struct) = parent_info.vtable;
        let pvt_len: Int = p_vt.length();
        let pvt_i: Int = 0;
        while (pvt_i < pvt_len) {
            vtable_vec.append(p_vt[pvt_i]);
            pvt_i += 1;
        }
    } else {
        fields_vec.append(FieldInfo(name="_vptr", type=TYPE_VOID, llvm_type="i8*", offset=0, is_const=true));
        llvm_body = "i8*";
        current_offset = 1;
    }

    let my_fields: Vector(NodeID) = node.fields;
    let mf_len: Int = 0; if (my_fields is !null) { mf_len = my_fields.length(); }
    let mf_idx: Int = 0;
    let class_field_names: Dict(String, StringConstant) = Dict();
    let inherited_field_idx: Int = 0;
    while (inherited_field_idx < fields_vec.length()) { let inherited_field: FieldInfo = fields_vec[inherited_field_idx]; class_field_names.put(inherited_field.name, StringConstant(id=0, value=inherited_field.name)); inherited_field_idx += 1; }
    while (mf_idx < mf_len) {
        let p: VarDeclareNode = get_var_decl_node(c.arena, my_fields[mf_idx]);
        let f_name: String = p.name_tok.value;
        if (class_field_names.contains_key(f_name)) { throw_name_error(p.pos, "field '" + f_name + "' is already defined in class '" + class_name + "'"); return void_result(); }
        if (has_func(find_method(vtable_vec, f_name))) {
            throw_name_error(p.pos, "Class '" + class_name + "' cannot use '" + f_name + "' as both a field and a method.");
            return void_result();
        }
        class_field_names.put(f_name, StringConstant(id=0, value=f_name));
        let f_type_id: Int = resolve_type(c, p.type_node);

        if (f_type_id == TYPE_AUTO) {
            if (!has_node(p.value)) {
                throw_type_error(p.pos, "field '" + f_name + "' needs an explicit type when it has no initializer.");
                return void_result();
            }
            f_type_id = get_expr_type(c, p.value);
            if (f_type_id == 0 || f_type_id == TYPE_AUTO) {
                throw_type_error(p.pos, "Failed to statically infer type for 'Auto' in class field '" + f_name + "'.");
                return void_result();
            }
        }

        let f_llvm_type: String = get_llvm_type_str(c, f_type_id);
        
        if (current_offset > 0) { llvm_body += ", "; }
        llvm_body += f_llvm_type;
        fields_vec.append(FieldInfo(name=f_name, type=f_type_id, llvm_type=f_llvm_type, offset=current_offset, is_const=p.is_const));
        current_offset += 1;
        mf_idx += 1;
    }
    info.fields = fields_vec;

    let def_str: String = info.llvm_name + " = type { " + llvm_body + " }\n";
    c.generic_type_defs += def_str;

    let my_methods: Vector(NodeID) = node.methods;
    let mm_len: Int = 0; if (my_methods is !null) { mm_len = my_methods.length(); }
    let mm_idx: Int = 0;
    while (mm_idx < mm_len) {
        let m_node: MethodDefNode = get_method_def_node(c.arena, my_methods[mm_idx]);
        let raw_m_name: String = method_base_name(c, m_node);

        if (!raw_m_name.starts_with("$") && class_field_names.contains_key(raw_m_name)) {
            throw_name_error(m_node.pos, "Class '" + class_name + "' cannot use '" + raw_m_name + "' as both a field and a method.");
            return void_result();
        }

        if (m_node.type_params is !null && m_node.type_params.length() > 0) {
            mm_idx++;
            continue;
        }
        
        if (raw_m_name != "$init" && raw_m_name != "$field_init") {
            let m_name: String = class_name + "_" + raw_m_name;
            let f_info: FuncInfo = c.func_table.lookup(m_name);

            if (!has_func(f_info)) {
                throw_name_error(m_node.pos, "Compiler internal error: Method '" + m_name + "' was not properly registered.");
                return void_result();
            }
            f_info.mutates_self = method_mutates_self(c, m_node.body);
            c.func_table.put(m_name, f_info);
            
            if (f_info.compiler_link_name is !null && 
                f_info.compiler_link_name.length() > 0) {
                mm_idx += 1;
                continue;
            }
            let vt_len: Int = vtable_vec.length();
            let vt_i: Int = 0;
            let is_override: Bool = false;
            while (vt_i < vt_len) {
                let p_func: FuncInfo = vtable_vec[vt_i];
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
    store_struct(c, info);

    let vt_final_len: Int = vtable_vec.length();
    let vtable_type: String = "%vtable_type." + class_name;
    if (c.generic_class_type != 0) {
        vtable_type = generic_llvm_name("%vtable_type.__generic.", info.type_id);
    }
    c.generic_type_defs += vtable_type + " = type [ " + vt_final_len + " x i8* ]\n";

    let vt_str: String = info.vtable_name + " = global " + vtable_type;
    if (vt_final_len == 0) {
        vt_str += " zeroinitializer\n\n";
    } else if (c.generic_class_type != 0) {
        c.generic_vtables.append(info);
        vt_str = "";
    } else {
        vt_str += " [ ";
        let vt_i: Int = 0;
        while (vt_i < vt_final_len) {
            let f_info: FuncInfo = vtable_vec[vt_i];
            let sig: String = get_func_sig_str(c, f_info);
            if (vt_i > 0) { vt_str += ", "; }
            vt_str += "i8* bitcast (" + sig + " @" + f_info.name + " to i8*)";
            vt_i += 1;
        }
        vt_str += " ]\n\n";
    }
    if (vt_str.length() > 0) { c.output_file.write(vt_str); }

    if (info.interfaces is !null) {
        let i_len: Int = info.interfaces.length();
        let i_idx: Int = 0;
        while (i_idx < i_len) {
            let interface_type: TypeListNode = info.interfaces[i_idx];
            let i_info: StructInfo = c.struct_id_map.lookup("" + interface_type.type);
            let raw_i_name: String = get_type_name(c, interface_type.type);
            if (!has_struct(i_info) || !i_info.is_interface) {
                throw_name_error(node.pos, "Interface '" + raw_i_name + "' is not defined or is not an interface.");
                return void_result();
            }
            let i_name: String = i_info.name;
            
            let im_methods: Vector(Struct) = i_info.vtable;
            let im_len: Int = 0; if (im_methods is !null) { im_len = im_methods.length(); }
            
            let itable_name: String = "@itable." + class_name + "." + i_name;
            c.output_file.write("%itable_type." + class_name + "." + i_name + " = type [ " + im_len + " x i8* ]\n");
            let it_str: String = itable_name + " = global %itable_type." + class_name + "." + i_name;
            
            if (im_len == 0) {
                it_str += " zeroinitializer\n\n";
            } else {
                it_str += " [ ";
                let im_idx: Int = 0;
                while (im_idx < im_len) {
                    let req_m: MethodDefNode = im_methods[im_idx];
                    let req_name: String = req_m.name_tok.value;
                    
                    let found_impl: FuncInfo = FuncInfo();
                    let vt_idx: Int = 0;
                    while (vt_idx < vt_final_len) {
                        let f: FuncInfo = vtable_vec[vt_idx];
                        if (f.base_name == req_name) {
                            let match: Bool = true;
                            let req_ret_type: Int = interface_method_type_for(c, i_info, req_m.return_type, info.type_id);
                            if (f.ret_type != req_ret_type) {
                                match = false;
                            } else {
                                let req_params: Vector(ParamNode) = req_m.params;
                                let req_p_len: Int = 0;
                                if (req_params is !null) { req_p_len = req_params.length(); }
                                
                                let f_p_len: Int = 0;
                                if (f.arg_types is !null) { f_p_len = f.arg_types.length(); }
                                
                                if (f_p_len != req_p_len + 1) {
                                    match = false;
                                } else {
                                    let p_idx: Int = 0;
                                    while (p_idx < req_p_len) {
                                        let req_p: ParamNode = req_params[p_idx];
                                        let req_p_type: Int = interface_method_type_for(c, i_info, req_p.type_tok, info.type_id);
                                        let f_p: TypeListNode = f.arg_types[p_idx + 1];
                                        
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
                    
                    if (!has_func(found_impl)) {
                        throw_name_error(node.pos, "Class '" + raw_name + "' does not implement interface method '" + req_name + "'.");
                        return void_result();
                    }
                    
                    let sig: String = get_func_sig_str(c, found_impl);
                    queue_generic_class_method(c, info, found_impl.base_name);
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

    if (c.generic_class_type == 0) {
        mm_idx = 0;
        while (mm_idx < mm_len) {
            let m_node: MethodDefNode = get_method_def_node(c.arena, my_methods[mm_idx]);
            if (m_node.type_params is null || m_node.type_params.length() == 0) {
                compile_method_def(c, class_name, m_node);
            }
            mm_idx += 1;
        }
    }
    
    return void_result();
}

func compile_field_access(c: Compiler, node: FieldAccessNode) -> CompileResult {
    let obj_base: Int = node_tag(node.obj);

    let is_module: Bool = false;
    let full_name: String = "";
    let owner_type: StructInfo = StructInfo();
    let owner_name: String = "";
    
    let path_parts: Vector(String) = [];
    let curr_obj: NodeID = node.obj;
    let curr_base: Int = node_tag(curr_obj);
    while (curr_base == NODE_FIELD_ACCESS) {
        let inner_f: FieldAccessNode = get_field_access_node(c.arena, curr_obj);
        path_parts.append(inner_f.field_name);
        curr_obj = inner_f.obj;
        curr_base = node_tag(curr_obj);
    }
    if (curr_base == NODE_VAR_ACCESS) {
        let inner_v: VarAccessNode = get_var_access_node(c.arena, curr_obj);
        let root_name: String = inner_v.name_tok.value;
        if (!has_symbol(find_symbol(c, root_name))) {
            let module_prefix: String = c.current_file_visible_prefixes.lookup(root_name);
            if (module_prefix is !null) {
                full_name = module_member_name(module_prefix, path_parts, node.field_name);
                is_module = true;
            } else {
                let source_name: String = module_member_name(root_name + ".", path_parts, node.field_name);
                let mapped_global: String = c.current_file_global_aliases.lookup(source_name);
                if (mapped_global is !null) {
                    full_name = mapped_global;
                    is_module = true;
                }
                if (!is_module) {
                    let mapped_root: String = null;
                    let local_type_name: String = c.current_package_prefix + root_name;
                    if (has_struct(c.struct_table.lookup(local_type_name))) {
                        mapped_root = local_type_name;
                    } else {
                        mapped_root = c.current_file_type_aliases.lookup(root_name);
                    }
                    if (mapped_root is null) {
                        let alias_info: NamedTypeInfo = find_named_decl(c, root_name);
                        if (has_named_type(alias_info) && alias_info.is_alias) {
                            owner_type = c.struct_id_map.lookup("" + resolve_named_type(c, alias_info));
                            if (has_struct(owner_type)) { mapped_root = owner_type.name; }
                        }
                    }
                    if (mapped_root is !null) {
                        if (!has_struct(owner_type)) {
                            owner_type = c.struct_table.lookup(mapped_root);
                        }
                        owner_name = root_name;
                        full_name = module_member_name(mapped_root + ".", path_parts, node.field_name);
                        if (has_struct(owner_type) || has_symbol(c.global_symbol_table.lookup(full_name))) { is_module = true; }
                    }
                }
            }
        }
    }

    if is_module {
        let g_alias_var: String = c.global_var_aliases.lookup(full_name);
        if (g_alias_var is !null) { full_name = g_alias_var; }

        if (node.field_name.starts_with("__")) {
            throw_name_error(node.pos, "Undefined module variable '" + full_name + "'.");
            return void_result();
        }

        let g_info: SymbolInfo = c.global_symbol_table.lookup(full_name);
        if (!has_symbol(g_info)) {
            let len_full: Int = full_name.length();
            let len_field: Int = node.field_name.length();
            if (len_full > len_field + 1) {
                let type_part: String = full_name.slice(0, len_full - len_field - 1);
                
                let real_type_name: String = type_part;
                let c_alias: String = c.current_file_type_aliases.lookup(type_part);
                if (c_alias is !null) { real_type_name = c_alias; }
                else {
                    let g_alias: String = c.global_type_aliases.lookup(type_part);
                    if (g_alias is !null) { real_type_name = g_alias; }
                }
                
                let resolved_enum_field: String = real_type_name + "." + node.field_name;
                g_info = c.global_symbol_table.lookup(resolved_enum_field);
            }
        }

        if (has_symbol(g_info)) {
            if (g_info.reg.starts_with("$intrinsic.")) { return emit_target_intrinsic(c, g_info); }
            let llvm_ty_str: String = get_llvm_type_str(c, g_info.type);
            let val_reg: String = next_reg(c);
            c.output_file.write(c.indent + val_reg + " = load " + llvm_ty_str + ", " + llvm_ty_str + "* " + g_info.reg + "\n");
            return CompileResult(reg=val_reg, type=g_info.type, origin_type=g_info.origin_type);
        } else {
            if (has_struct(owner_type)) {
                let owner_kind: String = "Type";
                if (owner_type.is_enum) { owner_kind = "Enum"; }
                throw_name_error(node.pos, owner_kind + " '" + owner_name + "' has no member '" + node.field_name + "'.");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            let mod_name: String = format_ast_path(c, node.obj);
            throw_name_error(node.pos, "Undefined field, function or enum variant '" + node.field_name + "' in module '" + mod_name + "'.");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
    }

    let obj_res: CompileResult = compile_node(c, node.obj);
    if (has_result(obj_res) && obj_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

    if (is_pointer_type(c, obj_res.type)) {
        let base_info: SymbolInfo = c.ptr_base_map.lookup("" + obj_res.type);
        if (has_symbol(base_info)) {
            let s_check: StructInfo = c.struct_id_map.lookup("" + base_info.type);
            if (has_struct(s_check)) {
                let ptr_is_null: String = next_reg(c);
                let ptr_ty_str: String = get_llvm_type_str(c, obj_res.type);
                c.output_file.write(c.indent + ptr_is_null + " = icmp eq " + ptr_ty_str + " " + obj_res.reg + ", null\n");
                
                let label_ok: String = "ptr_ok_" + c.reg_count;
                let label_fail: String = "ptr_fail_" + c.reg_count;
                c.reg_count += 1;
                
                c.output_file.write(c.indent + "br i1 " + ptr_is_null + ", label %" + label_fail + ", label %" + label_ok + "\n");
                c.output_file.write("\n" + label_fail + ":\n");
                emit_runtime_error(c, node.pos, "Null pointer dereference");
                
                c.output_file.write("\n" + label_ok + ":\n");

                let loaded_reg: String = next_reg(c);
                let base_ty_str: String = get_llvm_type_str(c, base_info.type);
                c.output_file.write(c.indent + loaded_reg + " = load " + base_ty_str + ", " + base_ty_str + "* " + obj_res.reg + "\n");

                obj_res.reg = loaded_reg;
                obj_res.type = base_info.type;
            }
        }
    }

    let type_id: Int = get_repr_type(c, obj_res.type);
    let obj_reg: String = obj_res.reg;


    let obj_llvm_ty: String = get_llvm_type_str(c, obj_res.type);
    let null_info: StructInfo = c.struct_id_map.lookup("" + obj_res.type);
    if (is_nullable_reference_type(c, obj_res.type)) {
        let is_null: String = next_reg(c);
        let null_check_reg: String = obj_reg;
        let null_check_type: String = obj_llvm_ty;
        if (has_struct(null_info) && null_info.is_interface) {
            null_check_reg = next_reg(c);
            null_check_type = "i8*";
            c.output_file.write(c.indent + null_check_reg + " = extractvalue { i8*, i8* } " + obj_reg + ", 0\n");
        }
        c.output_file.write(c.indent + is_null + " = icmp eq " + null_check_type + " " + null_check_reg + ", null\n");
        let label_ok: String = "access_ok_" + c.reg_count;
        let label_fail: String = "access_fail_" + c.reg_count;
        c.reg_count += 1;
        c.output_file.write(c.indent + "br i1 " + is_null + ", label %" + label_fail + ", label %" + label_ok + "\n");

        c.output_file.write("\n" + label_fail + ":\n");
        emit_runtime_error(c, node.pos, "Null pointer dereference");

        c.output_file.write("\n" + label_ok + ":\n");
    }


    if (type_id == TYPE_GENERIC_STRUCT || type_id == TYPE_GENERIC_CLASS) {
        let base_obj: Int = node_tag(node.obj);
        if (base_obj == NODE_VAR_ACCESS) {
            let v_node: VarAccessNode = get_var_access_node(c.arena, node.obj);
            let info: SymbolInfo = find_symbol(c, v_node.name_tok.value);
            if (has_symbol(info) && info.origin_type >= 100) {
                type_id = info.origin_type;
                
                // i8* -> %struct.Test*
                let s_info_temp: StructInfo = c.struct_id_map.lookup("" + type_id);
                if (has_struct(s_info_temp)) {
                    let cast_reg: String = next_reg(c);
                    c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + obj_reg + " to " + s_info_temp.llvm_name + "*\n");
                    obj_reg = cast_reg;
                }
            }
        }
    }
    let s_info: StructInfo = c.struct_id_map.lookup("" + type_id);
    if (!has_struct(s_info)) {
        throw_type_error(node.pos, "Cannot access field on non-struct type (or generic Struct/Class without origin inference).");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    if (node.field_name.starts_with("__")) {
        let class_prefix: String = "";
        let dot_idx: Int = s_info.name.length() - 1;
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
    
    let field: FieldInfo = find_field(s_info, node.field_name);
    
    if (has_field(field)) {
        if (!s_info.is_class && !s_info.is_interface) {
            let arr_check: ArrayInfo = c.array_info_map.lookup("" + field.type);
            if (has_array_info(arr_check) && arr_check.size != -1) {
                let value_slot: String = next_reg(c);
                c.output_file.write(c.indent + value_slot + " = alloca " + s_info.llvm_name + "\n");
                c.output_file.write(c.indent + "store " + s_info.llvm_name + " " + obj_reg + ", " + s_info.llvm_name + "* " + value_slot + "\n");
                let field_ptr: String = next_reg(c);
                c.output_file.write(c.indent + field_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + value_slot + ", i32 0, i32 " + field.offset + "\n");
                return CompileResult(reg=field_ptr, type=field.type, is_const_access=obj_res.is_const_access);
            }

            let value_reg: String = next_reg(c);
            c.output_file.write(c.indent + value_reg + " = extractvalue " + s_info.llvm_name + " " + obj_reg + ", " + field.offset + "\n");
            return CompileResult(reg=value_reg, type=field.type, is_const_access=obj_res.is_const_access);
        }

        let f_ptr: String = next_reg(c);
        c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + obj_reg + ", i32 0, i32 " + field.offset + "\n");

        let arr_check: ArrayInfo = c.array_info_map.lookup("" + field.type);
        if (has_array_info(arr_check)) {
            if (arr_check.size != -1) {
                return CompileResult(reg=f_ptr, type=field.type, is_const_access=obj_res.is_const_access);
            }
        }

        let val_reg: String = next_reg(c);
        c.output_file.write(c.indent + val_reg + " = load " + field.llvm_type + ", " + field.llvm_type + "* " + f_ptr + "\n");
        return CompileResult(reg=val_reg, type=field.type, is_const_access=obj_res.is_const_access);
    }

    if (s_info.is_interface) {
        let methods: Vector(Struct) = s_info.vtable;
        let method_count: Int = 0; if (methods is !null) { method_count = methods.length(); }
        let method_index: Int = 0;
        while (method_index < method_count) {
            let candidate: MethodDefNode = methods[method_index];
            if (candidate.name_tok.value == node.field_name) { break; }
            method_index += 1;
        }
        if (method_index < method_count) {
            let method_node: MethodDefNode = methods[method_index];
            if (obj_res.is_const_access) {
                throw_type_error(node.pos, "Cannot bind a method through const value");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            let object_ptr: String = next_reg(c);
            let table_ptr: String = next_reg(c);
            c.output_file.write(c.indent + object_ptr + " = extractvalue { i8*, i8* } " + obj_reg + ", 0\n");
            c.output_file.write(c.indent + table_ptr + " = extractvalue { i8*, i8* } " + obj_reg + ", 1\n");

            let table_type: String = "[ " + method_count + " x i8* ]";
            let typed_table: String = next_reg(c);
            c.output_file.write(c.indent + typed_table + " = bitcast i8* " + table_ptr + " to " + table_type + "*\n");

            let method_addr: String = next_reg(c);
            let method_ptr: String = next_reg(c);
            c.output_file.write(c.indent + method_addr + " = getelementptr inbounds " + table_type + ", " + table_type + "* " + typed_table + ", i32 0, i32 " + method_index + "\n");
            c.output_file.write(c.indent + method_ptr + " = load i8*, i8** " + method_addr + "\n");

            let bound_args: Vector(Struct) = [];
            let param_index: Int = 0;
            while (method_node.params is !null && param_index < method_node.params.length()) {
                let param: ParamNode = method_node.params[param_index];
                bound_args.append(TypeListNode(type=resolve_type(c, param.type_tok)));
                param_index += 1;
            }
            let return_type: Int = resolve_type(c, method_node.return_type);
            let specific_type_id: Int = get_method_type_id(c, bound_args, return_type, 0, []);
            let closure: String = emit_alloc_closure(c, specific_type_id);
            let function_slot: String = next_reg(c);
            c.output_file.write(c.indent + function_slot + " = bitcast i8* " + closure + " to i8**\n");
            c.output_file.write(c.indent + "store i8* " + method_ptr + ", i8** " + function_slot + "\n");

            let environment_bytes: String = next_reg(c);
            let environment_slot: String = next_reg(c);
            c.output_file.write(c.indent + environment_bytes + " = getelementptr inbounds i8, i8* " + closure + ", i32 " + closure_env_offset() + "\n");
            c.output_file.write(c.indent + environment_slot + " = bitcast i8* " + environment_bytes + " to i8**\n");
            c.output_file.write(c.indent + "store i8* " + object_ptr + ", i8** " + environment_slot + "\n");

            emit_retain(c, obj_reg, type_id);
            emit_retain(c, closure, specific_type_id);

            return CompileResult(reg=closure, type=specific_type_id, origin_type=return_type);
        }
    }

    if (s_info.is_class) {
        let vtable_vec: Vector(Struct) = s_info.vtable;
        let v_len: Int = 0; if (vtable_vec is !null) { v_len = vtable_vec.length(); }
        let m_idx: Int = 0;
        let target_func: FuncInfo = FuncInfo();
        
        while (m_idx < v_len) {
            let m: FuncInfo = vtable_vec[m_idx];
            if (m.base_name == node.field_name) {
                target_func = m;
                break;
            }
            m_idx += 1;
        }
        
        if (has_func(target_func)) {
            if (obj_res.is_const_access) {
                throw_type_error(node.pos, "Cannot bind a method through const value");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            let class_llvm_ty: String = s_info.llvm_name;
            let vptr_addr: String = next_reg(c);
            c.output_file.write(c.indent + vptr_addr + " = getelementptr inbounds " + class_llvm_ty + ", " + class_llvm_ty + "* " + obj_reg + ", i32 0, i32 0\n");
            let vtable_i8ptr: String = next_reg(c);
            c.output_file.write(c.indent + vtable_i8ptr + " = load i8*, i8** " + vptr_addr + "\n");
            let vtable_ptr: String = next_reg(c);
            c.output_file.write(c.indent + vtable_ptr + " = bitcast i8* " + vtable_i8ptr + " to " + class_vtable_type(c, s_info) + "*\n");
            let method_i8ptr_addr: String = next_reg(c);
            c.output_file.write(c.indent + method_i8ptr_addr + " = getelementptr inbounds " + class_vtable_type(c, s_info) + ", " + class_vtable_type(c, s_info) + "* " + vtable_ptr + ", i32 0, i32 " + m_idx + "\n");
            let method_i8ptr: String = next_reg(c);
            c.output_file.write(c.indent + method_i8ptr + " = load i8*, i8** " + method_i8ptr_addr + "\n");

            let bound_args: Vector(Struct) = [];
            let ba_idx: Int = 1;
            while (ba_idx < target_func.arg_types.length()) {
                bound_args.append(target_func.arg_types[ba_idx]);
                ba_idx += 1;
            }
            if (!validate_callable_value(target_func, 1, node.pos, "Method")) {
                return CompileResult(reg="poison", type=TYPE_POISON);
            }

            let specific_type_id: Int = get_method_type_id(c, bound_args, target_func.ret_type, target_func.variadic_param, callable_arg_names(target_func, 1));
            let clo_payload: String = emit_alloc_closure(c, specific_type_id);
            
            let clo_func_ptr: String = next_reg(c);
            c.output_file.write(c.indent + clo_func_ptr + " = bitcast i8* " + clo_payload + " to i8**\n");
            c.output_file.write(c.indent + "store i8* " + method_i8ptr + ", i8** " + clo_func_ptr + "\n");
            
            let clo_env_ptr_i8: String = next_reg(c);
            c.output_file.write(c.indent + clo_env_ptr_i8 + " = getelementptr inbounds i8, i8* " + clo_payload + ", i32 " + closure_env_offset() + "\n");
            let clo_env_ptr: String = next_reg(c);
            c.output_file.write(c.indent + clo_env_ptr + " = bitcast i8* " + clo_env_ptr_i8 + " to i8**\n");
            let obj_i8_ptr: String = next_reg(c);
            c.output_file.write(c.indent + obj_i8_ptr + " = bitcast " + class_llvm_ty + "* " + obj_reg + " to i8*\n");
            c.output_file.write(c.indent + "store i8* " + obj_i8_ptr + ", i8** " + clo_env_ptr + "\n");
            
            emit_retain(c, obj_reg, type_id);
            
            return CompileResult(reg=clo_payload, type=specific_type_id, origin_type=target_func.ret_type);
        }
    }

    throw_name_error(node.pos, "Field '" + node.field_name + "' not found in struct '" + s_info.name + "'.");
    return CompileResult(reg="poison", type=TYPE_POISON);
}

func compile_field_assign(c: Compiler, node: FieldAssignNode) -> CompileResult {
    if (reject_const_write(c, node.obj, node.pos)) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    let obj_base: Int = node_tag(node.obj);

    let is_module: Bool = false;
    let full_name: String = "";
    let path_parts: Vector(String) = [];
    let curr_obj: NodeID = node.obj;
    let curr_base: Int = node_tag(curr_obj);
    while (curr_base == NODE_FIELD_ACCESS) {
        let inner_f: FieldAccessNode = get_field_access_node(c.arena, curr_obj);
        path_parts.append(inner_f.field_name);
        curr_obj = inner_f.obj;
        curr_base = node_tag(curr_obj);
    }
    if (curr_base == NODE_VAR_ACCESS) {
        let root_node: VarAccessNode = get_var_access_node(c.arena, curr_obj);
        let root_name: String = root_node.name_tok.value;
        if (!has_symbol(find_symbol(c, root_name))) {
            let module_prefix: String = c.current_file_visible_prefixes.lookup(root_name);
            if (module_prefix is !null) {
                full_name = module_member_name(module_prefix, path_parts, node.field_name);
                is_module = true;
            } else {
                let source_name: String = module_member_name(root_name + ".", path_parts, node.field_name);
                let mapped_global: String = c.current_file_global_aliases.lookup(source_name);
                if (mapped_global is !null) {
                    full_name = mapped_global;
                    is_module = true;
                }
            }
        }
    }

    if is_module {
        let g_alias_var: String = c.global_var_aliases.lookup(full_name);
        if (g_alias_var is !null) { full_name = g_alias_var; }

        let g_info: SymbolInfo = c.global_symbol_table.lookup(full_name);
        if (node.field_name.starts_with("__")) {
            throw_name_error(node.pos, "Undefined module variable '" + full_name + "'.");
            return void_result();
        }
        if (!has_symbol(g_info)) {
            throw_name_error(node.pos, "Undefined module variable '" + full_name + "'.");
            return void_result();
        }
        if (g_info.is_const) {
            throw_type_error(node.pos, "Cannot assign to constant module variable '" + full_name + "'.");
            return void_result();
        }
        
        c.expected_type = g_info.type;
        let val_res: CompileResult = compile_node(c, node.value);
        c.expected_type = 0;
        
        val_res = emit_implicit_cast(c, val_res, g_info.type, node.pos);
        
        let f_ptr: String = g_info.reg;

        if (result_owns_value(c, g_info.type)) {
            if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, g_info.type); }
            emit_drop_slot(c, f_ptr, g_info.type);
        }
        
        let store_ty: String = get_llvm_type_str(c, g_info.type);
        c.output_file.write(c.indent + "store " + store_ty + " " + val_res.reg + ", " + store_ty + "* " + f_ptr + "\n");
        return val_res;
    }

    if (obj_base == NODE_CALL || obj_base == NODE_VECTOR_LIT || obj_base == NODE_STRING) {
        throw_invalid_syntax(node.pos, "Cannot assign to a field of a temporary right-value object. Assign it to a variable first.");
        return void_result();
    }
    
    let object_type: Int = get_repr_type(c, get_expr_type(c, node.obj));
    let struct_type_id: Int = object_type;
    let struct_ptr_reg: String = "";
    let obj_res: CompileResult = CompileResult();
    if (is_pointer_type(c, object_type)) {
        obj_res = compile_node(c, node.obj);
        if (!has_result(obj_res) || obj_res.type == TYPE_POISON) {
            return CompileResult(reg="poison", type=TYPE_POISON);
        }

        let base_info: SymbolInfo = c.ptr_base_map.lookup("" + object_type);
        if (!has_symbol(base_info)) {
            return CompileResult(reg="poison", type=TYPE_POISON);
        }

        emit_pointer_null_check(c, obj_res.reg, object_type, node.pos);

        struct_type_id = get_repr_type(c, base_info.type);
        struct_ptr_reg = obj_res.reg;

    } else if (is_value_struct(c, object_type)) {
        let object_lvalue: CompileResult = compile_lvalue_ptr(c, node.obj, node.pos);
        if (!has_result(object_lvalue) || object_lvalue.type == TYPE_POISON) {
            return CompileResult(reg="poison", type=TYPE_POISON);
        }

        struct_type_id = get_repr_type(c, object_lvalue.type);
        struct_ptr_reg = object_lvalue.reg;
    } else {
        obj_res = compile_node(c, node.obj);
        if (!has_result(obj_res) || obj_res.type == TYPE_POISON) {
            return CompileResult(reg="poison", type=TYPE_POISON);
        }

        struct_type_id = get_repr_type(c, obj_res.type);
        struct_ptr_reg = obj_res.reg;
    }

    if ((struct_type_id == TYPE_GENERIC_STRUCT || struct_type_id == TYPE_GENERIC_CLASS) && obj_res.origin_type >= 100) {
        struct_type_id = obj_res.origin_type;
        let s_info_temp: StructInfo = c.struct_id_map.lookup("" + struct_type_id);
        if (has_struct(s_info_temp)) {
            let cast_reg: String = next_reg(c);
            c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + struct_ptr_reg + " to " + s_info_temp.llvm_name + "*\n");
            struct_ptr_reg = cast_reg;
        }
    }

    let s_info: StructInfo = c.struct_id_map.lookup("" + struct_type_id);
    if (!has_struct(s_info)) {
        throw_type_error(node.pos, "Cannot assign field to non-struct type.");
        return void_result();
    }

    if (node.field_name.starts_with("__")) {
        let class_prefix: String = "";
        let dot_idx: Int = s_info.name.length() - 1;
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

    let field: FieldInfo = find_field(s_info, node.field_name);
    if (!has_field(field)) {
        throw_name_error(node.pos, "Field '" + node.field_name + "' not found in struct '" + s_info.name + "'.");
        return void_result();
    }

    c.expected_type = field.type;
    let val_res: CompileResult = compile_node(c, node.value);
    c.expected_type = 0;

    val_res = emit_implicit_cast(c, val_res, field.type, node.pos);
    
    let f_ptr: String = next_reg(c);
    c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + struct_ptr_reg + ", i32 0, i32 " + field.offset + "\n");

    if (result_owns_value(c, field.type)) {
        if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, field.type); }
        emit_drop_slot(c, f_ptr, field.type);
    }

    let store_ty: String = get_llvm_type_str(c, field.type);
    c.output_file.write(c.indent + "store " + store_ty + " " + val_res.reg + ", " + store_ty + "* " + f_ptr + "\n");
    return val_res;
}

// todo: add the White Language ABI
func compile_array_literal(c: Compiler, lit_node: VectorLitNode, target_arr_id: Int, ptr_reg: String) -> Void {
    let target_arr: ArrayInfo = c.array_info_map.lookup("" + target_arr_id);
    if (!has_array_info(target_arr)) { return; }
    
    if (lit_node.count > target_arr.size) {
        throw_type_error(lit_node.pos, "Array literal too large: expected " + target_arr.size + " elements, got " + lit_node.count);
        return;
    }
    
    let lit_i: Int = 0;
    let elem_ty_str: String = get_llvm_type_str(c, target_arr.base_type);
    c.output_file.write(c.indent + "store " + target_arr.llvm_name + " zeroinitializer, " + target_arr.llvm_name + "* " + ptr_reg + "\n");
    
    while (lit_i < lit_node.count) {
        let elem_node: ArgNode = lit_node.elements[lit_i];
        let elem_base: Int = node_tag(elem_node.val);
        
        let elem_ptr_reg: String = next_reg(c);
        c.output_file.write(c.indent + elem_ptr_reg + " = getelementptr inbounds " + target_arr.llvm_name + ", " + target_arr.llvm_name + "* " + ptr_reg + ", i32 0, i32 " + lit_i + "\n");
        
        let is_nested: Bool = false;
        if (elem_base == NODE_VECTOR_LIT) {
            let inner_arr_info: ArrayInfo = c.array_info_map.lookup("" + target_arr.base_type);
            if (has_array_info(inner_arr_info)) {
                is_nested = true;
                let inner_lit: VectorLitNode = get_vector_lit_node(c.arena, elem_node.val);
                compile_array_literal(c, inner_lit, target_arr.base_type, elem_ptr_reg);
            }
        }
        
        if (!is_nested) {
            c.expected_type = target_arr.base_type;
            let elem_res: CompileResult = compile_node(c, elem_node.val);
            c.expected_type = 0;
            
            let casted_res: CompileResult = emit_implicit_cast(c, elem_res, target_arr.base_type, lit_node.pos);
            c.output_file.write(c.indent + "store " + elem_ty_str + " " + casted_res.reg + ", " + elem_ty_str + "* " + elem_ptr_reg + "\n");
            
            if (c.scope_depth > 0 && result_owns_value(c, target_arr.base_type) && !casted_res.owns_ref) {
                emit_retain_value(c, casted_res.reg, target_arr.base_type);
            }
        }
        
        lit_i += 1;
    }
}

func compile_vector_append(c: Compiler, vec_node: NodeID, call_node: CallNode) -> CompileResult {
    if (reject_const_write(c, vec_node, call_node.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let args: Vector(ArgNode) = call_node.args;
    let a_len: Int = 0;
    if (args is !null) { a_len = args.length(); }
    if (a_len != 1) { throw_type_error(call_node.pos, "'append' expects exactly 1 argument."); return void_result(); }
    let append_names: Vector(String) = ["value"];
    args = bind_call_args(args, append_names, 0, call_node.pos);
    if (args is null) { return CompileResult(reg="poison", type=TYPE_POISON); }
    
    let arg_node: ArgNode = args[0];
    let vec_res: CompileResult = compile_node(c, vec_node);
    if (has_result(vec_res) && vec_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

    let v_info: SymbolInfo = c.vector_base_map.lookup("" + vec_res.type);
    if (!has_symbol(v_info)) { throw_type_error(call_node.pos, "'append' is only for Vectors."); return void_result(); }
    
    let elem_type: Int = v_info.type;

    c.expected_type = elem_type;
    let arg_res: CompileResult = compile_node(c, arg_node.val);
    c.expected_type = 0;

    arg_res = emit_implicit_cast(c, arg_res, elem_type, call_node.pos);
    let elem_ty_str: String = get_llvm_type_str(c, elem_type);
    let struct_ty: String = get_vector_llvm_type(c, elem_type);
    let size_ty: String = get_size_llvm_type();

    let size_ptr: String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_res.reg + ", i32 0, i32 0\n");
    let size_val: String = next_reg(c);
    c.output_file.write(c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");
    
    let cap_ptr: String = next_reg(c);
    c.output_file.write(c.indent + cap_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_res.reg + ", i32 0, i32 1\n");
    let cap_val: String = next_reg(c);
    c.output_file.write(c.indent + cap_val + " = load " + size_ty + ", " + size_ty + "* " + cap_ptr + "\n");

    let cmp_reg: String = next_reg(c);
    c.output_file.write(c.indent + cmp_reg + " = icmp uge " + size_ty + " " + size_val + ", " + cap_val + "\n");
    
    let grow_label: String = next_label(c);
    let push_label: String = next_label(c);
    
    c.output_file.write(c.indent + "br i1 " + cmp_reg + ", label %" + grow_label + ", label %" + push_label + "\n");

    c.output_file.write("\n" + grow_label + ":\n");
    
    let is_zero_cap: String = next_reg(c);
    c.output_file.write(c.indent + is_zero_cap + " = icmp eq " + size_ty + " " + cap_val + ", 0\n");

    let elem_size_ptr: String = next_reg(c);
    c.output_file.write(c.indent + elem_size_ptr + " = getelementptr " + elem_ty_str + ", " + elem_ty_str + "* null, " + size_ty + " 1\n");
    let elem_size: String = next_reg(c);
    c.output_file.write(c.indent + elem_size + " = ptrtoint " + elem_ty_str + "* " + elem_size_ptr + " to " + size_ty + "\n");

    let max_capacity: String = next_reg(c);
    c.output_file.write(c.indent + max_capacity + " = udiv " + size_ty + " -1, " + elem_size + "\n");

    let growth_limit: String = next_reg(c);
    c.output_file.write(c.indent + growth_limit + " = lshr " + size_ty + " " + max_capacity + ", 1\n");

    let cap_overflow: String = next_reg(c);
    c.output_file.write(c.indent + cap_overflow + " = icmp ugt " + size_ty + " " + cap_val + ", " + growth_limit + "\n");
    let grow_fail: String = next_label(c);
    let grow_calc: String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + cap_overflow + ", label %" + grow_fail + ", label %" + grow_calc + "\n");

    c.output_file.write("\n" + grow_fail + ":\n");
    c.output_file.write(c.indent + "call void @__wl_oom()\n");
    c.output_file.write(c.indent + "unreachable\n");

    c.output_file.write("\n" + grow_calc + ":\n");
    let dbl_cap: String = next_reg(c);
    c.output_file.write(c.indent + dbl_cap + " = mul " + size_ty + " " + cap_val + ", 2\n");
    let new_cap: String = next_reg(c);
    c.output_file.write(c.indent + new_cap + " = select i1 " + is_zero_cap + ", " + size_ty + " 4, " + size_ty + " " + dbl_cap + "\n");

    let data_field_ptr: String = next_reg(c);
    c.output_file.write(c.indent + data_field_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_res.reg + ", i32 0, i32 2\n");
    let old_data: String = next_reg(c);
    c.output_file.write(c.indent + old_data + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_field_ptr + "\n");
    
    let old_data_i8: String = next_reg(c);
    c.output_file.write(c.indent + old_data_i8 + " = bitcast " + elem_ty_str + "* " + old_data + " to i8*\n");

    let bytes_overflow: String = next_reg(c);
    c.output_file.write(c.indent + bytes_overflow + " = icmp ugt " + size_ty + " " + new_cap + ", " + max_capacity + "\n");
    let bytes_fail: String = next_label(c);
    let resize_label: String = next_label(c);
    c.output_file.write(c.indent + "br i1 " + bytes_overflow + ", label %" + bytes_fail + ", label %" + resize_label + "\n");

    c.output_file.write("\n" + bytes_fail + ":\n");
    c.output_file.write(c.indent + "call void @__wl_oom()\n");
    c.output_file.write(c.indent + "unreachable\n");

    c.output_file.write("\n" + resize_label + ":\n");
    
    let new_bytes: String = next_reg(c);
    c.output_file.write(c.indent + new_bytes + " = mul " + size_ty + " " + new_cap + ", " + elem_size + "\n");
    
    let resize_hook: String = get_mangled_symbol(c, "memory_resize", call_node.pos);
    let new_data_i8: String = next_reg(c);
    c.output_file.write(c.indent + new_data_i8 + " = call i8* @" + resize_hook + "(i8* " + old_data_i8 + ", " + size_ty + " " + new_bytes + ")\n");
    emit_alloc_check(c, new_data_i8);
    
    let new_data_typed: String = next_reg(c);
    c.output_file.write(c.indent + new_data_typed + " = bitcast i8* " + new_data_i8 + " to " + elem_ty_str + "*\n");
    c.output_file.write(c.indent + "store " + elem_ty_str + "* " + new_data_typed + ", " + elem_ty_str + "** " + data_field_ptr + "\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + new_cap + ", " + size_ty + "* " + cap_ptr + "\n");
    
    c.output_file.write(c.indent + "br label %" + push_label + "\n");
    c.output_file.write("\n" + push_label + ":\n");
    
    let final_data_field_ptr: String = next_reg(c);
    c.output_file.write(c.indent + final_data_field_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_res.reg + ", i32 0, i32 2\n");
    let final_data: String = next_reg(c);
    c.output_file.write(c.indent + final_data + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + final_data_field_ptr + "\n");
    
    let slot_ptr: String = next_reg(c);
    c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + final_data + ", " + size_ty + " " + size_val + "\n");
    
    if (result_owns_value(c, elem_type) && !arg_res.owns_ref) {
        emit_retain_value(c, arg_res.reg, elem_type);
    }
    c.output_file.write(c.indent + "store " + elem_ty_str + " " + arg_res.reg + ", " + elem_ty_str + "* " + slot_ptr + "\n");
    
    let new_size: String = next_reg(c);
    c.output_file.write(c.indent + new_size + " = add " + size_ty + " " + size_val + ", 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + new_size + ", " + size_ty + "* " + size_ptr + "\n");
    
    return void_result();
}
func compile_vector_drop(c: Compiler, vec_node: NodeID, call_node: CallNode) -> CompileResult {
    if (reject_const_write(c, vec_node, call_node.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let args: Vector(ArgNode) = call_node.args;
    let a_len: Int = 0;
    if (args is !null) { a_len = args.length(); }
    if (a_len > 0) { throw_type_error(call_node.pos, "'drop' expects 0 arguments."); return void_result(); }
    
    let vec_res: CompileResult = compile_node(c, vec_node);
    if (has_result(vec_res) && vec_res.type == TYPE_POISON) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let v_info: SymbolInfo = c.vector_base_map.lookup("" + vec_res.type);
    let elem_type: Int = v_info.type;
    let elem_ty_str: String = get_llvm_type_str(c, elem_type);
    let struct_ty: String = get_vector_llvm_type(c, elem_type);
    let size_ty: String = get_size_llvm_type();

    let size_ptr: String = next_reg(c);
    c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_res.reg + ", i32 0, i32 0\n");
    let size_val: String = next_reg(c);
    c.output_file.write(c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");

    let cmp_reg: String = next_reg(c);
    c.output_file.write(c.indent + cmp_reg + " = icmp ugt " + size_ty + " " + size_val + ", 0\n");
    
    let pop_label: String = next_label(c);
    let empty_label: String = next_label(c);
    let end_label: String = next_label(c);
    
    c.output_file.write(c.indent + "br i1 " + cmp_reg + ", label %" + pop_label + ", label %" + empty_label + "\n");

    c.output_file.write("\n" + empty_label + ":\n");

    emit_runtime_error(c, call_node.pos, "drop from empty vector");

    c.output_file.write("\n" + pop_label + ":\n");
    
    // size--
    let new_size: String = next_reg(c);
    c.output_file.write(c.indent + new_size + " = sub " + size_ty + " " + size_val + ", 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + new_size + ", " + size_ty + "* " + size_ptr + "\n");

    let data_field_ptr: String = next_reg(c);
    c.output_file.write(c.indent + data_field_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + vec_res.reg + ", i32 0, i32 2\n");
    let data_ptr: String = next_reg(c);
    c.output_file.write(c.indent + data_ptr + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_field_ptr + "\n");
    
    let slot_ptr: String = next_reg(c);
    c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", " + size_ty + " " + new_size + "\n");
    
    let ret_val: String = next_reg(c);
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
func compile_vector_lit(c: Compiler, node: VectorLitNode) -> CompileResult {
    let count: Int = node.count;
    let elem_type_id: Int = TYPE_INT; 
    let elements: Vector(ArgNode) = node.elements;
    let e_len: Int = 0;
    if (elements is !null) { e_len = elements.length(); }
    
    let has_expected: Bool = false;
    if (c.expected_type > 0) {
        let v_info: SymbolInfo = c.vector_base_map.lookup("" + c.expected_type);
        if (has_symbol(v_info)) {
            elem_type_id = v_info.type;
            has_expected = true;
        } else {
            elem_type_id = c.expected_type;
            has_expected = true;
        }
    }
    
    if (!has_expected && e_len > 0) {
        let first_arg: ArgNode = elements[0];
        let old_exp: Int = c.expected_type;
        c.expected_type = 0;
        let first_res: CompileResult = compile_node(c, first_arg.val);
        c.expected_type = old_exp;
        elem_type_id = first_res.type;
    }
    
    let vec_type_id: Int = get_vector_type_id(c, elem_type_id);
    let elem_ty_str: String = get_llvm_type_str(c, elem_type_id);
    let struct_name: String = get_vector_llvm_type(c, elem_type_id);
    let size_ty: String = get_size_llvm_type();

    let struct_size_ptr: String = next_reg(c);
    c.output_file.write(c.indent + struct_size_ptr + " = getelementptr " + struct_name + ", " + struct_name + "* null, i32 1\n");
    let struct_size: String = next_reg(c);
    c.output_file.write(c.indent + struct_size + " = ptrtoint " + struct_name + "* " + struct_size_ptr + " to " + size_ty + "\n");
    let vec_ptr: String = emit_alloc_obj(c, struct_size, "" + vec_type_id, struct_name + "*");
    
    let arr_size_ptr: String = next_reg(c);
    let alloc_count: Int = count;
    if (alloc_count == 0) { alloc_count = 1; }
    c.output_file.write(c.indent + arr_size_ptr + " = getelementptr " + elem_ty_str + ", " + elem_ty_str + "* null, " + size_ty + " " + alloc_count + "\n");
    let arr_bytes: String = next_reg(c);
    c.output_file.write(c.indent + arr_bytes + " = ptrtoint " + elem_ty_str + "* " + arr_size_ptr + " to " + size_ty + "\n");
    
    let alloc_hook: String = get_mangled_symbol(c, "memory_alloc", node.pos);
    let raw_data: String = next_reg(c);
    c.output_file.write(c.indent + raw_data + " = call i8* @" + alloc_hook + "(" + size_ty + " " + arr_bytes + ")\n");
    emit_alloc_check(c, raw_data);
    let data_ptr: String = next_reg(c);
    c.output_file.write(c.indent + data_ptr + " = bitcast i8* " + raw_data + " to " + elem_ty_str + "*\n");

    // vector length and capacity follow the target pointer width
    let size_ptr: String = next_reg(c); 
    c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + struct_name + ", " + struct_name + "* " + vec_ptr + ", i32 0, i32 0\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + count + ", " + size_ty + "* " + size_ptr + "\n");
    
    // capacity
    let cap_ptr: String = next_reg(c); 
    c.output_file.write(c.indent + cap_ptr + " = getelementptr inbounds " + struct_name + ", " + struct_name + "* " + vec_ptr + ", i32 0, i32 1\n");
    c.output_file.write(c.indent + "store " + size_ty + " " + count + ", " + size_ty + "* " + cap_ptr + "\n"); 
    
    // data pointer
    let data_field_ptr: String = next_reg(c); 
    c.output_file.write(c.indent + data_field_ptr + " = getelementptr inbounds " + struct_name + ", " + struct_name + "* " + vec_ptr + ", i32 0, i32 2\n");
    c.output_file.write(c.indent + "store " + elem_ty_str + "* " + data_ptr + ", " + elem_ty_str + "** " + data_field_ptr + "\n");
    
    let idx: Int = 0;
    while (idx < e_len) {
        let curr: ArgNode = elements[idx];

        let old_exp: Int = c.expected_type;
        c.expected_type = elem_type_id;
        let val_res: CompileResult = compile_node(c, curr.val);
        c.expected_type = old_exp;

        val_res = emit_implicit_cast(c, val_res, elem_type_id, node.pos);
        
        let slot_ptr: String = next_reg(c);
        c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", " + size_ty + " " + idx + "\n");

        if (result_owns_value(c, elem_type_id) && !val_res.owns_ref) {
            emit_retain_value(c, val_res.reg, elem_type_id);
        }
        
        c.output_file.write(c.indent + "store " + elem_ty_str + " " + val_res.reg + ", " + elem_ty_str + "* " + slot_ptr + "\n");

        idx += 1;
    }
    
    return CompileResult(reg=vec_ptr, type=vec_type_id);
}

func compile_length_method(c: Compiler, obj_node: NodeID, call_node: CallNode) -> CompileResult {
    let args: Vector(ArgNode) = call_node.args;
    let a_len: Int = 0;
    if (args is !null) { a_len = args.length(); }
    if (a_len > 0) {
        throw_type_error(call_node.pos, "Method 'length' does not accept arguments.");
        return void_result();
    }

    let obj_res: CompileResult = compile_node(c, obj_node);
    if (has_result(obj_res) && obj_res.type == TYPE_POISON) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let type_id: Int = get_repr_type(c, obj_res.type);

    // String.length() is the stored UTF-8 byte count
    if (type_id == TYPE_STRING) {
        // read len directly from struct field 1
        let len_ptr: String = next_reg(c);
        c.output_file.write(c.indent + len_ptr + " = getelementptr inbounds %struct.$String, %struct.$String* " + obj_res.reg + ", i32 0, i32 1\n");
        let len_val: String = next_reg(c);
        c.output_file.write(c.indent + len_val + " = load i32, i32* " + len_ptr + "\n");
        return CompileResult(reg=len_val, type=TYPE_INT);
    }

    // Vector.length() is the number of initialized elements
    let is_vec: Bool = false;
    if (type_id >= 100) {
        let v_info: SymbolInfo = c.vector_base_map.lookup("" + type_id);
        if (has_symbol(v_info)) {
            is_vec = true;
        }
    }

    let arr_info: ArrayInfo = c.array_info_map.lookup("" + type_id);
        if (has_array_info(arr_info)) {
            if (arr_info.size == -1) {
                let parts: SliceParts = emit_slice_parts(c, obj_res.reg, type_id, call_node.pos);
                let trunc_reg: String = emit_size_to_int(c, parts.length);
                return CompileResult(reg=trunc_reg, type=TYPE_INT);
            } else {
                return CompileResult(reg="" + arr_info.size, type=TYPE_INT);
            }
        }

    if is_vec {
        let v_info: SymbolInfo = c.vector_base_map.lookup("" + type_id);
        let struct_ty: String = get_vector_llvm_type(c, v_info.type);
        let size_ty: String = get_size_llvm_type();
        
        let size_ptr: String = next_reg(c);
        c.output_file.write(c.indent + size_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + obj_res.reg + ", i32 0, i32 0\n");
        
        let size_val: String = next_reg(c);
        c.output_file.write(c.indent + size_val + " = load " + size_ty + ", " + size_ty + "* " + size_ptr + "\n");

        let trunc_reg: String = emit_size_to_int(c, size_val);
        
        return CompileResult(reg=trunc_reg, type=TYPE_INT);
    }

    throw_type_error(call_node.pos, "Method 'length' is not defined for type " + get_type_name(c, type_id));
    return void_result();
}

func compile_index_access(c: Compiler, node: IndexAccessNode, handled: Bool) -> CompileResult {
    check_out_index(c, node.target, node.index_node, node.pos);
    let target_res: CompileResult = compile_node(c, node.target);
    if (has_result(target_res) && target_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let target_type: Int = get_repr_type(c, target_res.type);

    let s_info: StructInfo = c.struct_id_map.lookup("" + target_type);
    if (has_struct(s_info) && s_info.is_class) {
        let has_get: Bool = false;
        let v_len: Int = 0; if (s_info.vtable is !null) { v_len = s_info.vtable.length(); }
        let m_idx: Int = 0;
        while (m_idx < v_len) {
            let m: FuncInfo = s_info.vtable[m_idx];
            if (m.base_name == "get") { has_get = true; break; }
            m_idx += 1;
        }

        if has_get {
            let fake_args: Vector(ArgNode) = [];
            fake_args.append(ArgNode(val=node.index_node, name=null));
            let fake_call: CallNode = CallNode(type=NODE_CALL, callee=NO_NODE, args=fake_args, type_args=null, pos=node.pos, preserve_fallible=handled);
            return compile_class_method_call(c, s_info, target_res, "get", fake_call);
        }
    }

    let old_exp: Int = c.expected_type;
    c.expected_type = TYPE_INT;
    let index_res: CompileResult = compile_node(c, node.index_node);
    c.expected_type = old_exp;
    if (has_result(index_res) && index_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    
    if (index_res.type != TYPE_INT) {
        throw_type_error(node.pos, "Index must be an Integer.");
        return void_result();
    }

    // string index access
    if (target_type == TYPE_STRING) {
        let src_buf: String = next_reg(c);
        let src_struct_buf: String = next_reg(c);
        c.output_file.write(c.indent + src_struct_buf + " = getelementptr inbounds %struct.$String, %struct.$String* " + target_res.reg + ", i32 0, i32 0\n");
        c.output_file.write(c.indent + src_buf + " = load i8*, i8** " + src_struct_buf + "\n");
        
        let src_len: String = next_reg(c);
        let src_struct_len: String = next_reg(c);
        c.output_file.write(c.indent + src_struct_len + " = getelementptr inbounds %struct.$String, %struct.$String* " + target_res.reg + ", i32 0, i32 1\n");
        c.output_file.write(c.indent + src_len + " = load i32, i32* " + src_struct_len + "\n");
        
        // emit bounds check
        emit_array_bounds_check(c, index_res.reg, src_len, node.pos);
        
        let addr_reg: String = next_reg(c);
        c.output_file.write(c.indent + addr_reg + " = getelementptr inbounds i8, i8* " + src_buf + ", i32 " + index_res.reg + "\n");
        
        let load_reg: String = next_reg(c);
        c.output_file.write(c.indent + load_reg + " = load i8, i8* " + addr_reg + "\n");
        
        return CompileResult(reg=load_reg, type=TYPE_BYTE, origin_type=0);
    }

    if (is_pointer_type(c, target_type)) {
        let base_info: SymbolInfo = c.ptr_base_map.lookup("" + target_type);
        if (has_symbol(base_info)) {
            let elem_type: Int = base_info.type;
            
            if (elem_type == TYPE_VOID) {
                throw_type_error(node.pos, "Cannot index 'ptr Void'. Cast it to a specific pointer type first.");
                return void_result();
            }
            emit_pointer_null_check(c, target_res.reg, target_type, node.pos);
            
            let elem_ty_str: String = get_llvm_type_str(c, elem_type);
            
            let addr_reg: String = next_reg(c);
            c.output_file.write(c.indent + addr_reg + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + target_res.reg + ", i32 " + index_res.reg + "\n");
            
            let load_reg: String = next_reg(c);
            c.output_file.write(c.indent + load_reg + " = load " + elem_ty_str + ", " + elem_ty_str + "* " + addr_reg + "\n");
            
            return CompileResult(reg=load_reg, type=elem_type, origin_type=elem_type);
        }
    }

    // array / slice access
    let arr_info: ArrayInfo = c.array_info_map.lookup("" + target_type);
    if (has_array_info(arr_info)) {
        let elem_type: Int = arr_info.base_type;
        let elem_ty_str: String = get_llvm_type_str(c, elem_type);
        
        let idx_i32: String = index_res.reg;

        let curr_len: String = "";
        let data_ptr: String = "";
        if (arr_info.size == -1) {
            let parts: SliceParts = emit_slice_parts(c, target_res.reg, target_type, node.pos);
            curr_len = emit_size_to_int(c, parts.length);
            data_ptr = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + parts.data + ", " + get_size_llvm_type() + " " + parts.start + "\n");
        } else {
            curr_len = "" + arr_info.size;
            data_ptr = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + target_res.reg + ", i32 0, i32 0\n");
        }

        emit_array_bounds_check(c, idx_i32, curr_len, node.pos);

        let ptr_reg: String = next_reg(c);
        c.output_file.write(c.indent + ptr_reg + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", i32 " + idx_i32 + "\n");

        if (has_array_info(c.array_info_map.lookup("" + elem_type))) {
            return CompileResult(reg=ptr_reg, type=elem_type, origin_type=elem_type, is_const_access=target_res.is_const_access);
        }
        
        let val_reg: String = next_reg(c);
        c.output_file.write(c.indent + val_reg + " = load " + elem_ty_str + ", " + elem_ty_str + "* " + ptr_reg + "\n");
        return CompileResult(reg=val_reg, type=elem_type, origin_type=elem_type, is_const_access=target_res.is_const_access);
    }
    
    // vector access
    let is_vec: Bool = false;
    if (target_res.type >= 100) {
        if (has_symbol(c.vector_base_map.lookup("" + target_res.type))) { is_vec = true; }
    }
    
    if is_vec {
        let v_info: SymbolInfo = c.vector_base_map.lookup("" + target_res.type);
        let elem_type: Int = v_info.type;
        let elem_ty_str: String = get_llvm_type_str(c, elem_type);
        
        let struct_ty: String = get_vector_llvm_type(c, elem_type);

        emit_vector_bounds_check(c, target_res.reg, index_res.reg, struct_ty, node.pos);

        let data_field_ptr: String = next_reg(c);
        c.output_file.write(c.indent + data_field_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + target_res.reg + ", i32 0, i32 2\n");
        
        let data_ptr: String = next_reg(c);
        c.output_file.write(c.indent + data_ptr + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_field_ptr + "\n");

        let slot_ptr: String = next_reg(c);
        
        let size_index: String = emit_int_to_size(c, index_res.reg, true);
        c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", " + get_size_llvm_type() + " " + size_index + "\n");
        
        let val_reg: String = next_reg(c);
        c.output_file.write(c.indent + val_reg + " = load " + elem_ty_str + ", " + elem_ty_str + "* " + slot_ptr + "\n");
        
        return CompileResult(reg=val_reg, type=elem_type, is_const_access=target_res.is_const_access);
    }

    throw_type_error(node.pos, "Type " + get_type_name(c, target_res.type) + " is not indexable.");
    return void_result();
}

func compile_index_assign(c: Compiler, node: IndexAssignNode) -> CompileResult {
    if (reject_const_write(c, node.target, node.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }
    check_out_index(c, node.target, node.index_node, node.pos);
    let target_res: CompileResult = compile_node(c, node.target);
    if (has_result(target_res) && target_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

    let s_info: StructInfo = c.struct_id_map.lookup("" + target_res.type);
    if (has_struct(s_info) && s_info.is_class) {
        let has_put: Bool = false;
        let v_len: Int = 0; if (s_info.vtable is !null) { v_len = s_info.vtable.length(); }
        let m_idx: Int = 0;
        while (m_idx < v_len) {
            let m: FuncInfo = s_info.vtable[m_idx];
            if (m.base_name == "put") { has_put = true; break; }
            m_idx += 1;
        }

        if has_put {
            let fake_args: Vector(ArgNode) = [];
            fake_args.append(ArgNode(val=node.index_node, name=null));
            fake_args.append(ArgNode(val=node.value, name=null));
            let fake_call: CallNode = CallNode(type=NODE_CALL, callee=NO_NODE, args=fake_args, type_args=null, pos=node.pos, preserve_fallible=false);
            compile_class_method_call(c, s_info, target_res, "put", fake_call);
            return void_result();
        }
    }

    let old_exp: Int = c.expected_type;
    c.expected_type = TYPE_INT;
    let index_res: CompileResult = compile_node(c, node.index_node);
    c.expected_type = old_exp;
    if (has_result(index_res) && index_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    
    if (index_res.type != TYPE_INT) {
        throw_type_error(node.pos, "Index must be an Integer.");
        return void_result();
    }

    if (is_pointer_type(c, target_res.type)) {
        let base_info: SymbolInfo = c.ptr_base_map.lookup("" + target_res.type);
        if (has_symbol(base_info)) {
            let elem_type: Int = base_info.type;
            
            if (elem_type == TYPE_VOID) {
                throw_type_error(node.pos, "Cannot index 'ptr Void'. Cast it to a specific pointer type first.");
                return void_result();
            }
            emit_pointer_null_check(c, target_res.reg, target_res.type, node.pos);

            c.expected_type = elem_type;
            let val_res: CompileResult = compile_node(c, node.value);
            c.expected_type = 0;
            if (has_result(val_res) && val_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
            
            val_res = emit_implicit_cast(c, val_res, elem_type, node.pos);
            
            let elem_ty_str: String = get_llvm_type_str(c, elem_type);
            let addr_reg: String = next_reg(c);
            c.output_file.write(c.indent + addr_reg + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + target_res.reg + ", i32 " + index_res.reg + "\n");
            
            if (result_owns_value(c, elem_type)) {
                if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, elem_type); }
                emit_drop_slot(c, addr_reg, elem_type);
            }
            
            c.output_file.write(c.indent + "store " + elem_ty_str + " " + val_res.reg + ", " + elem_ty_str + "* " + addr_reg + "\n");
            return val_res;
        }
    }

    // array / slice assignment
    let arr_info: ArrayInfo = c.array_info_map.lookup("" + target_res.type);
    if (has_array_info(arr_info)) {
        let elem_type: Int = arr_info.base_type;
        let elem_ty_str: String = get_llvm_type_str(c, elem_type);

        c.expected_type = elem_type;
        let val_res: CompileResult = compile_node(c, node.value);
        c.expected_type = 0;
        if (has_result(val_res) && val_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
        
        val_res = emit_implicit_cast(c, val_res, elem_type, node.pos);

        let curr_len: String = "";
        let data_ptr: String = "";
        if (arr_info.size == -1) {
            let parts: SliceParts = emit_slice_parts(c, target_res.reg, target_res.type, node.pos);
            curr_len = emit_size_to_int(c, parts.length);
            data_ptr = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + parts.data + ", " + get_size_llvm_type() + " " + parts.start + "\n");
        } else {
            curr_len = "" + arr_info.size;
            data_ptr = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + target_res.reg + ", i32 0, i32 0\n");
        }

        emit_array_bounds_check(c, index_res.reg, curr_len, node.pos);

        let ptr_reg: String = next_reg(c);
        c.output_file.write(c.indent + ptr_reg + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", i32 " + index_res.reg + "\n");
        
        if (result_owns_value(c, elem_type)) {
            if (!val_res.owns_ref) { emit_retain_value(c, val_res.reg, elem_type); }
            emit_drop_slot(c, ptr_reg, elem_type);
        }
        
        c.output_file.write(c.indent + "store " + elem_ty_str + " " + val_res.reg + ", " + elem_ty_str + "* " + ptr_reg + "\n");
        return val_res;
    }
    
    let is_vec: Bool = false;
    if (target_res.type >= 100) {
        if (has_symbol(c.vector_base_map.lookup("" + target_res.type))) {
            is_vec = true;
        }
    }

    if (target_res.type == TYPE_STRING) {
        let is_magic_func: Bool = false;
        if (has_func(c.curr_func)) {
            if (c.curr_func.base_name == "string_slice") {
                is_magic_func = true;
            }
        }

        if is_magic_func {
            let val_res: CompileResult = compile_node(c, node.value);

            // extract i8* buffer from %struct.$String*
            let src_struct_buf: String = next_reg(c);
            let src_buf: String = next_reg(c);
            c.output_file.write(c.indent + src_struct_buf + " = getelementptr inbounds %struct.$String, %struct.$String* " + target_res.reg + ", i32 0, i32 0\n");
            c.output_file.write(c.indent + src_buf + " = load i8*, i8** " + src_struct_buf + "\n");

            let ptr_reg: String = next_reg(c);
            c.output_file.write(c.indent + ptr_reg + " = getelementptr inbounds i8, i8* " + src_buf + ", i32 " + index_res.reg + "\n");
            val_res = emit_implicit_cast(c, val_res, TYPE_BYTE, node.pos);
            c.output_file.write(c.indent + "store i8 " + val_res.reg + ", i8* " + ptr_reg + "\n");
            return val_res;
        }

        throw_type_error(node.pos, "Strings are immutable. Cannot assign to index.");

        return void_result();
    }

    if is_vec {
        let v_info: SymbolInfo = c.vector_base_map.lookup("" + target_res.type);
        let elem_type: Int = v_info.type;
        let elem_ty_str: String = get_llvm_type_str(c, elem_type);

        c.expected_type = elem_type;
        let val_res: CompileResult = compile_node(c, node.value);
        c.expected_type = 0;
        
        val_res = emit_implicit_cast(c, val_res, elem_type, node.pos);
        let struct_ty: String = get_vector_llvm_type(c, elem_type);

        emit_vector_bounds_check(c, target_res.reg, index_res.reg, struct_ty, node.pos);

        let data_field_ptr: String = next_reg(c);
        c.output_file.write(c.indent + data_field_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + target_res.reg + ", i32 0, i32 2\n");
        let data_ptr: String = next_reg(c);
        c.output_file.write(c.indent + data_ptr + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_field_ptr + "\n");
        
        let size_index: String = emit_int_to_size(c, index_res.reg, true);
        let slot_ptr: String = next_reg(c);
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

func compile_slice_access(c: Compiler, node: SliceAccessNode, shared: Bool) -> CompileResult {
    if ((!has_node(node.start_idx) && has_node(node.end_idx)) ||
        (has_node(node.start_idx) && !has_node(node.end_idx))) {
        throw_invalid_syntax(node.pos, "Slice bounds must either both be present or both be omitted.");
        return void_result();
    }

    let old_exp: Int = c.expected_type;
    c.expected_type = 0;
    let target_res: CompileResult = compile_node(c, node.target);
    c.expected_type = old_exp;
    if (has_result(target_res) && target_res.type == TYPE_POISON) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    let target_type: Int = get_repr_type(c, target_res.type);

    let omitted: Bool = !has_node(node.start_idx) && !has_node(node.end_idx);
    if (target_type == TYPE_STRING) {
        let len_slot: String = next_reg(c);
        c.output_file.write(c.indent + len_slot + " = getelementptr inbounds %struct.$String, %struct.$String* " + target_res.reg + ", i32 0, i32 1\n");
        let source_len: String = next_reg(c);
        c.output_file.write(c.indent + source_len + " = load i32, i32* " + len_slot + "\n");

        if shared {
            if (!omitted) {
                throw_type_error(node.pos, "String views currently require a full slice expression.");
                return void_result();
            }
            return target_res;
        }

        let start: String = "0";
        let end: String = source_len;
        if (!omitted) {
            c.expected_type = TYPE_INT;
            let start_res: CompileResult = compile_node(c, node.start_idx);
            let end_res: CompileResult = compile_node(c, node.end_idx);
            c.expected_type = old_exp;
            start = start_res.reg;
            end = end_res.reg;
        }
        emit_slice_bounds_check(c, start, end, source_len, node.pos);
        let slice_hook: String = get_mangled_symbol(c, "string_slice", node.pos);
        let result: String = next_reg(c);
        c.output_file.write(c.indent + result + " = call %struct.$String* @" + slice_hook + "(%struct.$String* " + target_res.reg + ", i32 " + start + ", i32 " + end + ")\n");
        emit_release_owned(c, target_res);
        let result_type: Int = TYPE_STRING;
        if (has_named_type(get_named_type(c, target_res.type))) { result_type = target_res.type; }
        return CompileResult(reg=result, type=result_type, owns_ref=true);
    }

    let elem_type: Int = 0;
    let source_data: String = "";
    let current_len: String = "";
    let source_kind: Int = 0;
    let source_parts: SliceParts = SliceParts();
    let vec_data_slot: String = "";
    let vec_size_slot: String = "";
    let vec_owner: String = "";

    let arr_info: ArrayInfo = c.array_info_map.lookup("" + target_type);
    let vec_info: SymbolInfo = c.vector_base_map.lookup("" + target_type);
    if (has_array_info(arr_info)) {
        elem_type = arr_info.base_type;
        let elem_ty: String = get_llvm_type_str(c, elem_type);
        if (arr_info.size == -1) {
            source_kind = 2;
            source_parts = emit_slice_parts(c, target_res.reg, target_type, node.pos);
            current_len = emit_size_to_int(c, source_parts.length);
            source_data = next_reg(c);
            c.output_file.write(c.indent + source_data + " = getelementptr inbounds " + elem_ty + ", " + elem_ty + "* " + source_parts.data + ", " + get_size_llvm_type() + " " + source_parts.start + "\n");
        } else {
            source_kind = 1;
            current_len = "" + arr_info.size;
            source_data = next_reg(c);
            c.output_file.write(c.indent + source_data + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + target_res.reg + ", i32 0, i32 0\n");
        }
    } else if (has_symbol(vec_info)) {
        source_kind = 3;
        elem_type = vec_info.type;
        let elem_ty: String = get_llvm_type_str(c, elem_type);
        let vec_ty: String = get_vector_llvm_type(c, elem_type);
        let size_ty: String = get_size_llvm_type();
        vec_size_slot = next_reg(c);
        c.output_file.write(c.indent + vec_size_slot + " = getelementptr inbounds " + vec_ty + ", " + vec_ty + "* " + target_res.reg + ", i32 0, i32 0\n");
        let vector_length: String = next_reg(c);
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

    let start: String = "0";
    let end: String = current_len;
    if (!omitted) {
        c.expected_type = TYPE_INT;
        let start_res: CompileResult = compile_node(c, node.start_idx);
        let end_res: CompileResult = compile_node(c, node.end_idx);
        c.expected_type = old_exp;
        start = start_res.reg;
        end = end_res.reg;
    }
    emit_slice_bounds_check(c, start, end, current_len, node.pos);

    let length: String = next_reg(c);
    c.output_file.write(c.indent + length + " = sub i32 " + end + ", " + start + "\n");
    if (!shared) {
        return emit_slice_copy(c, elem_type, source_data, start, length, node.pos);
    }

    if (source_kind == 1) {
        throw_type_error(node.pos, "Shared views over fixed stack storage cannot escape their scope yet. Convert the data to a 'Vector' or 'Array(T)' first.");
        return void_result();
    }

    let size_start: String = emit_int_to_size(c, start, false);
    let size_length: String = emit_int_to_size(c, length, false);
    if (source_kind == 2) {
        let absolute_start: String = next_reg(c);
        c.output_file.write(c.indent + absolute_start + " = add " + get_size_llvm_type() + " " + source_parts.start + ", " + size_start + "\n");
        return emit_make_slice(c, elem_type, source_parts.owner, source_parts.data_slot, source_parts.size_slot, absolute_start, size_length);
    }
    return emit_make_slice(c, elem_type, vec_owner, vec_data_slot, vec_size_slot, size_start, size_length);
}

func compile_map_lit(c: Compiler, node: MapLitNode) -> CompileResult {
    let pairs: Vector(MapPairNode) = node.pairs;
    let pair_count: Int = 0;
    if (pairs is !null) { pair_count = pairs.length(); }

    let cap: Int = pair_count * 2;
    if (cap < 8) { cap = 8; }

    let dict_info: StructInfo = c.struct_id_map.lookup("" + c.expected_type);
    if (!is_typed_dict(c, dict_info)) {
        dict_info = c.struct_table.lookup("Dict");
        if (!has_struct(dict_info)) { dict_info = c.struct_table.lookup("dict.Dict"); }
    }
    if (!has_struct(dict_info)) { throw_type_error(node.pos, "Compiler error: 'Dict' class not found in prelude."); }

    let init_args: Vector(ArgNode) = [];
    if (!is_typed_dict(c, dict_info)) {
        let cap_tok: Token = Token(type=TOK_INT, value="" + cap, line=node.pos.ln, col=node.pos.col);
        let cap_node: NodeID = add_int_node(c.arena, IntNode(type=NODE_INT, tok=cap_tok, pos=node.pos));
        init_args.append(ArgNode(val=cap_node, name=null));
    }
    let fake_init_call: CallNode = CallNode(type=NODE_CALL, callee=NO_NODE, args=init_args, type_args=null, pos=node.pos, preserve_fallible=false);

    let dict_res: CompileResult = compile_class_init(c, dict_info, fake_init_call);

    // dict.put(k, v)
    let i: Int = 0;
    while (i < pair_count) {
        let pair: MapPairNode = pairs[i];
        let put_args: Vector(ArgNode) = [];
        put_args.append(ArgNode(val=pair.key, name=null));
        put_args.append(ArgNode(val=pair.value, name=null));
        let fake_put_call: CallNode = CallNode(type=NODE_CALL, callee=NO_NODE, args=put_args, type_args=null, pos=node.pos, preserve_fallible=false);
        
        compile_class_method_call(c, dict_info, dict_res, "put", fake_put_call);
        i += 1;
    }

    return CompileResult(reg=dict_res.reg, type=dict_info.type_id, origin_type=0);
}

func compile_enum_def(c: Compiler, node: EnumDefNode) -> CompileResult {
    let raw_name: String = node.name_tok.value;
    let enum_name: String = c.current_package_prefix + raw_name;
    
    let type_info: StructInfo = c.struct_table.lookup(enum_name);
    let type_id: Int = type_info.type_id;
    let llvm_ty_str: String = "i32";

    let fields: Vector(EnumFieldNode) = node.fields;
    let len: Int = 0; if (fields is !null) { len = fields.length(); }
    let i: Int = 0;
    
    let current_val: Long = 0L;
    let member_names: Dict(String, StringConstant) = Dict();

    while (i < len) {
        let f_node: EnumFieldNode = fields[i];
        
        if (has_node(f_node.value)) {
            current_val = eval_const_long(c, f_node.value, f_node.pos);
        }
        
        let field_name: String = f_node.name_tok.value;
        if (member_names.contains_key(field_name)) {
            throw_name_error(f_node.pos, "Member '" + field_name + "' is already defined in " + enum_name);
            return void_result();
        }
        member_names.put(field_name, StringConstant(id=0, value=field_name));
        if (current_val < -2147483648L || current_val > 2147483647L) {
            throw_overflow_error(f_node.pos, "Value for '" + field_name + "' is outside the Int range");
            return void_result();
        }
        let global_name: String = "@" + enum_name + "." + field_name;
        
        c.output_file.write(global_name + " = global " + llvm_ty_str + " " + current_val + "\n");
        c.global_symbol_table.put(enum_name + "." + field_name, SymbolInfo(reg=global_name, type=type_id, origin_type=type_id, is_const=true));

        let offset_int: Int = string_to_int("" + current_val, f_node.pos);
        type_info.fields.append(FieldInfo(name=field_name, type=type_id, llvm_type="i32", offset=offset_int));
        
        current_val += 1L;
        i += 1;
    }
    
    return void_result();
}

func compile_try_unwrap(c: Compiler, node: TryUnwrapNode) -> CompileResult {
    let expr_base: Int = node_tag(node.expr);
    let expr_res: CompileResult = CompileResult();
    if (expr_base == NODE_INDEX_ACCESS) {
        let access: IndexAccessNode = get_index_access_node(c.arena, node.expr);
        expr_res = compile_index_access(c, access, true);
    } else {
        expr_res = compile_node(c, node.expr);
    }

    let fallible_type: Int = expr_res.type;
    if (!is_fallible_type(c, fallible_type)) {
        if (expr_base == NODE_CALL) {
            let call: CallNode = get_call_node(c.arena, node.expr);
            let callee_base: Int = node_tag(call.callee);
            if (callee_base == NODE_VAR_ACCESS) {
                let callee: VarAccessNode = get_var_access_node(c.arena, call.callee);
                let target_type: Int = get_cast_target(c, callee.name_tok.value);
                if (target_type != 0) {
                    throw_invalid_syntax(node.pos, "Conversion to " + get_type_name(c, target_type) + " cannot fail; remove '?'");
                    return void_result();
                }
            }
        }
        throw_invalid_syntax(node.pos, "Cannot use '?' on a non-fallible type.");
        return void_result();
    }
    
    let inner_type: Int = get_inner_fallible_type(c, fallible_type);
    let fallible_llvm_ty: String = get_llvm_type_str(c, fallible_type);
    
    let is_err_reg: String = next_reg(c);
    c.output_file.write(c.indent + is_err_reg + " = extractvalue " + fallible_llvm_ty + " " + expr_res.reg + ", 0\n");
    
    let success_label: String = next_label(c);
    let fail_label: String = next_label(c);
    
    c.output_file.write(c.indent + "br i1 " + is_err_reg + ", label %" + fail_label + ", label %" + success_label + "\n\n");
    c.output_file.write(fail_label + ":\n");
    
    let err_val_reg: String = next_reg(c);
    c.output_file.write(c.indent + err_val_reg + " = extractvalue " + fallible_llvm_ty + " " + expr_res.reg + ", 1\n");
    
    if (c.current_catch_label is !null && c.current_catch_label != "") {
        c.output_file.write(c.indent + "store { i64, i32 } " + err_val_reg + ", { i64, i32 }* " + c.current_catch_err_ptr + "\n");
        c.output_file.write(c.indent + "br label %" + c.current_catch_label + "\n\n");
    } else {
        if (!is_fallible_type(c, c.current_ret_type)) {
            throw_invalid_syntax(node.pos, "Cannot use '?' without catch in a function that does not return a fallible type.");
        }
        let cur_ret_llvm_ty: String = get_llvm_type_str(c, c.current_ret_type);
        let ret_val_1: String = next_reg(c);
        c.output_file.write(c.indent + ret_val_1 + " = insertvalue " + cur_ret_llvm_ty + " undef, i1 true, 0\n");
        let ret_val_2: String = next_reg(c);
        c.output_file.write(c.indent + ret_val_2 + " = insertvalue " + cur_ret_llvm_ty + " " + ret_val_1 + ", { i64, i32 } " + err_val_reg + ", 1\n");
        
        cleanup_all_scopes(c);
        
        c.output_file.write(c.indent + "ret " + cur_ret_llvm_ty + " " + ret_val_2 + "\n\n");
    }
    
    c.output_file.write(success_label + ":\n");
    
    if (inner_type != TYPE_VOID) {
        let inner_val_reg: String = next_reg(c);
        c.output_file.write(c.indent + inner_val_reg + " = extractvalue " + fallible_llvm_ty + " " + expr_res.reg + ", 2\n");
        let inner_owned: Bool = expr_res.owns_ref && needs_drop(c, inner_type);
        return CompileResult(reg=inner_val_reg, type=inner_type, origin_type=0, owns_ref=inner_owned);
    } else {
        return void_result();
    }
}

func compile_catch(c: Compiler, node: CatchNode) -> CompileResult {
    let fail_label: String = next_label(c);
    let success_label: String = next_label(c);
    
    let err_reg_ptr: String = c.alloc_regs[node.alloc_id];
    
    let old_catch_label: String = c.current_catch_label;
    let old_err_ptr: String = c.current_catch_err_ptr;
    let old_catch_scope: Scope = c.current_catch_scope;
    
    c.current_catch_label = fail_label;
    c.current_catch_err_ptr = err_reg_ptr;
    c.current_catch_scope = c.symbol_table;
    
    let res: CompileResult = compile_node(c, node.stmt);
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

func compile_throw(c: Compiler, node: ThrowNode) -> CompileResult {
    let res: CompileResult = compile_node(c, node.value);
    if (!has_result(res) || res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

    let error_type: Int = res.type;
    if (!is_error_type(c, error_type) && is_error_type(c, res.origin_type)) {
        error_type = res.origin_type;
    }
    if (!is_error_type(c, error_type)) {
        throw_type_error(node.pos, "Cannot throw " + get_type_name(c, res.type) + ", expected an error value");
        return void_result();
    }

    let error_value: CompileResult = emit_error_value(c, res, node.pos);
    let err_val_reg: String = error_value.reg;
    
    if (c.current_catch_label is !null && c.current_catch_label != "") {
        cleanup_scopes_until(c, c.current_catch_scope);
        c.output_file.write(c.indent + "store { i64, i32 } " + err_val_reg + ", { i64, i32 }* " + c.current_catch_err_ptr + "\n");
        c.output_file.write(c.indent + "br label %" + c.current_catch_label + "\n\n");
    } else {
        if (!is_fallible_type(c, c.current_ret_type)) {
            throw_invalid_syntax(node.pos, "Cannot use 'throw' without a catch block in a function that does not return a fallible type.");
            return void_result();
        }
        
        let target_ty: String = get_llvm_type_str(c, c.current_ret_type);
        let ret_val_1: String = next_reg(c);
        c.output_file.write(c.indent + ret_val_1 + " = insertvalue " + target_ty + " undef, i1 true, 0\n");
        let ret_val_2: String = next_reg(c);
        c.output_file.write(c.indent + ret_val_2 + " = insertvalue " + target_ty + " " + ret_val_1 + ", { i64, i32 } " + err_val_reg + ", 1\n");
        
        cleanup_all_scopes(c);
        c.output_file.write(c.indent + "ret " + target_ty + " " + ret_val_2 + "\n\n");
    }
    
    return void_result();
}

func compile_lvalue_ptr(c: Compiler, node: NodeID, pos: Position) -> CompileResult {
    if (!has_node(node)) { return CompileResult(); }
    let base: Int = node_tag(node);

    if (base == NODE_VAR_ACCESS) {
        let v: VarAccessNode = get_var_access_node(c.arena, node);
        let name: String = v.name_tok.value;

        let info: SymbolInfo = find_symbol(c, name);
        if (has_symbol(info)) {
            if (info.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
            return CompileResult(reg=info.reg, type=info.type, origin_type=info.origin_type);
        }

        let f_info: FuncInfo = c.func_table.lookup(name);
        if (!has_func(f_info) && c.current_package_prefix != "") {
            f_info = c.func_table.lookup(c.current_package_prefix + name);
        }
        if (has_func(f_info)) {
            if (!validate_callable_value(f_info, 0, pos, "Function")) {
                return CompileResult(reg="poison", type=TYPE_POISON);
            }

            let specific_type_id: Int = get_func_type_id(c, f_info.arg_types, f_info.ret_type, f_info.variadic_param, callable_arg_names(f_info, 0));
            let sig: String = get_func_sig_str(c, f_info);
            let func_ptr: String = "@" + f_info.name;
            let cast_reg: String = next_reg(c);
            c.output_file.write(c.indent + cast_reg + " = bitcast " + sig + " " + func_ptr + " to i8*\n");

            let clo_payload: String = emit_alloc_closure(c, specific_type_id);
            let clo_func_ptr: String = next_reg(c);
            c.output_file.write(c.indent + clo_func_ptr + " = bitcast i8* " + clo_payload + " to i8**\n");
            c.output_file.write(c.indent + "store i8* " + cast_reg + ", i8** " + clo_func_ptr + "\n");
            let clo_env_ptr_i8: String = next_reg(c);
            c.output_file.write(c.indent + clo_env_ptr_i8 + " = getelementptr inbounds i8, i8* " + clo_payload + ", i32 " + closure_env_offset() + "\n");
            let clo_env_ptr: String = next_reg(c);
            c.output_file.write(c.indent + clo_env_ptr + " = bitcast i8* " + clo_env_ptr_i8 + " to i8**\n");
            c.output_file.write(c.indent + "store i8* null, i8** " + clo_env_ptr + "\n");
            return CompileResult(reg=clo_payload, type=specific_type_id);
        }
        
        throw_name_error(v.pos, "Unknown variable or function '" + name + "'.");
        let curr_scope: Scope = c.symbol_table;
        curr_scope.table.put(name, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    if (base == NODE_INDEX_ACCESS) {
        let ia: IndexAccessNode = get_index_access_node(c.arena, node);
        check_out_index(c, ia.target, ia.index_node, ia.pos);
        let target_res: CompileResult = compile_node(c, ia.target);
        
        let s_info: StructInfo = c.struct_id_map.lookup("" + target_res.type);
        if (has_struct(s_info) && s_info.is_class) {
            throw_invalid_syntax(ia.pos, "Cannot take ref of overloaded class index access.");
            return CompileResult();
        }

        let index_res: CompileResult = compile_node(c, ia.index_node);
        if (index_res.type != TYPE_INT) {
            throw_type_error(ia.pos, "Index must be an Integer.");
            return CompileResult();
        }

        if (is_pointer_type(c, target_res.type)) {
            let base_info: SymbolInfo = c.ptr_base_map.lookup("" + target_res.type);
            if (has_symbol(base_info)) {
                let elem_type: Int = base_info.type;
                if (elem_type == TYPE_VOID) {
                    throw_type_error(ia.pos, "Cannot index 'ptr Void'.");
                    return CompileResult();
                }
                emit_pointer_null_check(c, target_res.reg, target_res.type, ia.pos);
                let elem_ty_str: String = get_llvm_type_str(c, elem_type);
                let addr_reg: String = next_reg(c);
                c.output_file.write(c.indent + addr_reg + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + target_res.reg + ", i32 " + index_res.reg + "\n");
                return CompileResult(reg=addr_reg, type=elem_type, origin_type=elem_type);
            }
        }

        let arr_info: ArrayInfo = c.array_info_map.lookup("" + target_res.type);
        if (has_array_info(arr_info)) {
            let elem_type: Int = arr_info.base_type;
            let elem_ty_str: String = get_llvm_type_str(c, elem_type);
            let curr_len: String = "";
            let data_ptr: String = "";
            if (arr_info.size == -1) {
                let parts: SliceParts = emit_slice_parts(c, target_res.reg, target_res.type, ia.pos);
                curr_len = emit_size_to_int(c, parts.length);
                data_ptr = next_reg(c);
                c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + parts.data + ", " + get_size_llvm_type() + " " + parts.start + "\n");
            } else {
                curr_len = "" + arr_info.size;
                data_ptr = next_reg(c);
                c.output_file.write(c.indent + data_ptr + " = getelementptr inbounds " + arr_info.llvm_name + ", " + arr_info.llvm_name + "* " + target_res.reg + ", i32 0, i32 0\n");
            }
            emit_array_bounds_check(c, index_res.reg, curr_len, ia.pos);
            let ptr_reg: String = next_reg(c);
            c.output_file.write(c.indent + ptr_reg + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", i32 " + index_res.reg + "\n");
            return CompileResult(reg=ptr_reg, type=elem_type, origin_type=elem_type);
        }

        if (target_res.type >= 100 && has_symbol(c.vector_base_map.lookup("" + target_res.type))) {
            let v_info: SymbolInfo = c.vector_base_map.lookup("" + target_res.type);
            let elem_type: Int = v_info.type;
            let elem_ty_str: String = get_llvm_type_str(c, elem_type);
            let struct_ty: String = get_vector_llvm_type(c, elem_type);
            emit_vector_bounds_check(c, target_res.reg, index_res.reg, struct_ty, ia.pos);
            
            let data_field_ptr: String = next_reg(c);
            c.output_file.write(c.indent + data_field_ptr + " = getelementptr inbounds " + struct_ty + ", " + struct_ty + "* " + target_res.reg + ", i32 0, i32 2\n");
            let data_ptr: String = next_reg(c);
            c.output_file.write(c.indent + data_ptr + " = load " + elem_ty_str + "*, " + elem_ty_str + "** " + data_field_ptr + "\n");
            
            let size_index: String = emit_int_to_size(c, index_res.reg, true);
            let slot_ptr: String = next_reg(c);
            c.output_file.write(c.indent + slot_ptr + " = getelementptr inbounds " + elem_ty_str + ", " + elem_ty_str + "* " + data_ptr + ", " + get_size_llvm_type() + " " + size_index + "\n");
            return CompileResult(reg=slot_ptr, type=elem_type, origin_type=elem_type);
        }
        
        throw_type_error(ia.pos, "Type does not support l-value indexing.");
        return CompileResult();
    }

    if (base == NODE_FIELD_ACCESS) {
        let f_acc: FieldAccessNode = get_field_access_node(c.arena, node);
        let obj_type: Int = get_repr_type(c, get_expr_type(c, f_acc.obj));
        let struct_type_id: Int = obj_type;
        let struct_ptr_reg: String = "";
        let obj_res: CompileResult = CompileResult();

        if (is_pointer_type(c, struct_type_id)) {
            let base_info: SymbolInfo = c.ptr_base_map.lookup("" + struct_type_id);
            if (has_symbol(base_info)) {
                obj_res = compile_node(c, f_acc.obj);
                struct_ptr_reg = obj_res.reg;
                emit_pointer_null_check(c, struct_ptr_reg, struct_type_id, f_acc.pos);
                struct_type_id = base_info.type;
            }
        } else {
            let info: StructInfo = c.struct_id_map.lookup("" + struct_type_id);
            if (has_struct(info) && info.is_class) {
                obj_res = compile_node(c, f_acc.obj);
                struct_ptr_reg = obj_res.reg;
            } else {
                let obj_lvalue: CompileResult = compile_lvalue_ptr(c, f_acc.obj, f_acc.pos);
                if (!has_result(obj_lvalue) || obj_lvalue.type == TYPE_POISON) { return obj_lvalue; }
                struct_type_id = get_repr_type(c, obj_lvalue.type);
                struct_ptr_reg = obj_lvalue.reg;
            }
        }

        if ((struct_type_id == TYPE_GENERIC_STRUCT || struct_type_id == TYPE_GENERIC_CLASS) && obj_res.origin_type >= 100) {
            struct_type_id = obj_res.origin_type;
            let s_info_temp: StructInfo = c.struct_id_map.lookup("" + struct_type_id);
            if (has_struct(s_info_temp)) {
                let cast_reg: String = next_reg(c);
                c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + struct_ptr_reg + " to " + s_info_temp.llvm_name + "*\n");
                struct_ptr_reg = cast_reg;
            }
        }

        let s_info: StructInfo = c.struct_id_map.lookup("" + struct_type_id);
        if (!has_struct(s_info)) {
            throw_type_error(f_acc.pos, "Cannot access field on non-struct type.");
            return CompileResult();
        }

        if (f_acc.field_name.starts_with("__")) {
            let class_prefix: String = "";
            let dot_idx: Int = s_info.name.length() - 1;
            while (dot_idx >= 0) {
                if (s_info.name[dot_idx] == '.') {
                    class_prefix = s_info.name.slice(0, dot_idx + 1);
                    break;
                }
                dot_idx -= 1;
            }
            if (c.current_package_prefix != class_prefix) {
                throw_name_error(f_acc.pos, "Member '" + f_acc.field_name + "' is private to '" + s_info.name + "'.");
                return CompileResult();
            }
        }

        let field: FieldInfo = find_field(s_info, f_acc.field_name);
        if (!has_field(field)) {
            if (s_info.is_class) {
                let vtable_vec: Vector(Struct) = s_info.vtable;
                let v_len: Int = 0; if (vtable_vec is !null) { v_len = vtable_vec.length(); }
                let m_idx: Int = 0;
                let m_info: FuncInfo = FuncInfo();
                while (m_idx < v_len) {
                    let m: FuncInfo = vtable_vec[m_idx];
                    if (m.base_name == f_acc.field_name) {
                        m_info = m;
                        break;
                    }
                    m_idx += 1;
                }
                
                if (has_func(m_info)) {
                    let bound_args: Vector(Struct) = [];
                    let ba_idx: Int = 1;
                    while (ba_idx < m_info.arg_types.length()) {
                        bound_args.append(m_info.arg_types[ba_idx]);
                        ba_idx += 1;
                    }

                    if (!validate_callable_value(m_info, 1, f_acc.pos, "Method")) {
                        return CompileResult(reg="poison", type=TYPE_POISON);
                    }

                    let specific_type_id: Int = get_method_type_id(c, bound_args, m_info.ret_type, m_info.variadic_param, callable_arg_names(m_info, 1));
                    let sig: String = get_func_sig_str(c, m_info);
                    
                    let vtable_ptr_addr: String = next_reg(c);
                    c.output_file.write(c.indent + vtable_ptr_addr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + struct_ptr_reg + ", i32 0, i32 0\n");
                    let vtable_ptr: String = next_reg(c);
                    c.output_file.write(c.indent + vtable_ptr + " = load " + class_vtable_type(c, s_info) + "*, " + class_vtable_type(c, s_info) + "** " + vtable_ptr_addr + "\n");
                    
                    let method_i8ptr_addr: String = next_reg(c);
                    c.output_file.write(c.indent + method_i8ptr_addr + " = getelementptr inbounds " + class_vtable_type(c, s_info) + ", " + class_vtable_type(c, s_info) + "* " + vtable_ptr + ", i32 0, i32 " + m_idx + "\n");
                    let method_i8ptr: String = next_reg(c);
                    c.output_file.write(c.indent + method_i8ptr + " = load i8*, i8** " + method_i8ptr_addr + "\n");
                    
                    let cast_reg: String = next_reg(c);
                    c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + method_i8ptr + " to i8*\n");

                    let clo_payload: String = emit_alloc_closure(c, specific_type_id);
                    let clo_func_ptr: String = next_reg(c);
                    c.output_file.write(c.indent + clo_func_ptr + " = bitcast i8* " + clo_payload + " to i8**\n");
                    c.output_file.write(c.indent + "store i8* " + cast_reg + ", i8** " + clo_func_ptr + "\n");
                    
                    let clo_env_ptr_i8: String = next_reg(c);
                    c.output_file.write(c.indent + clo_env_ptr_i8 + " = getelementptr inbounds i8, i8* " + clo_payload + ", i32 " + closure_env_offset() + "\n");
                    let clo_env_ptr: String = next_reg(c);
                    c.output_file.write(c.indent + clo_env_ptr + " = bitcast i8* " + clo_env_ptr_i8 + " to i8**\n");
                    
                    let env_cast: String = next_reg(c);
                    c.output_file.write(c.indent + env_cast + " = bitcast " + s_info.llvm_name + "* " + struct_ptr_reg + " to i8*\n");
                    c.output_file.write(c.indent + "store i8* " + env_cast + ", i8** " + clo_env_ptr + "\n");
                    return CompileResult(reg=clo_payload, type=specific_type_id, origin_type=specific_type_id);
                }
            }
            throw_name_error(f_acc.pos, "Field '" + f_acc.field_name + "' not found.");
            return CompileResult();
        }

        let f_ptr: String = next_reg(c);
        c.output_file.write(c.indent + f_ptr + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + struct_ptr_reg + ", i32 0, i32 " + field.offset + "\n");
        return CompileResult(reg=f_ptr, type=field.type, origin_type=field.type);
    }

    if (base == NODE_DEREF) {
        let d_node: DerefNode = get_deref_node(c.arena, node);
        let res: CompileResult = compile_node(c, d_node.node);
        if (!has_result(res) || res.type == TYPE_POISON || res.reg == "") {
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        let i: Int = 0;
        let curr_reg: String = res.reg;
        let curr_type: Int = res.type;

        while (i < d_node.level - 1) { 
            if (curr_type == TYPE_NULL) {
                throw_null_dereference_error(d_node.pos, "Cannot dereference 'nullptr'.");
                return CompileResult();
            }
            let base_info: SymbolInfo = c.ptr_base_map.lookup("" + curr_type);
            if (!has_symbol(base_info)) {
                throw_type_error(d_node.pos, "Attempt to dereference non-pointer."); 
                return CompileResult();
            }
            let next_type: Int = base_info.type;
            if (next_type == TYPE_VOID) {
                throw_type_error(d_node.pos, "Cannot dereference 'ptr Void'.");
                return CompileResult();
            }
            emit_pointer_null_check(c, curr_reg, curr_type, d_node.pos);
            let ty_str: String = get_llvm_type_str(c, next_type);
            let next_reg: String = next_reg(c);
            c.output_file.write(c.indent + next_reg + " = load " + ty_str + ", " + ty_str + "* " + curr_reg + "\n");
            
            curr_reg = next_reg;
            curr_type = next_type;
            i += 1;
        }
        
        let base_info: SymbolInfo = c.ptr_base_map.lookup("" + curr_type);
        if (!has_symbol(base_info)) {
            throw_type_error(d_node.pos, "Attempt to take ref of non-pointer deref.");
            return CompileResult();
        }
        return CompileResult(reg=curr_reg, type=base_info.type, origin_type=base_info.type);
    }

    throw_invalid_syntax(pos, "Cannot take ref of r-value.");
    return CompileResult();
}

func compile_type_layout(c: Compiler, node: TypeLayoutNode) -> CompileResult {
    let type_id: Int = resolve_type(c, node.type_node);
    if (!check_layout_type(c, type_id, node.is_align, node.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }

    let llvm_type: String = get_llvm_type_str(c, type_id);
    let size_ty: String = get_size_llvm_type();
    let value: String = "";
    if (node.is_align) {
        let pair_type: String = "{ i8, " + llvm_type + " }";
        value = "ptrtoint (" + llvm_type + "* getelementptr (" + pair_type + ", " + pair_type + "* null, i32 0, i32 1) to " + size_ty + ")";
    } else {
        value = "ptrtoint (" + llvm_type + "* getelementptr (" + llvm_type + ", " + llvm_type + "* null, i32 1) to " + size_ty + ")";
    }
    return CompileResult(reg=value, type=TYPE_UINTSIZE);
}

func ordering_ordinal(c: Compiler, name: String, pos: Position) -> Int {
    let ordering: StructInfo = c.struct_table.lookup("comparison.Ordering");
    let field: FieldInfo = find_field(ordering, name);
    if (!has_struct(ordering) || !has_field(field)) {
        throw_internal_compiler_error(pos, "Ordering." + name + " is unavailable while lowering a comparison.");
        return 0;
    }
    return field.offset;
}

func compile_protocol_comparison(c: Compiler, left: CompileResult, right: CompileResult, op_type: Int, pos: Position) -> CompileResult {
    if (left.type != right.type || left.type < 100) { return CompileResult(); }
    let info: StructInfo = c.struct_id_map.lookup("" + left.type);
    if (!has_struct(info) || !info.is_class) { return CompileResult(); }

    let method_name: String = "equals";
    let protocol_name: String = "comparison.Equal";
    let ordered: Bool = op_type == TOK_LT || op_type == TOK_GT || op_type == TOK_LTE || op_type == TOK_GTE;
    if ordered {
        method_name = "compare";
        protocol_name = "comparison.Comparable";
    }
    if (!class_has_named_interface(c, info, protocol_name)) { return CompileResult(); }

    let method_index: Int = 0;
    let method_info: FuncInfo = FuncInfo();
    while (info.vtable is !null && method_index < info.vtable.length()) {
        let candidate: FuncInfo = info.vtable[method_index];
        if (candidate.base_name == method_name) {
            method_info = candidate;
            break;
        }
        method_index += 1;
    }
    if (!has_func(method_info) || method_info.arg_types is null || method_info.arg_types.length() != 2) {
        throw_internal_compiler_error(pos, "Protocol method '" + method_name + "' is missing from '" + info.name + "'.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    queue_generic_class_method(c, info, method_name);
    emit_method_nullcheck(c, left.reg, info.llvm_name, method_name, pos);

    let vptr_addr: String = next_reg(c);
    c.output_file.write(c.indent + vptr_addr + " = getelementptr inbounds " + info.llvm_name + ", " + info.llvm_name + "* " + left.reg + ", i32 0, i32 0\n");

    let vtable_raw: String = next_reg(c);
    c.output_file.write(c.indent + vtable_raw + " = load i8*, i8** " + vptr_addr + "\n");

    let vtable: String = next_reg(c);
    c.output_file.write(c.indent + vtable + " = bitcast i8* " + vtable_raw + " to " + class_vtable_type(c, info) + "*\n");

    let slot: String = next_reg(c);
    c.output_file.write(c.indent + slot + " = getelementptr inbounds " + class_vtable_type(c, info) + ", " + class_vtable_type(c, info) + "* " + vtable + ", i32 0, i32 " + method_index + "\n");

    let method_raw: String = next_reg(c);
    c.output_file.write(c.indent + method_raw + " = load i8*, i8** " + slot + "\n");

    let method_ptr: String = next_reg(c);
    c.output_file.write(c.indent + method_ptr + " = bitcast i8* " + method_raw + " to " + get_func_sig_str(c, method_info) + "\n");

    let call_result: String = next_reg(c);
    let return_llvm: String = get_llvm_type_str(c, method_info.ret_type);
    c.output_file.write(c.indent + call_result + " = call " + return_llvm + " " + method_ptr + "(" + info.llvm_name + "* " + left.reg + ", " + info.llvm_name + "* " + right.reg + ")\n");

    emit_release_owned(c, left);
    emit_release_owned(c, right);

    if (!ordered) {
        if (op_type == TOK_EE) { return CompileResult(reg=call_result, type=TYPE_BOOL); }
        let inverted: String = next_reg(c);
        c.output_file.write(c.indent + inverted + " = xor i1 " + call_result + ", true\n");
        return CompileResult(reg=inverted, type=TYPE_BOOL);
    }

    let result: String = next_reg(c);
    let predicate: String = "eq";
    let ordinal: Int = ordering_ordinal(c, "Less", pos);
    if (op_type == TOK_GT) {
        ordinal = ordering_ordinal(c, "Greater", pos);
    }
    else if (op_type == TOK_LTE) {
        predicate = "ne";
        ordinal = ordering_ordinal(c, "Greater", pos);
    }
    else if (op_type == TOK_GTE) {
        predicate = "ne";
    }

    c.output_file.write(c.indent + result + " = icmp " + predicate + " i32 " + call_result + ", " + ordinal + "\n");
    return CompileResult(reg=result, type=TYPE_BOOL);
}

func compile_binop(c: Compiler, node: BinOpNode) -> CompileResult {
    let left: CompileResult = compile_node(c, node.left);
    if (has_result(left) && left.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let op_type: Int = node.op_tok.type; 

    if (op_type == TOK_AND || op_type == TOK_OR) {
        let logic_type: Int = left.type;
        let logic_repr: Int = get_repr_type(c, logic_type);
        if (logic_repr != TYPE_BOOL) {
            throw_type_error(node.pos, "Logic operators '&&' and '||' require Bool operands. ");
            return void_result();
        }
        left.type = logic_repr;
        let label_rhs: String = "logic_rhs_" + c.type_counter;
        let label_merge: String = "logic_merge_" + c.type_counter;
        let label_left: String = "logic_left_" + c.type_counter;
        c.type_counter += 1;

        c.output_file.write(c.indent + "br label %" + label_left + "\n");
        c.output_file.write("\n" + label_left + ":\n");

        if (op_type == TOK_AND) {
            c.output_file.write(c.indent + "br i1 " + left.reg + ", label %" + label_rhs + ", label %" + label_merge + "\n");
        } else {
            c.output_file.write(c.indent + "br i1 " + left.reg + ", label %" + label_merge + ", label %" + label_rhs + "\n");
        }

        c.output_file.write("\n" + label_rhs + ":\n");
        let right_res: CompileResult = compile_node(c, node.right);
        if (right_res.type != logic_type) { throw_type_error(node.pos, "Both logic operands must have type " + get_type_name(c, logic_type) + "."); }
        right_res.type = get_repr_type(c, right_res.type);
        
        let label_rhs_end: String = "logic_rhs_end_" + c.type_counter;
        c.type_counter += 1;
        c.output_file.write(c.indent + "br label %" + label_rhs_end + "\n");
        c.output_file.write("\n" + label_rhs_end + ":\n");
        c.output_file.write(c.indent + "br label %" + label_merge + "\n");

        c.output_file.write("\n" + label_merge + ":\n");
        let final_reg: String = next_reg(c);
        c.output_file.write(c.indent + final_reg + " = phi i1 [ " + left.reg + ", %" + label_left + " ], [ " + right_res.reg + ", %" + label_rhs_end + " ]\n");
        
        return CompileResult(reg=final_reg, type=logic_type);
    }

    let right: CompileResult = compile_node(c, node.right);
    if (has_result(right) && right.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
    let named_result: Int = 0;
    let left_named: NamedTypeInfo = get_named_type(c, left.type);
    let right_named: NamedTypeInfo = get_named_type(c, right.type);
    if (has_named_type(left_named) || has_named_type(right_named)) {
        if (left.type != right.type) {
            throw_type_error(node.pos, "Cannot mix " + get_type_name(c, left.type) + " and " + get_type_name(c, right.type) + " without an explicit conversion.");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        named_result = left.type;
        left.type = get_repr_type(c, left.type);
        right.type = get_repr_type(c, right.type);
    }
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
            let other_type: Int = right.type;
            if (left.type != TYPE_ANY_ERROR) { other_type = left.type; }
            throw_type_error(node.pos, "Cannot compare an error value with " + get_type_name(c, other_type));
            return void_result();
        }

        left = emit_error_value(c, left, node.pos);
        right = emit_error_value(c, right, node.pos);

        let left_domain: String = next_reg(c);
        let right_domain: String = next_reg(c);
        let left_code: String = next_reg(c);
        let right_code: String = next_reg(c);
        c.output_file.write(c.indent + left_domain + " = extractvalue { i64, i32 } " + left.reg + ", 0\n");
        c.output_file.write(c.indent + right_domain + " = extractvalue { i64, i32 } " + right.reg + ", 0\n");
        c.output_file.write(c.indent + left_code + " = extractvalue { i64, i32 } " + left.reg + ", 1\n");
        c.output_file.write(c.indent + right_code + " = extractvalue { i64, i32 } " + right.reg + ", 1\n");

        let domain_equal: String = next_reg(c);
        let code_equal: String = next_reg(c);
        let equal: String = next_reg(c);
        c.output_file.write(c.indent + domain_equal + " = icmp eq i64 " + left_domain + ", " + right_domain + "\n");
        c.output_file.write(c.indent + code_equal + " = icmp eq i32 " + left_code + ", " + right_code + "\n");
        c.output_file.write(c.indent + equal + " = and i1 " + domain_equal + ", " + code_equal + "\n");
        if (op_type == TOK_EE) {
            return CompileResult(reg=equal, type=TYPE_BOOL);
        }

        let not_equal: String = next_reg(c);
        c.output_file.write(c.indent + not_equal + " = xor i1 " + equal + ", true\n");
        return CompileResult(reg=not_equal, type=TYPE_BOOL);
    }

    if (op_type == TOK_EE || op_type == TOK_NE || op_type == TOK_LT || op_type == TOK_GT || op_type == TOK_LTE || op_type == TOK_GTE) {
        let protocol_result: CompileResult = compile_protocol_comparison(c, left, right, op_type, node.pos);
        if (has_result(protocol_result)) {
            return protocol_result;
        }
    }

    // string
    if (left.type == TYPE_STRING || right.type == TYPE_STRING) {
        if (op_type == TOK_PLUS) {
            let left_stringable: Bool = left.type == TYPE_STRING || left.type == TYPE_NULL || is_primitive_type(left.type);
            let right_stringable: Bool = right.type == TYPE_STRING || right.type == TYPE_NULL || is_primitive_type(right.type);
            if (!left_stringable || !right_stringable) {
                let invalid_type: Int = left.type; if left_stringable { invalid_type = right.type; }
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

            let concat_hook: String = get_mangled_symbol(c, "string_concat", node.pos);
            let new_str_ptr: String = next_reg(c);
            c.output_file.write(c.indent + new_str_ptr + " = call %struct.$String* @" + concat_hook + "(%struct.$String* " + left.reg + ", %struct.$String* " + right.reg + ")\n");
            emit_release_owned(c, left);
            emit_release_owned(c, right);
            let result_type: Int = TYPE_STRING;
            if (named_result != 0) { result_type = named_result; }
            return CompileResult(reg=new_str_ptr, type=result_type, owns_ref=true);
        }

        if (left.type != right.type) {
            throw_type_error(node.pos, "Cannot operate on String with other types.");
            return void_result();
        }


        let allowed: Bool = false;
        if (op_type == TOK_EE) { allowed = true; }
        if (op_type == TOK_NE) { allowed = true; }
        
        if (!allowed) {
            throw_type_error(node.pos, "Arithmetic operations on Strings are not supported (except +).");
            return void_result();
        }

        let compare_hook: String = get_mangled_symbol(c, "string_compare", node.pos);
        let cmp_val: String = next_reg(c);
        c.output_file.write(c.indent + cmp_val + " = call i32 @" + compare_hook + "(%struct.$String* " + left.reg + ", %struct.$String* " + right.reg + ")\n");
        emit_release_owned(c, left);
        emit_release_owned(c, right);

        let res_reg: String = next_reg(c);
        let op_code: String = "icmp eq";

        if (op_type == TOK_NE) { op_code = "icmp ne"; }

        c.output_file.write(c.indent + res_reg + " = " + op_code + " i32 " + cmp_val + ", 0\n");
        
        return CompileResult(reg=res_reg, type=TYPE_BOOL);
    }

    if (op_type == TOK_POW) {
        let left_numeric: Bool = is_integer_type(left.type) || left.type == TYPE_FLOAT || left.type == TYPE_FLOAT32;
        let right_numeric: Bool = is_integer_type(right.type) || right.type == TYPE_FLOAT || right.type == TYPE_FLOAT32;
        if (!left_numeric || !right_numeric) {
            throw_type_error(node.pos, "Operator '**' requires numeric operands");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        left = promote_to_float(c, left);
        right = promote_to_float(c, right);
        let res_reg: String = next_reg(c);
        let pow_hook: String = get_mangled_symbol(c, "float_pow", node.pos);
        c.output_file.write(c.indent + res_reg + " = call double @" + pow_hook + "(double " + left.reg + ", double " + right.reg + ")\n");
        return CompileResult(reg=res_reg, type=TYPE_FLOAT);
    }

    if ((left.type == TYPE_CHAR && right.type == TYPE_BYTE) ||
        (left.type == TYPE_BYTE && right.type == TYPE_CHAR)) {
        if (left.type == TYPE_BYTE) {
            let promoted: String = next_reg(c);
            c.output_file.write(c.indent + promoted + " = zext i8 " + left.reg + " to i32\n");
            left = CompileResult(reg=promoted, type=TYPE_CHAR, origin_type=TYPE_BYTE);
        }
        if (right.type == TYPE_BYTE) {
            let promoted: String = next_reg(c);
            c.output_file.write(c.indent + promoted + " = zext i8 " + right.reg + " to i32\n");
            right = CompileResult(reg=promoted, type=TYPE_CHAR, origin_type=TYPE_BYTE);
        }
    }

    if (left.type == TYPE_CHAR || right.type == TYPE_CHAR) {
        if (left.type != right.type) {
            throw_type_error(node.pos, "Cannot mix Char with other types in binary operations.");
            return void_result();
        }

        let is_char_cmp: Bool = false;
        if (op_type == TOK_EE || op_type == TOK_NE || op_type == TOK_LT || op_type == TOK_GT || op_type == TOK_LTE || op_type == TOK_GTE) {
            is_char_cmp = true;
        }
        
        if (!is_char_cmp) {
            throw_type_error(node.pos, "Char type only supports comparison operators (==, !=, <, >, <=, >=).");
            return void_result();
        }

        let op_code: String = "";
        if (op_type == TOK_EE) { op_code = "icmp eq"; }
        else if (op_type == TOK_NE) { op_code = "icmp ne"; }
        else if (op_type == TOK_GT) { op_code = "icmp ugt"; }
        else if (op_type == TOK_LT) { op_code = "icmp ult"; }
        else if (op_type == TOK_GTE) { op_code = "icmp uge"; }
        else if (op_type == TOK_LTE) { op_code = "icmp ule"; }

        let res_reg: String = next_reg(c);
        c.output_file.write(c.indent + res_reg + " = " + op_code + " i32 " + left.reg + ", " + right.reg + "\n");
        return CompileResult(reg=res_reg, type=TYPE_BOOL);
    }

    let is_cmp: Bool = false;
    if (op_type == TOK_EE) { is_cmp = true; }
    if (op_type == TOK_NE) { is_cmp = true; }
    if (op_type == TOK_GT) { is_cmp = true; }
    if (op_type == TOK_LT) { is_cmp = true; }
    if (op_type == TOK_GTE) { is_cmp = true; }
    if (op_type == TOK_LTE) { is_cmp = true; }

    if is_cmp {
        let is_enum_cmp: Bool = false;
        if (left.type >= 100 && left.type == right.type) {
            let s_info: StructInfo = c.struct_id_map.lookup("" + left.type);
            if (has_struct(s_info) && s_info.is_enum) {
                is_enum_cmp = true;
            }
        } else if (left.type == TYPE_GENERIC_ENUM && right.type == TYPE_GENERIC_ENUM) {
            is_enum_cmp = true;
        } else if (left.type == TYPE_GENERIC_ENUM && right.type >= 100) {
            let s_info: StructInfo = c.struct_id_map.lookup("" + right.type);
            if (has_struct(s_info) && s_info.is_enum) { is_enum_cmp = true; }
        } else if (right.type == TYPE_GENERIC_ENUM && left.type >= 100) {
            let s_info: StructInfo = c.struct_id_map.lookup("" + left.type);
            if (has_struct(s_info) && s_info.is_enum) { is_enum_cmp = true; }
        }
        
        if is_enum_cmp {
            if (op_type != TOK_EE && op_type != TOK_NE) {
                throw_type_error(node.pos, "Enum type only supports == and !=.");
                return void_result();
            }
            let res_reg: String = next_reg(c);
            let op_code: String = "icmp eq";
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
            let res_reg: String = next_reg(c);
            let op_code: String = "icmp eq";
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
        let safe_widening: Bool = false;
        if (is_signed_integer(left.type) && get_type_bitwidth(left.type) > get_type_bitwidth(right.type)) { safe_widening = true; }
        if (is_signed_integer(right.type) && get_type_bitwidth(right.type) > get_type_bitwidth(left.type)) { safe_widening = true; }
        if safe_widening {
        } else if (is_unsuffix_int_literal(c, node.left)) {
            left = compile_type_cast(c, left, right.type, node.pos);
        } else if (is_unsuffix_int_literal(c, node.right)) {
            right = compile_type_cast(c, right, left.type, node.pos);
        } else {
            throw_type_error(node.pos, "Cannot mix signed and unsigned integers without an explicit conversion");
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
    }

    let target_type: Int = left.type;
    if (left.type == TYPE_FLOAT || right.type == TYPE_FLOAT) {
        target_type = TYPE_FLOAT;
    } else if (left.type == TYPE_FLOAT32 || right.type == TYPE_FLOAT32) {
        target_type = TYPE_FLOAT32;
    } else if (is_integer_type(left.type) && is_integer_type(right.type)) {
        let l_bits: Int = get_type_bitwidth(left.type);
        let r_bits: Int = get_type_bitwidth(right.type);

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

    let type_str: String = get_llvm_type_str(c, target_type);
    let res_reg: String = next_reg(c);
    let op_code: String = "";

    if is_cmp {
        if (target_type == TYPE_FLOAT || target_type == TYPE_FLOAT32) {
            if (op_type == TOK_EE) { op_code = "fcmp oeq"; }
            else if (op_type == TOK_NE) { op_code = "fcmp une"; }
            else if (op_type == TOK_GT) { op_code = "fcmp ogt"; }
            else if (op_type == TOK_LT) { op_code = "fcmp olt"; }
            else if (op_type == TOK_GTE) { op_code = "fcmp oge"; }
            else if (op_type == TOK_LTE) { op_code = "fcmp ole"; }
        } else {
            let suffix: String = "s"; 
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
        let is_zero_reg: String = next_reg(c);
        if (target_type == TYPE_FLOAT || target_type == TYPE_FLOAT32) {
            c.output_file.write(c.indent + is_zero_reg + " = fcmp oeq " + type_str + " " + right.reg + ", 0.0\n");
        } else {
            c.output_file.write(c.indent + is_zero_reg + " = icmp eq " + type_str + " " + right.reg + ", 0\n");
        }
        let err_label: String = "div_zero_" + c.type_counter;
        let ok_label: String = "div_ok_" + c.type_counter;
        c.type_counter += 1;
        c.output_file.write(c.indent + "br i1 " + is_zero_reg + ", label %" + err_label + ", label %" + ok_label + "\n");
        c.output_file.write("\n" + err_label + ":\n");
        emit_runtime_error(c, node.pos, "Division by zero");
        c.output_file.write("\n" + ok_label + ":\n");

        if (is_signed_integer(target_type)) {
            let min_literal: String = get_signed_min_literal(target_type);
            if (min_literal.length() > 0) {
                let is_min: String = next_reg(c);
                c.output_file.write(c.indent + is_min + " = icmp eq " + type_str + " " + left.reg + ", " + min_literal + "\n");
                let is_negative_one: String = next_reg(c);
                c.output_file.write(c.indent + is_negative_one + " = icmp eq " + type_str + " " + right.reg + ", -1\n");
                let is_overflow: String = next_reg(c);
                c.output_file.write(c.indent + is_overflow + " = and i1 " + is_min + ", " + is_negative_one + "\n");

                let overflow_label: String = "div_overflow_" + c.type_counter;
                let arithmetic_label: String = "div_arithmetic_" + c.type_counter;
                c.type_counter += 1;
                c.output_file.write(c.indent + "br i1 " + is_overflow + ", label %" + overflow_label + ", label %" + arithmetic_label + "\n");
                c.output_file.write("\n" + overflow_label + ":\n");
                emit_runtime_error(c, node.pos, "Signed division overflow");
                c.output_file.write("\n" + arithmetic_label + ":\n");
            }
        }
    }


    if (op_type == TOK_LSHIFT || op_type == TOK_RSHIFT) {
        let shift_bits: Int = get_type_bitwidth(target_type);
        if (is_unsuffix_int_literal(c, node.right)) {
            let amount: Long = eval_const_long(c, node.right, node.pos);
            if (amount < 0L || amount >= Long(shift_bits)) {
                throw_overflow_error(node.pos, "Shift count must be between 0 and " + (shift_bits - 1));
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
        } else {
            let too_large: String = next_reg(c);
            let invalid: String = too_large;
            c.output_file.write(c.indent + too_large + " = icmp uge " + type_str + " " + right.reg + ", " + shift_bits + "\n");
            if (is_signed_integer(target_type)) {
                let negative: String = next_reg(c);
                let combined: String = next_reg(c);
                c.output_file.write(c.indent + negative + " = icmp slt " + type_str + " " + right.reg + ", 0\n");
                c.output_file.write(c.indent + combined + " = or i1 " + negative + ", " + too_large + "\n");
                invalid = combined;
            }
            let error_label: String = "shift_error_" + c.type_counter;
            let shift_label: String = "shift_ok_" + c.type_counter;
            c.type_counter += 1;
            c.output_file.write(c.indent + "br i1 " + invalid + ", label %" + error_label + ", label %" + shift_label + "\n");
            c.output_file.write("\n" + error_label + ":\n");
            emit_runtime_error(c, node.pos, "Invalid shift count");
            c.output_file.write("\n" + shift_label + ":\n");
        }
    }

    if ((target_type == TYPE_INT128 || target_type == TYPE_UINT128) && (op_type == TOK_DIV || op_type == TOK_MOD)) {
        let hook_name: String = "int128_div";
        if (target_type == TYPE_UINT128) { hook_name = "uint128_div"; }
        if (op_type == TOK_MOD) {
            hook_name = "int128_rem";
            if (target_type == TYPE_UINT128) { hook_name = "uint128_rem"; }
        }
        let arithmetic_hook: String = get_mangled_symbol(c, hook_name, node.pos);
        c.output_file.write(c.indent + res_reg + " = call i128 @" + arithmetic_hook + "(i128 " + left.reg + ", i128 " + right.reg + ")\n");
        let result_type: Int = target_type;
        if (named_result != 0) { result_type = named_result; }
        return CompileResult(reg=res_reg, type=result_type);
    }

    if ((target_type == TYPE_FLOAT || target_type == TYPE_FLOAT32) && op_type == TOK_MOD) {
        let left_reg: String = left.reg;
        let right_reg: String = right.reg;
        if (target_type == TYPE_FLOAT32) {
            let widened_left: String = next_reg(c);
            let widened_right: String = next_reg(c);
            c.output_file.write(c.indent + widened_left + " = fpext float " + left_reg + " to double\n");
            c.output_file.write(c.indent + widened_right + " = fpext float " + right_reg + " to double\n");
            left_reg = widened_left;
            right_reg = widened_right;
        }
        let mod_hook: String = get_mangled_symbol(c, "float_mod", node.pos);
        let mod_result: String = res_reg;
        if (target_type == TYPE_FLOAT32) { mod_result = next_reg(c); }
        c.output_file.write(c.indent + mod_result + " = call double @" + mod_hook + "(double " + left_reg + ", double " + right_reg + ")\n");
        if (target_type == TYPE_FLOAT32) { c.output_file.write(c.indent + res_reg + " = fptrunc double " + mod_result + " to float\n"); }
        let result_type: Int = target_type;
        if (named_result != 0) { result_type = named_result; }
        return CompileResult(reg=res_reg, type=result_type);
    }

    c.output_file.write(c.indent + res_reg + " = " + op_code + " " + type_str + " " + left.reg + ", " + right.reg + "\n");
    let result_type: Int = target_type;
    if (named_result != 0) { result_type = named_result; }
    return CompileResult(reg=res_reg, type=result_type);
}

func emit_function_value(c: Compiler, info: FuncInfo, pos: Position) -> CompileResult {
    if ((info.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
        throw_type_error(pos, "Compiler intrinsic '" + info.base_name + "' cannot be used as a function value.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    if (!validate_callable_value(info, 0, pos, "Function")) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let specific_type: Int = get_func_type_id(c, info.arg_types, info.ret_type, info.variadic_param, callable_arg_names(info, 0));
    let cast: String = next_reg(c);
    c.output_file.write(c.indent + cast + " = bitcast " + get_func_sig_str(c, info) + " @" + info.name + " to i8*\n");

    let closure: String = emit_alloc_closure(c, specific_type);
    let function_slot: String = next_reg(c);
    c.output_file.write(c.indent + function_slot + " = bitcast i8* " + closure + " to i8**\n");
    c.output_file.write(c.indent + "store i8* " + cast + ", i8** " + function_slot + "\n");

    let environment_bytes: String = next_reg(c);
    let environment_slot: String = next_reg(c);
    c.output_file.write(c.indent + environment_bytes + " = getelementptr inbounds i8, i8* " + closure + ", i32 " + closure_env_offset() + "\n");
    c.output_file.write(c.indent + environment_slot + " = bitcast i8* " + environment_bytes + " to i8**\n");
    c.output_file.write(c.indent + "store i8* null, i8** " + environment_slot + "\n");

    return CompileResult(reg=closure, type=specific_type, origin_type=info.ret_type);
}

func emit_generic_method_value(c: Compiler, generic: GenericTypeNode) -> CompileResult {
    let field_base: Int = node_tag(generic.base_type);
    if (field_base != NODE_FIELD_ACCESS) {
        throw_type_error(generic.pos, "A generic method instance must name a class method.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    let field: FieldAccessNode = get_field_access_node(c.arena, generic.base_type);
    let object: CompileResult = compile_node(c, field.obj);
    if (!has_result(object) || object.type == TYPE_POISON) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let info: StructInfo = c.struct_id_map.lookup("" + object.type);
    if (!has_struct(info) || !info.is_class) {
        throw_type_error(generic.pos, "Generic methods can only be bound from class values.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let template: GenericTemplate = c.generic_methods.lookup(info.name + "_" + field.field_name);
    if (!has_template(template)) {
        throw_name_error(generic.pos, "Generic method '" + field.field_name + "' is not defined in '" + info.name + "'.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let types: Vector(Struct) = resolve_generic_method_args(c, template, generic.type_args, null, generic.pos);
    if (types is null) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let method_info: FuncInfo = register_generic_method(c, template, info, types, generic.pos);
    if (!has_func(method_info)) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    if (object.is_const_access && method_info.mutates_self) {
        throw_type_error(generic.pos, "Cannot bind mutating method '" + field.field_name + "' through const value");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    if (!validate_callable_value(method_info, 1, generic.pos, "Method")) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    emit_method_nullcheck(c, object.reg, info.llvm_name, field.field_name, generic.pos);
    let args: Vector(Struct) = [];
    let i: Int = 1;
    while (i < method_info.arg_types.length()) {
        args.append(method_info.arg_types[i]);
        i++;
    }

    let method_type: Int = get_method_type_id(c, args, method_info.ret_type, method_info.variadic_param, callable_arg_names(method_info, 1));
    let closure: String = emit_alloc_closure(c, method_type);
    let cast: String = next_reg(c);
    c.output_file.write(c.indent + cast + " = bitcast " + get_func_sig_str(c, method_info) + " @" + method_info.name + " to i8*\n");

    let function_slot: String = next_reg(c);
    c.output_file.write(c.indent + function_slot + " = bitcast i8* " + closure + " to i8**\n");
    c.output_file.write(c.indent + "store i8* " + cast + ", i8** " + function_slot + "\n");

    let environment_bytes: String = next_reg(c);
    let environment_slot: String = next_reg(c);
    c.output_file.write(c.indent + environment_bytes + " = getelementptr inbounds i8, i8* " + closure + ", i32 " + closure_env_offset() + "\n");
    c.output_file.write(c.indent + environment_slot + " = bitcast i8* " + environment_bytes + " to i8**\n");

    let object_bytes: String = next_reg(c);
    c.output_file.write(c.indent + object_bytes + " = bitcast " + info.llvm_name + "* " + object.reg + " to i8*\n");
    c.output_file.write(c.indent + "store i8* " + object_bytes + ", i8** " + environment_slot + "\n");

    emit_retain(c, object.reg, object.type);

    return CompileResult(reg=closure, type=method_type, origin_type=method_info.ret_type);
}

func compile_generic_value(c: Compiler, node: GenericTypeNode) -> CompileResult {
    let base: Int = node_tag(node.base_type);
    if (base == NODE_FIELD_ACCESS) {
        return emit_generic_method_value(c, node);
    }

    let name: String = generic_symbol_name(c, node.base_type, true);
    let template: GenericTemplate = c.generic_funcs.lookup(name);
    if (!has_template(template)) {
        throw_name_error(node.pos, "Generic function '" + name + "' is not defined.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let types: Vector(Struct) = resolve_generic_args(c, template, node.type_args, null, node.pos);
    if (types is null) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let instance: FuncInfo = register_generic_func(c, template, types, node.pos);
    if (!has_func(instance)) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    return emit_function_value(c, instance, node.pos);
}

func compile_builtin_protocol_call(c: Compiler, receiver: NodeID, receiver_type: Int, name: String, call: CallNode) -> CompileResult {
    let available: Bool = false;
    if (name == "equals" && has_builtin_equal(c, receiver_type)) {
        available = has_struct(c.struct_table.lookup("comparison.Equal"));
    } else if (name == "hash" && has_builtin_hash(c, receiver_type)) {
        available = has_struct(c.struct_table.lookup("hashing.Hash"));
    } else if (name == "compare" && has_builtin_order(c, receiver_type)) {
        available = has_struct(c.struct_table.lookup("comparison.Comparable"));
    } else if (name == "display" && has_builtin_display(c, receiver_type)) {
        available = has_struct(c.struct_table.lookup("formatting.Display"));
    }

    if (!available) { return CompileResult(); }

    let count: Int = 0;
    if (call.args is !null) {
        count = call.args.length();
    }

    let expected: Int = 0;
    if (name == "equals" || name == "compare") {
        expected = 1;
    }

    if (count != expected) {
        throw_type_error(call.pos, "Method '" + name + "' expects " + expected + " arguments, got " + count + ".");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    if (reject_named_args(call.args, call.pos, "protocol method '" + name + "'")) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    if (name == "equals") {
        let arg: ArgNode = call.args[0];
        let op: Token = Token(type=TOK_EE, value="==", line=call.pos.ln, col=call.pos.col);
        return compile_binop(c, BinOpNode(type=NODE_BINOP, left=receiver, op_tok=op, right=arg.val, pos=call.pos));
    }

    let value: CompileResult = compile_node(c, receiver);
    if (value.type == TYPE_POISON) { return value; }

    if (name == "display") {
        return convert_to_string(c, value);
    }

    if (name == "hash") {
        c.hash_types.put("" + receiver_type, StringConstant(id=receiver_type, value=""));

        let result: String = next_reg(c);
        c.output_file.write(c.indent + result + " = call i32 @__wl_hash_value_" + receiver_type + "(" + get_llvm_type_str(c, receiver_type) + " " + value.reg + ")\n");

        emit_release_owned(c, value);

        return CompileResult(reg=result, type=TYPE_INT);
    }

    let ordering: StructInfo = c.struct_table.lookup("comparison.Ordering");
    if (!has_struct(ordering)) {
        throw_internal_compiler_error(call.pos, "Ordering is unavailable while lowering Comparable.compare.");
        emit_release_owned(c, value);

        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let less_ordinal: Int = ordering_ordinal(c, "Less", call.pos);
    let equal_ordinal: Int = ordering_ordinal(c, "Equal", call.pos);
    let greater_ordinal: Int = ordering_ordinal(c, "Greater", call.pos);

    let arg: ArgNode = call.args[0];

    let other: CompileResult = emit_implicit_cast(c, compile_node(c, arg.val), receiver_type, call.pos);
    if (other.type == TYPE_POISON) {
        return other;
    }

    let comparison: String = "";
    if (receiver_type == TYPE_STRING) {
        let compare_hook: String = get_mangled_symbol(c, "string_compare", call.pos);

        comparison = next_reg(c);
        c.output_file.write(c.indent + comparison + " = call i32 @" + compare_hook + "(%struct.$String* " + value.reg + ", %struct.$String* " + other.reg + ")\n");
    } else {
        let llvm_type: String = get_llvm_type_str(c, receiver_type);
        let suffix: String = "s";
        if (is_unsigned_integer(receiver_type) || receiver_type == TYPE_CHAR) { suffix = "u"; }

        let less: String = next_reg(c);
        let greater: String = next_reg(c);
        let greater_value: String = next_reg(c);

        comparison = next_reg(c);

        c.output_file.write(c.indent + less + " = icmp " + suffix + "lt " + llvm_type + " " + value.reg + ", " + other.reg + "\n");
        c.output_file.write(c.indent + greater + " = icmp " + suffix + "gt " + llvm_type + " " + value.reg + ", " + other.reg + "\n");
        c.output_file.write(c.indent + greater_value + " = select i1 " + greater + ", i32 " + greater_ordinal + ", i32 " + equal_ordinal + "\n");
        c.output_file.write(c.indent + comparison + " = select i1 " + less + ", i32 " + less_ordinal + ", i32 " + greater_value + "\n");
    }

    emit_release_owned(c, value);
    emit_release_owned(c, other);

    return CompileResult(reg=comparison, type=ordering.type_id);
}

func compile_node(c: Compiler, node: NodeID) -> CompileResult {
    if (!has_node(node)) {
        return void_result();
    }

    let base: Int = node_tag(node);
    if (base == NODE_GENERIC_TYPE) { return compile_generic_value(c, get_generic_type_node(c.arena, node)); }
    if (base == NODE_TYPE_LAYOUT) { return compile_type_layout(c, get_type_layout_node(c.arena, node)); }
    if (base == NODE_TYPE_DECL) { return void_result(); }

    if (base == NODE_BLOCK) {
        return compile_block(c, get_block_node(c.arena, node));
    }

    if (base == NODE_STRING) {
        let n: StringNode = get_string_node(c.arena, node);
        let val: String = n.tok.value;
        let id: Int = register_string_constant(c, val);
        let len: Int = val.length() + 1;
        let res_reg: String = next_reg(c);

        c.output_file.write(c.indent + res_reg + " = getelementptr inbounds { i32, i32, %struct.$String }, { i32, i32, %struct.$String }* @.str." + id + ", i32 0, i32 2\n");
        
        return CompileResult(reg=res_reg, type=TYPE_STRING, origin_type=0);
    }

    if (base == NODE_VAR_DECL) { return compile_var_decl(c, get_var_decl_node(c.arena, node)); }
    if (base == NODE_IF)       { return compile_if(c, get_if_node(c.arena, node)); }
    if (base == NODE_WHILE)    { return compile_while(c, node); }
    if (base == NODE_FOR)      { return compile_for(c, node); }
    if (base == NODE_BINOP)    { return compile_binop(c, get_binop_node(c.arena, node)); }
    if (base == NODE_RETURN)   { return compile_return(c, get_return_node(c.arena, node)); }
    if (base == NODE_STRUCT_DEF) { return compile_struct_def(c, get_struct_def_node(c.arena, node)); }
    if (base == NODE_CLASS_DEF)  { return compile_class_def(c, get_class_def_node(c.arena, node)); }
    if (base == NODE_FIELD_ACCESS) { return compile_field_access(c, get_field_access_node(c.arena, node)); }
    if (base == NODE_FIELD_ASSIGN) { return compile_field_assign(c, get_field_assign_node(c.arena, node)); }
    if (base == NODE_EXTERN_BLOCK) { return compile_extern_block(c, get_extern_block_node(c.arena, node)); }
    if (base == NODE_VECTOR_LIT) { return compile_vector_lit(c, get_vector_lit_node(c.arena, node)); }
    if (base == NODE_INDEX_ACCESS) { return compile_index_access(c, get_index_access_node(c.arena, node), false); }
    if (base == NODE_INDEX_ASSIGN) { return compile_index_assign(c, get_index_assign_node(c.arena, node)); }
    if (base == NODE_SLICE_ACCESS) { return compile_slice_access(c, get_slice_access_node(c.arena, node), false); }
    if (base == NODE_MAP_LIT) { return compile_map_lit(c, get_map_lit_node(c.arena, node)); }
    if (base == NODE_ENUM_DEF) { return compile_enum_def(c, get_enum_def_node(c.arena, node)); }
    if (base == NODE_TRY_UNWRAP) { return compile_try_unwrap(c, get_try_unwrap_node(c.arena, node)); }
    if (base == NODE_CATCH) { return compile_catch(c, get_catch_node(c.arena, node)); }
    if (base == NODE_THROW) { return compile_throw(c, get_throw_node(c.arena, node)); }

    // function and closure
    if (base == NODE_FUNC_DEF) {
            let func_def: FunctionDefNode = get_func_def_node(c.arena, node);
            if (c.scope_depth == 0) {
                compile_func_def(c, func_def);
                return CompileResult();
            } else {
                let clo_res: CompileResult = compile_local_closure(c, func_def);
                let f_name: String = func_def.name_tok.value;

                if (f_name != "") {
                    let llvm_ty_str: String = get_llvm_type_str(c, clo_res.type);
                    let ptr_reg: String = next_reg(c);
                    
                    c.output_file.write(c.indent + ptr_reg + " = alloca " + llvm_ty_str + "\n");
                    c.output_file.write(c.indent + "store " + llvm_ty_str + " " + clo_res.reg + ", " + llvm_ty_str + "* " + ptr_reg + "\n");
                    
                    let curr_scope: Scope = c.symbol_table;
                    curr_scope.table.put(f_name, SymbolInfo(reg=ptr_reg, type=clo_res.type, origin_type=clo_res.origin_type, is_const=true));
                    curr_scope.gc_vars.append(GCTracker(reg=ptr_reg, type=clo_res.type));
                }

                return clo_res;
            }
        }

    // ptr
    if (base == NODE_PTR_ASSIGN) { return compile_ptr_assign(c, get_ptr_assign_node(c.arena, node)); }
    // ref
    if (base == NODE_REF) {
        let r_node: RefNode = get_ref_node(c.arena, node);

        if (reject_const_write(c, r_node.node, r_node.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }

        let ref_base: Int = node_tag(r_node.node);
        if (ref_base == NODE_SLICE_ACCESS) {
            let slice_node: SliceAccessNode = get_slice_access_node(c.arena, r_node.node);
            return compile_slice_access(c, slice_node, true);
        }

        let lval: CompileResult = compile_lvalue_ptr(c, r_node.node, r_node.pos);
        if (!has_result(lval)) { return void_result(); }

        let ptr_id: Int = get_ptr_type_id(c, lval.type);
        return CompileResult(reg=lval.reg, type=ptr_id);
    }
    // deref
    if (base == NODE_DEREF) {
        let d_node: DerefNode = get_deref_node(c.arena, node);
        let res: CompileResult = compile_node(c, d_node.node);
        if (!has_result(res) || res.type == TYPE_POISON || res.reg == "") {
            return CompileResult(reg="poison", type=TYPE_POISON);
        }

        let i: Int = 0;
        let curr_reg: String = res.reg;
        let curr_type: Int = res.type;
        
        while (i < d_node.level) {
            if (curr_type == TYPE_NULL) {
                throw_null_dereference_error(d_node.pos, "Cannot dereference 'nullptr'. ");
                return void_result();
            }
            let base_info: SymbolInfo = c.ptr_base_map.lookup("" + curr_type);
            if (!has_symbol(base_info)) {
                throw_type_error(d_node.pos, "Attempt to dereference non-pointer. ");
                return void_result();
            }
            
            let next_type: Int = base_info.type;
            if (next_type == TYPE_VOID) {
                throw_type_error(d_node.pos, "Cannot dereference 'ptr Void'. Cast it to a specific pointer type first.");
                return void_result();
            }
            emit_pointer_null_check(c, curr_reg, curr_type, d_node.pos);
            let ty_str: String = get_llvm_type_str(c, next_type);
            let next_reg: String = next_reg(c);
            
            c.output_file.write(c.indent + next_reg + " = load " + ty_str + ", " + ty_str + "* " + curr_reg + "\n");
            
            curr_reg = next_reg;
            curr_type = next_type;
            i += 1;
        }
        return CompileResult(reg=curr_reg, type=curr_type, is_const_access=res.is_const_access);
    }

    if (base == NODE_IMPORT) { 
        compile_import(c, get_import_node(c.arena, node));
        return void_result();
    }
    
    if (base == NODE_NULLPTR) {
        return CompileResult(reg="null", type=TYPE_NULLPTR);
    }

    if (base == NODE_NULL) {
        return CompileResult(reg="null", type=TYPE_NULL);
    }

    if (base == NODE_IS || base == NODE_IS_NOT) {
        let b_node: BinOpNode = get_binop_node(c.arena, node);
        let lhs_res: CompileResult = compile_node(c, b_node.left);
        let rhs_res: CompileResult = compile_node(c, b_node.right);

        let l_reg: String = lhs_res.reg;
        let r_reg: String = rhs_res.reg;

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
            let lhs_info: StructInfo = c.struct_id_map.lookup("" + lhs_res.type);
            if (has_struct(lhs_info) && lhs_info.is_interface) {
                let object_l: String = next_reg(c);
                c.output_file.write(c.indent + object_l + " = extractvalue { i8*, i8* } " + l_reg + ", 0\n");
                l_reg = object_l;
            } else {
                let cast_l: String = next_reg(c);
                let ty_l: String = get_llvm_type_str(c, lhs_res.type);
                c.output_file.write(c.indent + cast_l + " = bitcast " + ty_l + " " + l_reg + " to i8*\n");
                l_reg = cast_l;
            }
        }
        if (rhs_res.type != TYPE_NULL && rhs_res.type != TYPE_NULLPTR) {
            let rhs_info: StructInfo = c.struct_id_map.lookup("" + rhs_res.type);
            if (has_struct(rhs_info) && rhs_info.is_interface) {
                let object_r: String = next_reg(c);
                c.output_file.write(c.indent + object_r + " = extractvalue { i8*, i8* } " + r_reg + ", 0\n");
                r_reg = object_r;
            } else {
                let cast_r: String = next_reg(c);
                let ty_r: String = get_llvm_type_str(c, rhs_res.type);
                c.output_file.write(c.indent + cast_r + " = bitcast " + ty_r + " " + r_reg + " to i8*\n");
                r_reg = cast_r;
            }
        }

        let cmp_reg: String = next_reg(c);
        let cond: String = "eq";
        if (base == NODE_IS_NOT) { cond = "ne"; }
        
        c.output_file.write(c.indent + cmp_reg + " = icmp " + cond + " i8* " + l_reg + ", " + r_reg + "\n");
        return CompileResult(reg=cmp_reg, type=TYPE_BOOL);
    }

    if (base == NODE_INT) {
        let n: IntNode = get_int_node(c.arena, node);
        let raw_val: String = n.tok.value;
        let t_id: Int = c.expected_type;
        
        let is_i128: Bool = false;
        let suffix_len: Int = 0;
        
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
            let parsed_wide: UInt128 = parse_const_uint128(raw_val, n.pos);
            let bits: Int = get_type_bitwidth(t_id);
            let max_value: UInt128 = 340282366920938463463374607431768211455ULL;
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
            let actual_val: String = raw_val;
            if (suffix_len > 0) {
                actual_val = raw_val.slice(0, raw_val.length() - suffix_len);
            }
            let clean_val: String = "";
            let i: Int = 0;
            let act_len: Int = actual_val.length();
            while (i < act_len) {
                if (actual_val[i] != '_') {
                    clean_val = clean_val + actual_val.slice(i, i + 1);
                }
                i += 1;
            }
            return CompileResult(reg=clean_val, type=t_id); 
        }

        let parsed_val: Long = string_to_long(raw_val, n.pos);
        if (t_id == 0 || !is_integer_type(t_id)) {
            if (raw_val.ends_with("L") || raw_val.ends_with("l")) {
                t_id = TYPE_LONG;
            } else if (parsed_val < -2147483648L || parsed_val > 2147483647L) {
                t_id = TYPE_LONG;
            } else {
                t_id = TYPE_INT;
            }
        } else {
            let bits: Int = get_type_bitwidth(t_id); // Byte or Int8
            let is_overflow: Bool = false;

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
    if (base == NODE_CHAR) {
        let cn: CharNode = get_char_node(c.arena, node);
        let char_val: Int = string_to_int(cn.tok.value, cn.pos);
        return CompileResult(reg="" + char_val, type=TYPE_CHAR);
    }
    if (base == NODE_FLOAT) {
        let n: FloatNode = get_float_node(c.arena, node);
        let val_str: String = n.tok.value;
        let is_f32: Bool = false;
        
        if (val_str.ends_with("f") || val_str.ends_with("F")) {
            is_f32 = true;
            val_str = val_str.slice(0, val_str.length() - 1);
        }

        if (c.expected_type == TYPE_FLOAT32 || (c.expected_type == 0 && is_f32)) {
            let tmp_reg: String = next_reg(c);
            c.output_file.write(c.indent + tmp_reg + " = fptrunc double " + val_str + " to float\n");
            return CompileResult(reg=tmp_reg, type=TYPE_FLOAT32);
        }
        return CompileResult(reg=val_str, type=TYPE_FLOAT); 
    }

    if (base == NODE_BOOL) {
        let b: BooleanNode = get_bool_node(c.arena, node);
        let val_str: String = "0";
        if (b.value == 1) { val_str = "1"; }
        return CompileResult(reg=val_str, type=TYPE_BOOL);
    }

    if (base == NODE_VAR_ACCESS) {
        let v: VarAccessNode = get_var_access_node(c.arena, node);
        let var_name: String = v.name_tok.value; 
        
        let info: SymbolInfo = find_symbol(c, var_name);
        if (!has_symbol(info)) {
            let f_info: FuncInfo = c.func_table.lookup(var_name);
            if (!has_func(f_info) && c.current_package_prefix != "") {
                f_info = c.func_table.lookup(c.current_package_prefix + var_name);
                if (has_func(f_info)) { var_name = c.current_package_prefix + var_name; }
            }
            if (has_func(f_info)) {
                if ((f_info.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
                    throw_type_error(v.pos, "Compiler intrinsic '" + f_info.base_name + "' cannot be used as a function value.");
                    return CompileResult(reg="poison", type=TYPE_POISON);
                }
                if (!validate_callable_value(f_info, 0, v.pos, "Function")) {
                    return CompileResult(reg="poison", type=TYPE_POISON);
                }

                let specific_type_id: Int = get_func_type_id(c, f_info.arg_types, f_info.ret_type, f_info.variadic_param, callable_arg_names(f_info, 0));
                let sig: String = get_func_sig_str(c, f_info);
                let func_ptr: String = "@" + f_info.name;
                
                let cast_reg: String = next_reg(c);
                c.output_file.write(c.indent + cast_reg + " = bitcast " + sig + " " + func_ptr + " to i8*\n");
                let clo_payload: String = emit_alloc_closure(c, specific_type_id);
                let clo_func_ptr_i8: String = clo_payload;
                let clo_func_ptr: String = next_reg(c);
                c.output_file.write(c.indent + clo_func_ptr + " = bitcast i8* " + clo_func_ptr_i8 + " to i8**\n");
                c.output_file.write(c.indent + "store i8* " + cast_reg + ", i8** " + clo_func_ptr + "\n");
                let clo_env_ptr_i8: String = next_reg(c);
                c.output_file.write(c.indent + clo_env_ptr_i8 + " = getelementptr inbounds i8, i8* " + clo_payload + ", i32 " + closure_env_offset() + "\n");
                let clo_env_ptr: String = next_reg(c);
                c.output_file.write(c.indent + clo_env_ptr + " = bitcast i8* " + clo_env_ptr_i8 + " to i8**\n");
                c.output_file.write(c.indent + "store i8* null, i8** " + clo_env_ptr + "\n");

                return CompileResult(reg=clo_payload, type=specific_type_id);
            }

            throw_name_error(v.pos, "Undefined variable or function '" + var_name + "'. ");
            let curr_scope: Scope = c.symbol_table;
            curr_scope.table.put(var_name, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
            return CompileResult(reg="poison", type=TYPE_POISON);
        }
        
        if (info.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

        if (info.reg.starts_with("$intrinsic.")) { return emit_target_intrinsic(c, info); }

        let llvm_ty_str: String = get_llvm_type_str(c, info.type);
        if (llvm_ty_str == "") {
            throw_type_error(v.pos, "Variable '" + var_name + "' has invalid internal type ID. ");
            return void_result();
        }

        let arr_check: ArrayInfo = c.array_info_map.lookup("" + info.type);
        if (has_array_info(arr_check)) {
            if (arr_check.size != -1) {
                return CompileResult(reg=info.reg, type=info.type, origin_type=info.origin_type, is_const_access=info.is_const || info.is_const_access);
            }
        }
        
        let val_reg: String = next_reg(c);
        c.output_file.write(c.indent + val_reg + " = load " + llvm_ty_str + ", " + llvm_ty_str + "* " + info.reg + "\n");
        return CompileResult(reg=val_reg, type=info.type, origin_type=info.origin_type, is_const_access=info.is_const || info.is_const_access);
    }

    if (base == NODE_VAR_ASSIGN) {
        return compile_var_assign(c, get_var_assign_node(c.arena, node));
    }

    if (base == NODE_CALL) {
        let n_call: CallNode = get_call_node(c.arena, node);
        let callee_node: NodeID = n_call.callee;
        let callee: Int = node_tag(callee_node);
        if (callee == NODE_GENERIC_TYPE) {
            let generic_callee: GenericTypeNode = get_generic_type_node(c.arena, callee_node);
            callee_node = generic_callee.base_type;
            callee = node_tag(callee_node);
        }

        let func_name: String = "";
        let is_direct: Bool = false;
        let is_package_call: Bool = false;

        if (callee == NODE_FIELD_ACCESS) {
            let f_acc: FieldAccessNode = get_field_access_node(c.arena, callee_node);

            let obj_base_pre: Int = node_tag(f_acc.obj);
            if (obj_base_pre == NODE_SUPER) {
                let self_info: SymbolInfo = find_symbol(c, "self");
                if (!has_symbol(self_info)) { throw_invalid_syntax(n_call.pos, "Cannot use 'super' outside of a method."); }

                let curr_class: StructInfo = c.struct_id_map.lookup("" + self_info.type);
                if (!has_struct(curr_class) || !curr_class.is_class || curr_class.parent_id == 0) {
                    throw_type_error(n_call.pos, "Cannot use 'super', class has no parent.");
                    return void_result();
                }

                let p_info: StructInfo = c.struct_id_map.lookup("" + curr_class.parent_id);
                let target_m_name: String = f_acc.field_name;
                if (target_m_name == "init") { target_m_name = "$init"; }
                if (target_m_name == "deinit") { target_m_name = "$deinit"; }

                let full_m_name: String = c.current_package_prefix + p_info.name + "_" + target_m_name;
                let f_info: FuncInfo = c.func_table.lookup(full_m_name);
                if (!has_func(f_info)) {
                    throw_name_error(n_call.pos, "Method '" + target_m_name + "' not found in parent class '" + p_info.name + "'.");
                    return void_result();
                }

                let self_ty_str: String = get_llvm_type_str(c, self_info.type);
                let self_val_reg: String = next_reg(c);
                c.output_file.write(c.indent + self_val_reg + " = load " + self_ty_str + ", " + self_ty_str + "* " + self_info.reg + "\n");
                let self_res: CompileResult = CompileResult(reg=self_val_reg, type=self_info.type, origin_type=0);

                c.expected_type = curr_class.parent_id;
                let casted_self: CompileResult = emit_implicit_cast(c, self_res, curr_class.parent_id, n_call.pos);
                c.expected_type = 0;

                let sig: String = get_func_sig_str(c, f_info);
                let args_str: String = get_llvm_type_str(c, curr_class.parent_id) + " " + casted_self.reg;

                let args: Vector(ArgNode) = n_call.args;
                let a_len: Int = 0; if (args is !null) { a_len = args.length(); }
                let arg_idx: Int = 0;
                let owned_args: Vector(Struct) = [];
                let expected_types: Vector(Struct) = f_info.arg_types;
                
                let expected_arg_count: Int = 0;
                if (expected_types is !null) { expected_arg_count = expected_types.length() - 1; }
                
                let native_args: BoundCallArgs = bind_native_args(args, f_info, 1, n_call.pos);
                if (!has_bound_args(native_args)) { return CompileResult(reg="poison", type=TYPE_POISON); }
                args = native_args.ordered;
                a_len = expected_arg_count;

                while (arg_idx < a_len) {
                    if (f_info.variadic_param > 0 && arg_idx == f_info.variadic_param - 1) {
                        let pack_type: TypeListNode = expected_types[arg_idx + 1];
                        let pack_info: ArrayInfo = c.array_info_map.lookup("" + pack_type.type);
                        let pack: CompileResult = compile_variadic_pack(c, native_args.variadic, pack_info.base_type, n_call.pos);
                        if (pack.type == TYPE_POISON) { return pack; }
                        args_str += ", " + get_llvm_type_str(c, pack.type) + " " + pack.reg;
                        arg_idx += 1;
                        continue;
                    }
                    let arg_node_curr: ArgNode = args[arg_idx];
                    let expected_type_node: TypeListNode = expected_types[arg_idx + 1];
                    let expected_type: Int = expected_type_node.type;

                    c.expected_type = expected_type;
                    let arg_val: CompileResult = compile_node(c, arg_node_curr.val);
                    c.expected_type = 0;
                    if (has_result(arg_val) && arg_val.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
                    arg_val = emit_implicit_cast(c, arg_val, expected_type, n_call.pos);

                    let ty_str: String = get_llvm_type_str(c, arg_val.type);
                    args_str = args_str + ", " + ty_str + " " + arg_val.reg;
                    if (arg_val.owns_ref) { owned_args.append(arg_val); }

                    arg_idx += 1;
                }

                let llvm_ret_type: String = get_llvm_type_str(c, f_info.ret_type);
                if (f_info.ret_type == TYPE_VOID) {
                    c.output_file.write(c.indent + "call " + llvm_ret_type + " @" + f_info.name + "(" + args_str + ")\n");
                    emit_release_owned_args(c, owned_args);
                    return CompileResult(reg="", type=TYPE_VOID, origin_type=0);
                } else {
                    let call_res: String = next_reg(c);
                    c.output_file.write(c.indent + call_res + " = call " + llvm_ret_type + " @" + f_info.name + "(" + args_str + ")\n");
                    emit_release_owned_args(c, owned_args);
                    return CompileResult(reg=call_res, type=f_info.ret_type, origin_type=0, owns_ref=result_owns_value(c, f_info.ret_type));
                }
            }

            let is_module_path: Bool = true;
            let path_parts: Vector(String) = [];
            let curr_obj: NodeID = f_acc.obj;
            let curr_base: Int = node_tag(curr_obj);
            while (curr_base == NODE_FIELD_ACCESS) {
                let inner_f: FieldAccessNode = get_field_access_node(c.arena, curr_obj);
                path_parts.append(inner_f.field_name);
                curr_obj = inner_f.obj;
                curr_base = node_tag(curr_obj);
            }
            if (curr_base == NODE_VAR_ACCESS) {
                let inner_v: VarAccessNode = get_var_access_node(c.arena, curr_obj);
                let root_name: String = inner_v.name_tok.value;
                if (!has_symbol(find_symbol(c, root_name))) {
                    let module_prefix: String = c.current_file_visible_prefixes.lookup(root_name);
                    if (module_prefix is !null) {
                        func_name = module_member_name(module_prefix, path_parts, f_acc.field_name);
                        is_package_call = true;
                    } else {
                        let source_name: String = module_member_name(root_name + ".", path_parts, f_acc.field_name);
                        let mapped_func: String = c.current_file_func_aliases.lookup(source_name);
                        if (mapped_func is !null) {
                            func_name = mapped_func;
                            is_package_call = true;
                        }
                    }
                }
            }

            let try_string_method: Bool = false;
            let guessed_type: Int = get_repr_type(c, get_expr_type(c, f_acc.obj));
            if (!is_package_call) {
                let protocol_call: CompileResult = compile_builtin_protocol_call(c, f_acc.obj, guessed_type, f_acc.field_name, n_call);
                if (has_result(protocol_call)) { return protocol_call; }

                if (f_acc.field_name == "length") {
                    if (guessed_type == TYPE_STRING || has_symbol(c.vector_base_map.lookup("" + guessed_type)) || has_array_info(c.array_info_map.lookup("" + guessed_type))) {
                        return compile_length_method(c, f_acc.obj, n_call);
                    }
                }
                if (has_symbol(c.vector_base_map.lookup("" + guessed_type))) {
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
                let res: CompileResult = compile_string_method_call(c, f_acc.obj, f_acc.field_name, n_call);
                if (has_result(res)) { return res; }
            }

            if (!is_package_call && !try_string_method) {
                let obj_res: CompileResult = compile_node(c, f_acc.obj);
                if (has_result(obj_res) && obj_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
                let struct_type_id: Int = get_repr_type(c, obj_res.type);
                if (struct_type_id == TYPE_GENERIC_STRUCT && obj_res.origin_type >= 100) {
                    struct_type_id = obj_res.origin_type;
                }
                let s_info: StructInfo = c.struct_id_map.lookup("" + struct_type_id);
                if (has_struct(s_info) && (s_info.is_class || s_info.is_interface)) {
                    obj_res.type = struct_type_id;
                    return compile_class_method_call(c, s_info, obj_res, f_acc.field_name, n_call);
                }
            }
        }

        if (callee == NODE_VAR_ACCESS) {
            let v_node: VarAccessNode = get_var_access_node(c.arena, callee_node);
            func_name = v_node.name_tok.value;
        }

        let generic_type_name: String = generic_symbol_name(c, callee_node, false);
        let generic_type_template: GenericTemplate = c.generic_structs.lookup(generic_type_name);
        if (use_generic_constructor(c, generic_type_name, generic_type_template, n_call.type_args, n_call.args, c.expected_type)) {
            let types: Vector(Struct) = resolve_generic_constructor_args(c, generic_type_template, n_call.type_args, n_call.args, c.expected_type, n_call.pos);
            if (types is null) { return CompileResult(reg="poison", type=TYPE_POISON); }

            let template_base: Int = node_tag(generic_type_template.node);
            let instance_type: Int = 0;
            if (template_base == NODE_CLASS_DEF) {
                instance_type = register_generic_class(c, generic_type_template, types, n_call.pos);
            } else {
                instance_type = register_generic_struct(c, generic_type_template, types, n_call.pos);
            }

            let instance: StructInfo = c.struct_id_map.lookup("" + instance_type);
            if (template_base == NODE_CLASS_DEF) {
                return compile_class_init(c, instance, n_call);
            }

            return compile_struct_init(c, instance, n_call);
        }

        if (callee == NODE_VAR_ACCESS || callee == NODE_FIELD_ACCESS) {
            let generic_name: String = generic_symbol_name(c, callee_node, true);
            let template: GenericTemplate = c.generic_funcs.lookup(generic_name);
            if (has_template(template)) {
                let types: Vector(Struct) = resolve_generic_args(c, template, n_call.type_args, n_call.args, n_call.pos);
                if (types is null) { return CompileResult(reg="poison", type=TYPE_POISON); }

                let instance: FuncInfo = register_generic_func(c, template, types, n_call.pos);
                if (!has_func(instance)) { return CompileResult(reg="poison", type=TYPE_POISON); }

                func_name = generic_instance_name(template.name, types, c);
            }
        }

        if (func_name != "") {
            let type_alias: NamedTypeInfo = find_named_decl(c, func_name);
            if (has_named_type(type_alias) && type_alias.is_alias) {
                let aliased_info: StructInfo = c.struct_id_map.lookup("" + resolve_named_type(c, type_alias));
                if (has_struct(aliased_info)) {
                    func_name = aliased_info.name;
                }
            }
            let cast_target: Int = get_cast_target(c, func_name);
            let is_cast: Bool = cast_target != 0;

            if is_cast {
                let args: Vector(ArgNode) = n_call.args;
                let a_len: Int = 0; if (args is !null) { a_len = args.length(); }
                if (reject_named_args(args, n_call.pos, "a type conversion")) { return CompileResult(reg="poison", type=TYPE_POISON); }
                if (a_len != 1) {
                    throw_type_error(n_call.pos, "Type cast expects exactly 1 argument.");
                    return void_result();
                }
                let arg_curr: ArgNode = args[0];
                if (!validate_explicit_literal_cast(c, arg_curr.val, cast_target, n_call.pos)) {
                    return void_result();
                }
                let old_exp: Int = c.expected_type;
                c.expected_type = 0;
                let arg_base: Int = node_tag(arg_curr.val);
                if (arg_base == NODE_INT && is_integer_type(cast_target) &&
                    cast_target != TYPE_CHAR) {
                    c.expected_type = cast_target;
                }
                let val_res: CompileResult = compile_node(c, arg_curr.val);
                c.expected_type = old_exp;

                let source_info: StructInfo = c.struct_id_map.lookup("" + val_res.type);
                let conversion: FuncInfo = find_class_conversion(source_info, cast_target);
                if (has_func(conversion)) {
                    let no_args: Vector(ArgNode) = [];
                    let conversion_call: CallNode = CallNode(type=NODE_CALL, callee=NO_NODE, args=no_args, type_args=null, pos=n_call.pos, preserve_fallible=true);
                    let converted: CompileResult = compile_class_method_call(
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

                if (is_numeric_literal_expression(c, arg_curr.val)) {
                    return compile_type_cast(c, val_res, cast_target, n_call.pos);
                }
                return compile_explicit_type_cast(c, val_res, cast_target, n_call.pos, n_call.preserve_fallible);
            }

            if (!is_package_call) {
                let found_local: Bool = false;
                let local_name: String = func_name;
                if (c.current_package_prefix != "") {
                    local_name = c.current_package_prefix + func_name;
                }
                
                if (has_struct(c.struct_table.lookup(local_name)) || has_func(c.func_table.lookup(local_name))) {
                    func_name = local_name;
                    found_local = true;
                }

                if (!found_local) {
                    let mapped_type: String = c.current_file_type_aliases.lookup(func_name);
                    if (mapped_type is !null) {
                        func_name = mapped_type;
                    } else {
                        let mapped_func: String = c.current_file_func_aliases.lookup(func_name);
                        if (mapped_func is !null) {
                            func_name = mapped_func;
                        }
                    }
                }
            }
            if is_package_call {
                let f_acc: FieldAccessNode = get_field_access_node(c.arena, n_call.callee);
                if (f_acc.field_name.starts_with("__")) {
                    throw_name_error(n_call.pos, "Function '" + func_name + "' is not defined.");
                    return void_result();
                }
                is_direct = true;
            } else {
                let s_check: StructInfo = c.struct_table.lookup(func_name);
                if (has_struct(s_check)) {
                    is_direct = true;
                } else {
                    let f_check: FuncInfo = c.func_table.lookup(func_name);
                    let v_check: SymbolInfo = find_symbol(c, func_name);
                    if (has_func(f_check) && !has_symbol(v_check)) {
                        is_direct = true;
                    }
                }
            }
        }

        if is_direct {
            let g_alias_type: String = c.global_type_aliases.lookup(func_name);
            if (g_alias_type is !null) { func_name = g_alias_type; }

            let g_alias_func: String = c.global_func_aliases.lookup(func_name);
            if (g_alias_func is !null) { func_name = g_alias_func; }

            let target_func_name: String = func_name;
            let check_built: FuncInfo = c.func_table.lookup(func_name);
            if (has_func(check_built)) { target_func_name = check_built.base_name; }

            let is_print: Bool = has_func(check_built) && target_func_name == "print" &&
                                 (check_built.ann_flags & FLAG_ANN_INTRINSIC) != 0;
            if is_print {
                return compile_print_call(c, n_call);
            }

            let s_info: StructInfo = c.struct_table.lookup(func_name);
            if (has_struct(s_info)) {
                if (s_info.is_class) {
                    return compile_class_init(c, s_info, n_call);
                } else {
                    return compile_struct_init(c, s_info, n_call);
                }
            }

            let func_info: FuncInfo = c.func_table.lookup(func_name);

            if (!has_func(func_info)) {
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

            let args_str: String = "";
            let args: Vector(ArgNode) = n_call.args;
            let a_len: Int = 0;
            if (args is !null) { a_len = args.length(); }
            let arg_idx: Int = 0;
            let owned_args: Vector(Struct) = [];

            let arg_types: Vector(Struct) = func_info.arg_types;
            let type_len: Int = 0; 
            if (arg_types is !null) { type_len = arg_types.length(); }
            let native_args: BoundCallArgs = BoundCallArgs();
            if (!func_info.is_varargs) {
                native_args = bind_native_args(args, func_info, 0, n_call.pos);
                if (!has_bound_args(native_args)) { return CompileResult(reg="poison", type=TYPE_POISON); }
                args = native_args.ordered;
                a_len = type_len;
            } else if (reject_named_args(args, n_call.pos, "a variadic function")) {
                return CompileResult(reg="poison", type=TYPE_POISON);
            } else if (reject_spread_args(args, n_call.pos, "a C variadic function")) {
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            
            let is_first: Bool = true;
            
            while (arg_idx < a_len) {
                if (func_info.variadic_param > 0 && arg_idx == func_info.variadic_param - 1) {
                    let pack_type: TypeListNode = arg_types[arg_idx];
                    let pack_info: ArrayInfo = c.array_info_map.lookup("" + pack_type.type);
                    let pack: CompileResult = compile_variadic_pack(c, native_args.variadic, pack_info.base_type, n_call.pos);
                    if (pack.type == TYPE_POISON) { return pack; }
                    if (!is_first) { args_str += ", "; }
                    args_str += get_llvm_type_str(c, pack.type) + " " + pack.reg;
                    is_first = false;
                    arg_idx += 1;
                    continue;
                }
                let arg_node_curr: ArgNode = args[arg_idx];

                if (arg_idx >= type_len) { 
                    if (!func_info.is_varargs) {
                        throw_type_error(n_call.pos, "Too many arguments.");
                        return void_result();
                    }
                    let arg_val: CompileResult = compile_node(c, arg_node_curr.val);
                    if (has_result(arg_val) && arg_val.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }

                    if (arg_val.type >= 100) {
                        throw_type_error(n_call.pos, "Cannot pass complex types (Struct/Array/Vector) directly to C varargs functions.");
                        return void_result();
                    }

                    if (arg_val.type == TYPE_BYTE) {
                        arg_val = promote_to_int(c, arg_val);
                    }
                    if (arg_val.type == TYPE_BOOL) {
                        let zext_reg: String = next_reg(c);
                        c.output_file.write(c.indent + zext_reg + " = zext i1 " + arg_val.reg + " to i32\n");
                        arg_val = CompileResult(reg=zext_reg, type=TYPE_INT);
                    }
                    if (!is_first) { args_str = args_str + ", "; }
                    let ty_str: String = get_llvm_type_str(c, arg_val.type);
                    args_str += ty_str + " " + arg_val.reg;
                    if (arg_val.owns_ref) { owned_args.append(arg_val); }

                    is_first = false;
                    arg_idx += 1;
                    continue;
                }

                let type_node_curr: TypeListNode = arg_types[arg_idx];
                let expected_type: Int = type_node_curr.type;

                c.expected_type = expected_type;
                let arg_val: CompileResult = compile_node(c, arg_node_curr.val);
                c.expected_type = 0;
                if (has_result(arg_val) && arg_val.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
                
                arg_val = emit_implicit_cast(c, arg_val, expected_type, n_call.pos);

                let ty_str: String = get_llvm_type_str(c, arg_val.type);
                if (!is_first) { args_str = args_str + ", "; }
                args_str += ty_str + " " + arg_val.reg;
                is_first = false;
                if (arg_val.owns_ref) { owned_args.append(arg_val); }
                
                arg_idx += 1;
            }
            
            if (arg_idx < type_len) { throw_type_error(n_call.pos, "Too few arguments."); }

            let ret_type_str: String = get_llvm_type_str(c, func_info.ret_type);
            let call_res_reg: String = "";

            let abi_callconv: String = func_callconv(func_info);
            let call_prefix: String = abi_callconv + ret_type_str + " ";
            if (func_info.is_varargs) {
                let sig_args: String = "";
                let p_idx: Int = 0;
                let first_p: Bool = true;
                while (p_idx < type_len) {
                    let p_curr: TypeListNode = arg_types[p_idx];
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
                let returns_owned: Bool = result_owns_value(c, func_info.ret_type) &&
                                            (func_info.abi_name is null || func_info.abi_name.length() == 0);
                return CompileResult(reg=call_res_reg, type=func_info.ret_type, owns_ref=returns_owned);
            }
        }

        else {
            if (callee == NODE_VAR_ACCESS) {
                let v_node: VarAccessNode = get_var_access_node(c.arena, callee_node);
                let s_info: StructInfo = c.struct_table.lookup(v_node.name_tok.value);
                if (has_struct(s_info)) {
                    if (s_info.is_class) {
                        return compile_class_init(c, s_info, n_call);
                    } else {
                        return compile_struct_init(c, s_info, n_call);
                    }
                }
            }

            let callee_res: CompileResult = compile_node(c, callee_node);
            if (has_result(callee_res) && callee_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
            let ptr_type: Int = callee_res.type;

            let ret_type_id: Int = 0;
            let is_valid_call: Bool = false;

            if (ptr_type == TYPE_GENERIC_FUNCTION || ptr_type == TYPE_GENERIC_METHOD) {
                if (callee == NODE_VAR_ACCESS) {
                    let v_node: VarAccessNode = get_var_access_node(c.arena, callee_node);
                    let info: SymbolInfo = find_symbol(c, v_node.name_tok.value);
                    if (has_symbol(info) && info.origin_type >= 100) {
                        let f_ret_info: SymbolInfo = c.func_ret_map.lookup("" + info.origin_type);
                        if (has_symbol(f_ret_info)) {
                            ret_type_id = f_ret_info.type;
                            is_valid_call = true;
                        } else {
                            let m_ret_info: SymbolInfo = c.method_ret_map.lookup("" + info.origin_type);
                            if (has_symbol(m_ret_info)) {
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
                let f_ret_info: SymbolInfo = c.func_ret_map.lookup("" + ptr_type);
                if (has_symbol(f_ret_info)) {
                    ret_type_id = f_ret_info.type;
                    is_valid_call = true;
                } else {
                    let m_ret_info: SymbolInfo = c.method_ret_map.lookup("" + ptr_type);
                    if (has_symbol(m_ret_info)) {
                        ret_type_id = m_ret_info.type;
                        is_valid_call = true;
                    }
                }
            }

            if is_valid_call {
                if (!validate_fallible_call(c, ret_type_id, n_call.preserve_fallible, "", n_call.pos)) {
                    return CompileResult(reg="poison", type=TYPE_POISON);
                }
                let is_closure: Bool = false;
                let actual_env_reg: String = "";
                let raw_func_ptr: String = callee_res.reg;
                let is_func: Bool = ptr_type == TYPE_GENERIC_FUNCTION || has_symbol(c.func_ret_map.lookup("" + ptr_type));
                let is_meth: Bool = ptr_type == TYPE_GENERIC_METHOD || has_symbol(c.method_ret_map.lookup("" + ptr_type));
                if (is_func || is_meth) {
                    is_closure = true;
                    let env_ptr_i8_addr: String = next_reg(c);
                    c.output_file.write(c.indent + env_ptr_i8_addr + " = getelementptr inbounds i8, i8* " + callee_res.reg + ", i32 " + closure_env_offset() + "\n");
                    let env_ptr_addr: String = next_reg(c);
                    c.output_file.write(c.indent + env_ptr_addr + " = bitcast i8* " + env_ptr_i8_addr + " to i8**\n");
                    actual_env_reg = next_reg(c);
                    c.output_file.write(c.indent + actual_env_reg + " = load i8*, i8** " + env_ptr_addr + "\n");
                    let f_ptr_i8_addr: String = next_reg(c);
                    c.output_file.write(c.indent + f_ptr_i8_addr + " = getelementptr inbounds i8, i8* " + callee_res.reg + ", i32 0\n");
                    let f_ptr_addr: String = next_reg(c);
                    c.output_file.write(c.indent + f_ptr_addr + " = bitcast i8* " + f_ptr_i8_addr + " to i8**\n");
                    raw_func_ptr = next_reg(c);
                    c.output_file.write(c.indent + raw_func_ptr + " = load i8*, i8** " + f_ptr_addr + "\n");
                }

                let args: Vector(ArgNode) = n_call.args;
                let a_len: Int = 0; if (args is !null) { a_len = args.length(); }
                
                let expected_args: Vector(Struct) = null;
                let signature_info: SymbolInfo = SymbolInfo();
                let bound_args: BoundCallArgs = BoundCallArgs();
                if (ptr_type != TYPE_GENERIC_FUNCTION && ptr_type != TYPE_GENERIC_METHOD) {
                    signature_info = c.func_ret_map.lookup("" + ptr_type);
                    if (!has_symbol(signature_info)) { signature_info = c.method_ret_map.lookup("" + ptr_type); }
                    if (has_symbol(signature_info)) {
                        expected_args = signature_info.func_arg_types;
                        bound_args = bind_callable_args(args, signature_info, n_call.pos);
                        if (!has_bound_args(bound_args)) { return CompileResult(reg="poison", type=TYPE_POISON); }
                        args = bound_args.ordered;
                        a_len = expected_args.length();
                    }
                } else if (reject_named_args(args, n_call.pos, "a Function or Method value")) {
                    return CompileResult(reg="poison", type=TYPE_POISON);
                }

                let a_idx: Int = 0;

                let sig_g: String = "";
                let sig_c: String = "i8*";
                let args_g_str: String = "";
                let args_c_str: String = "i8* " + actual_env_reg;
                let first: Bool = true;
                let owned_args: Vector(Struct) = [];
                
                while (a_idx < a_len) {
                    if (has_symbol(signature_info) && signature_info.variadic_param > 0 && a_idx == signature_info.variadic_param - 1) {
                        let pack_type: TypeListNode = expected_args[a_idx];
                        let pack_info: ArrayInfo = c.array_info_map.lookup("" + pack_type.type);
                        let pack: CompileResult = compile_variadic_pack(c, bound_args.variadic, pack_info.base_type, n_call.pos);
                        if (pack.type == TYPE_POISON) { return pack; }

                        let pack_llvm: String = get_llvm_type_str(c, pack.type);
                        if (!first) {
                            sig_g += ", ";
                            args_g_str += ", ";
                            sig_c += ", ";
                            args_c_str += ", ";
                        } else {
                            sig_c += ", ";
                            args_c_str += ", ";
                        }
                        sig_g += pack_llvm;
                        args_g_str += pack_llvm + " " + pack.reg;
                        sig_c += pack_llvm;
                        args_c_str += pack_llvm + " " + pack.reg;
                        first = false;
                        a_idx += 1;
                        continue;
                    }
                    let curr_arg: ArgNode = args[a_idx];
                    let a_res: CompileResult = compile_node(c, curr_arg.val);
                    
                    if (expected_args is !null) {
                        let exp_arg_node: TypeListNode = expected_args[a_idx];
                        if (a_res.type != exp_arg_node.type && a_res.type != TYPE_POISON && exp_arg_node.type != TYPE_POISON && a_res.type != TYPE_ANYPTR) {
                            if (!is_subclass(c, a_res.type, exp_arg_node.type)) {
                                throw_type_error(n_call.pos, "Argument type mismatch in Function/Method call. Expected " + get_type_name(c, exp_arg_node.type) + ", got " + get_type_name(c, a_res.type));
                                return void_result();
                            }
                        }
                    }

                    let a_ty: String = get_llvm_type_str(c, a_res.type);

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

                let ret_ty_str: String = get_llvm_type_str(c, ret_type_id);

                if is_closure {
                    let is_env_null: String = next_reg(c);
                    c.output_file.write(c.indent + is_env_null + " = icmp eq i8* " + actual_env_reg + ", null\n");
                    
                    let l_global: String = "call_g_" + c.type_counter;
                    let l_closure: String = "call_c_" + c.type_counter;
                    let l_merge: String = "call_m_" + c.type_counter;
                    c.type_counter += 1;
                    
                    c.output_file.write(c.indent + "br i1 " + is_env_null + ", label %" + l_global + ", label %" + l_closure + "\n");

                    c.output_file.write("\n" + l_global + ":\n");
                    let cast_g: String = next_reg(c);
                    c.output_file.write("  " + cast_g + " = bitcast i8* " + raw_func_ptr + " to " + ret_ty_str + " (" + sig_g + ")*\n");
                    let res_g: String = "";
                    if (ret_type_id == TYPE_VOID) {
                        c.output_file.write("  call void " + cast_g + "(" + args_g_str + ")\n");
                    } else {
                        res_g = next_reg(c);
                        c.output_file.write("  " + res_g + " = call " + ret_ty_str + " " + cast_g + "(" + args_g_str + ")\n");
                    }
                    c.output_file.write("  br label %" + l_merge + "\n");

                    c.output_file.write("\n" + l_closure + ":\n");
                    let cast_c: String = next_reg(c);
                    c.output_file.write("  " + cast_c + " = bitcast i8* " + raw_func_ptr + " to " + ret_ty_str + " (" + sig_c + ")*\n");
                    let res_c: String = "";
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
                        let final_res: String = next_reg(c);
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

    if (base == NODE_BREAK) {
        let n_break: BreakNode = get_break_node(c.arena, node);
        if (c.loop_stack is null) {
            throw_invalid_syntax(n_break.pos, "'break' outside of loop. ");
            return void_result();
        }
        let scope: LoopScope = c.loop_stack;
        cleanup_scopes_until(c, scope.loop_scope);
        c.output_file.write(c.indent + "br label %" + scope.label_break + "\n");

        return void_result();
    }

    if (base == NODE_CONTINUE) {
        let n_cont: ContinueNode = get_continue_node(c.arena, node);
        if (c.loop_stack is null) {
            throw_invalid_syntax(n_cont.pos, "'continue' outside of loop. ");
            return void_result();
        }
        let scope: LoopScope = c.loop_stack;
        cleanup_scopes_until(c, scope.loop_scope);
        c.output_file.write(c.indent + "br label %" + scope.label_continue + "\n");

        return void_result();
    }

    if (base == NODE_POSTFIX) {
        let u: PostfixOpNode = get_postfix_node(c.arena, node);
        let op_type: Int = u.op_tok.type;

        let var_node: Int = node_tag(u.node);

        let target_reg: String = "";
        let target_type: Int = 0;
        let type_str: String = "";

        if (var_node == NODE_VAR_ACCESS) {
            let v_acc: VarAccessNode = get_var_access_node(c.arena, u.node);
            let var_name: String = v_acc.name_tok.value;

            let info: SymbolInfo = find_symbol(c, var_name);
            if (!has_symbol(info)) {
                throw_name_error(v_acc.pos, "Undefined variable '" + var_name + "'. "); 
                let curr_scope: Scope = c.symbol_table;
                curr_scope.table.put(var_name, SymbolInfo(reg="poison", type=TYPE_POISON, origin_type=TYPE_POISON, is_const=false));
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            if (info.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
            if (info.is_const) { throw_type_error(u.pos, "Cannot modify constant variable '" + var_name + "'."); }

            target_reg = info.reg;
            target_type = info.type;
            type_str = get_llvm_type_str(c, info.type);
            
        }
        else if (var_node == NODE_FIELD_ACCESS) {
            let f_acc: FieldAccessNode = get_field_access_node(c.arena, u.node);
            if (reject_const_write(c, f_acc.obj, u.pos)) { return CompileResult(reg="poison", type=TYPE_POISON); }
            let obj_res: CompileResult = compile_node(c, f_acc.obj);
            if (has_result(obj_res) && obj_res.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
            
            let type_id: Int = obj_res.type;
            let obj_reg: String = obj_res.reg;
            
            if (type_id == TYPE_GENERIC_STRUCT) {
                let base_obj: Int = node_tag(f_acc.obj);
                if (base_obj == NODE_VAR_ACCESS) {
                    let v_node: VarAccessNode = get_var_access_node(c.arena, f_acc.obj);
                    let info: SymbolInfo = find_symbol(c, v_node.name_tok.value);
                    if (has_symbol(info) && info.origin_type >= 100) {
                        type_id = info.origin_type;
                        let s_info_temp: StructInfo = c.struct_id_map.lookup("" + type_id);
                        if (has_struct(s_info_temp)) {
                            let cast_reg: String = next_reg(c);
                            c.output_file.write(c.indent + cast_reg + " = bitcast i8* " + obj_reg + " to " + s_info_temp.llvm_name + "*\n");
                            obj_reg = cast_reg;
                        }
                    }
                }
            }

            if (is_pointer_type(c, type_id)) {
                let base_info: SymbolInfo = c.ptr_base_map.lookup("" + type_id);
                if (!has_symbol(base_info)) {
                    throw_type_error(u.pos, "Cannot access a field through an untyped pointer.");
                    return CompileResult(reg="poison", type=TYPE_POISON);
                }
                type_id = base_info.type;
            }
            
            let s_info: StructInfo = c.struct_id_map.lookup("" + type_id);
            if (!has_struct(s_info)) {
                throw_type_error(u.pos, "Cannot access field on non-struct type.");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            
            let field: FieldInfo = find_field(s_info, f_acc.field_name);
            if (!has_field(field)) {
                throw_name_error(u.pos, "Field '" + f_acc.field_name + "' not found.");
                return CompileResult(reg="poison", type=TYPE_POISON);
            }
            
            target_type = field.type;
            type_str = field.llvm_type;
            target_reg = next_reg(c);

            c.output_file.write(c.indent + target_reg + " = getelementptr inbounds " + s_info.llvm_name + ", " + s_info.llvm_name + "* " + obj_reg + ", i32 0, i32 " + field.offset + "\n");
            
        } else {
            let op_str: String = "++";
            if (op_type == TOK_DEC) { op_str = "--"; }
            throw_type_error(u.pos, "Operator '" + op_str + "' can only be applied to variables or struct fields.");
            return void_result();
        }
        
        let operation_type: Int = get_repr_type(c, target_type);
        if (operation_type == TYPE_BOOL) {
            throw_type_error(u.pos, "Cannot increment/decrement Bool type. ");
            return void_result();
        }

        let old_val_reg: String = next_reg(c);
        c.output_file.write(c.indent + old_val_reg + " = load " + type_str + ", " + type_str + "* " + target_reg + "\n");

        let new_val_reg: String = next_reg(c);

        if (is_integer_type(operation_type)) {
            let op_code: String = "add";
            if (op_type == TOK_DEC) { op_code = "sub"; }
            c.output_file.write(c.indent + new_val_reg + " = " + op_code + " " + type_str + " " + old_val_reg + ", 1\n");
        }
        else if (operation_type == TYPE_FLOAT || operation_type == TYPE_FLOAT32) {
            let op_code: String = "fadd";
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

    if (base == NODE_UNARYOP) {
        let u: UnaryOpNode = get_unary_node(c.arena, node);
        let op_type: Int = u.op_tok.type; 
        
        let operand: CompileResult = compile_node(c, u.node);
        if (has_result(operand) && operand.type == TYPE_POISON) { return CompileResult(reg="poison", type=TYPE_POISON); }
        let operand_type: Int = operand.type;
        let operation_type: Int = get_repr_type(c, operand_type);
        let res_reg: String = next_reg(c);

        if (op_type == TOK_SUB) {
            if (is_integer_type(operation_type)) {
                let ty_str: String = get_llvm_type_str(c, operand.type);
                c.output_file.write(c.indent + res_reg + " = sub " + ty_str + " 0, " + operand.reg + "\n");
                return CompileResult(reg=res_reg, type=operand_type);
            } else if (operation_type == TYPE_FLOAT || operation_type == TYPE_FLOAT32) {
                let ty_str: String = get_llvm_type_str(c, operand.type);
                c.output_file.write(c.indent + res_reg + " = fneg " + ty_str + " " + operand.reg + "\n");
                return CompileResult(reg=res_reg, type=operand_type);
            } else {
                throw_type_error(u.pos, "Cannot negate non-numeric type. ");
                return void_result();
            }
        }
        else if (op_type == TOK_NOT) {
            if (operation_type != TYPE_BOOL) {
                throw_type_error(u.pos, "Operator '!' requires Bool type. ");
                return void_result();
            }
            c.output_file.write(c.indent + res_reg + " = xor i1 " + operand.reg + ", 1\n");
            return CompileResult(reg=res_reg, type=operand_type);
        } 
        else if (op_type == TOK_BIT_NOT) {
            if (is_integer_type(operation_type)) {
                let ty_str: String = get_llvm_type_str(c, operand.type);
                c.output_file.write(c.indent + res_reg + " = xor " + ty_str + " " + operand.reg + ", -1\n");
                return CompileResult(reg=res_reg, type=operand_type);
            } else {
                throw_type_error(u.pos, "Operator '~' requires an integer type.");
                return void_result();
            }
        }
        else {
            return operand;
        }
    }

    return CompileResult();
}

func compile_string_method_call(c: Compiler, obj_node: NodeID, method_name: String, call_node: CallNode) -> CompileResult {
    // check if method exists before compiling obj_node to avoid double compile
    let target_func: String = "string_" + method_name;
    let real_func_name: String = c.compiler_link.lookup(target_func);

    if (real_func_name is null) {
        return CompileResult();
    }

    let f_info: FuncInfo = c.func_table.lookup(real_func_name);
    if (!has_func(f_info)) {
        throw_internal_compiler_error(call_node.pos, "Missing function metadata for CompilerLink '" + target_func + "'.");
        return CompileResult(reg="poison", type=TYPE_POISON);
    }
    if (!validate_fallible_call(c, f_info.ret_type, call_node.preserve_fallible, method_name, call_node.pos)) {
        return CompileResult(reg="poison", type=TYPE_POISON);
    }

    let obj_res: CompileResult = compile_node(c, obj_node);

    // White Language methods receive the string object; native adapters receive its buffer
    let args_str: String = "%struct.$String* " + obj_res.reg;
    let args: Vector(ArgNode) = call_node.args;
    let a_len: Int = 0;
    if (args is !null) { a_len = args.length(); }
    let native_args: BoundCallArgs = bind_native_args(args, f_info, 1, call_node.pos);
    if (!has_bound_args(native_args)) { return CompileResult(reg="poison", type=TYPE_POISON); }
    args = native_args.ordered;
    a_len = f_info.arg_types.length() - 1;
    let a_idx: Int = 0;
    let owned_args: Vector(Struct) = [];
    
    while (a_idx < a_len) {
        args_str = args_str + ", ";
        let curr_arg: ArgNode = args[a_idx];
        let expected_node: TypeListNode = f_info.arg_types[a_idx + 1];
        c.expected_type = expected_node.type;
        let arg_res: CompileResult = compile_node(c, curr_arg.val);
        c.expected_type = 0;
        arg_res = emit_implicit_cast(c, arg_res, expected_node.type, call_node.pos);
        
        args_str = args_str + get_llvm_type_str(c, arg_res.type) + " " + arg_res.reg;
        if (arg_res.owns_ref) { owned_args.append(arg_res); }
        a_idx += 1;
    }

    let ret_ty_str: String = get_llvm_type_str(c, f_info.ret_type);
    let call_reg: String = "";
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

func compile_start(c: Compiler) -> Void {

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
    let variant_id: Int = c.type_counter;
    c.type_counter += 1;
    let v_fields: Vector(Struct) = [];
    v_fields.append(FieldInfo(name="type_id", type=TYPE_UINT64, llvm_type="i64", offset=0));
    v_fields.append(FieldInfo(name="payload_low", type=TYPE_LONG, llvm_type="i64", offset=1));
    v_fields.append(FieldInfo(name="payload_high", type=TYPE_LONG, llvm_type="i64", offset=2));

    let variant_info: StructInfo = StructInfo(
        name="$Variant", 
        type_id=variant_id, 
        fields=v_fields, 
        llvm_name="%struct.$Variant", 
        init_body=NO_NODE, 
        is_class=true, 
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
    
    let string_info: StructInfo = StructInfo(
        name="String", 
        type_id=TYPE_STRING, 
        fields=null, 
        llvm_name="%struct.$String", 
        init_body=NO_NODE, is_class=false, 
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

func compile(c: Compiler, node: NodeID) -> Void {
    // discover every module before lowering; import order must not change symbol visibility
    compile_start(c);

    let fake_path: Token = Token(type=TOK_STR_LIT, value="dict", line=0, col=0);
    let fake_pos: Position = Position(idx=0, ln=0, col=0, text="", fn="<prelude>");
    let star_tok: Token = Token(type=TOK_MUL, value="*", line=0, col=0);
    let star_sym: ImportSymbolNode = ImportSymbolNode(name_tok=star_tok, alias_tok=Token());
    let fake_syms: Vector(ImportSymbolNode) = [];
    fake_syms.append(star_sym);

    // error is a language-level prelude item, not part of the builtin namespace
    let fake_error_path: Token = Token(type=TOK_STR_LIT, value="errors", line=0, col=0);
    let fake_error_import: ImportNode = ImportNode(type=NODE_IMPORT, path_tok=fake_error_path, symbols=fake_syms, alias_tok=Token(), pos=fake_pos);
    compile_import(c, fake_error_import);

    // builtin is the prelude and carries the hooks required by generated code
    let fake_builtin_path: Token = Token(type=TOK_STR_LIT, value="builtin", line=0, col=0);
    let fake_builtin_import: ImportNode = ImportNode(type=NODE_IMPORT, path_tok=fake_builtin_path, symbols=fake_syms, alias_tok=Token(), pos=fake_pos);
    compile_import(c, fake_builtin_import);

    let fake_import: ImportNode = ImportNode(type=NODE_IMPORT, path_tok=fake_path, symbols=fake_syms, alias_tok=Token(), pos=fake_pos);
    compile_import(c, fake_import);

    if (!has_struct(c.struct_table.lookup("dict.Variant"))) {
        throw_import_error(fake_pos, "Missing required intrinsic item '@CompilerIntrinsic struct Variant'. The standard library 'dict.wl' may be corrupted or missing.");
        return;
    }

    precompile_ast(c, node, "<main>", "", c.current_dir);

    let mod_i: Int = 0;
    while (mod_i < c.all_modules.length()) {
        let p_mod: ParsedModule = c.all_modules[mod_i];
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
        let p_mod: ParsedModule = c.all_modules[mod_i];
        compile_ast_pass(c, p_mod);
        mod_i += 1;
    }
    emit_pending_generics(c);
    compile_end(c);
}

func compile_end(c: Compiler) -> Void {
    // generated helpers depend on the complete type table, so they are emitted last
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
    emit_hash_helpers(c);
    emit_erased_check_helpers(c);
    emit_windows_abi(c);
    emit_windows_entrypoint(c);

    let str_vec: Vector(Struct) = c.string_list;
    let s_len: Int = 0; if (str_vec is !null) { s_len = str_vec.length(); }
    let s_idx: Int = 0;
    while (s_idx < s_len) {
        let curr: StringConstant = str_vec[s_idx];
        let val: String = curr.value;
        let escaped_val: String = string_escape(val);
        let id: Int = curr.id;
        let len: Int = val.length() + 1;
        let real_len: Int = len - 1; // excluding \0

        let bytes_def: String = "@.str.bytes." + id + " = private unnamed_addr constant [" + len + " x i8] c\"" + escaped_val + "\\00\"\n";
        // string globals carry the runtime String type id in their object header
        let struct_def: String = "@.str." + id + " = private unnamed_addr constant { i32, i32, %struct.$String } { i32 -1, i32 5, %struct.$String { i8* getelementptr inbounds ([" + len + " x i8], [" + len + " x i8]* @.str.bytes." + id + ", i32 0, i32 0), i32 " + real_len + ", i32 " + real_len + " } }\n";

        c.output_file.write(bytes_def);
        c.output_file.write(struct_def);
        s_idx += 1;
    }

    c.output_file.write("; ====== Lambda Lifted Closures and Envs =====\n");
    c.output_file.write(c.global_buffer);
    c.output_file.write("\n");
    c.output_file.close();

    if (c.generic_type_defs.length() > 0) {
        let original: file.File = file.open(c.output_file.path)?;
        catch(err) {
            throw_internal_compiler_error(no_position(), "Cannot reopen generated LLVM IR while finalizing generic types.");
            return;
        }

        let body: String = original.read_all()?;
        catch(err) {
            original.close();
            throw_internal_compiler_error(no_position(), "Cannot read generated LLVM IR while finalizing generic types.");
            return;
        }
        original.close();

        let rewrite: file.File = file.create(c.output_file.path)?;
        catch(err) {
            throw_internal_compiler_error(no_position(), "Cannot rewrite generated LLVM IR while finalizing generic types.");
            return;
        }

        let line_end: Int = 0;
        while (line_end < body.length() && body[line_end] != '\n') { line_end++; }
        if (line_end < body.length()) { line_end++; }
        rewrite.write(body.slice(0, line_end));
        rewrite.write(c.generic_type_defs);
        rewrite.write(body.slice(line_end, body.length()));
        rewrite.close();
    }
}

func emit_pending_generic_funcs(c: Compiler) -> Void {
    let index: Int = c.generic_func_emitted;
    while (index < c.generic_worklist.length()) {
        let instance: GenericFuncInstance = c.generic_worklist[index];
        index++;
        c.generic_func_emitted = index;
        let template: GenericTemplate = instance.template;
        let node: FunctionDefNode = get_func_def_node(c.arena, template.node);
        let previous_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
        let previous: GenericTemplate = use_generic_context(c, template, instance.bindings);
        let previous_key: String = c.generic_func_key;
        let previous_depth: Int = c.generic_depth;
        c.generic_func_key = instance.func_key;
        c.generic_depth = instance.depth;

        compile_func_def(c, node);

        c.generic_depth = previous_depth;
        c.generic_func_key = previous_key;
        restore_generic_context(c, previous, previous_bindings);
    }
}

func emit_pending_generic_classes(c: Compiler) -> Void {
    let index: Int = c.generic_class_emitted;
    while (index < c.generic_class_worklist.length()) {
        let instance: GenericClassInstance = c.generic_class_worklist[index];
        index++;
        c.generic_class_emitted = index;
        let template: GenericTemplate = instance.template;
        let node: ClassDefNode = get_class_def_node(c.arena, template.node);
        let previous_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
        let previous: GenericTemplate = use_generic_context(c, template, instance.bindings);
        let previous_type: Int = c.generic_class_type;
        let previous_depth: Int = c.generic_depth;
        c.generic_class_type = instance.type_id;
        c.generic_depth = instance.depth;

        compile_class_def(c, node);

        c.generic_depth = previous_depth;
        c.generic_class_type = previous_type;
        restore_generic_context(c, previous, previous_bindings);
    }
}

func emit_pending_generic_methods(c: Compiler) -> Void {
    let index: Int = c.generic_method_emitted;
    while (index < c.generic_method_worklist.length()) {
        let instance: GenericMethodInstance = c.generic_method_worklist[index];
        index++;
        c.generic_method_emitted = index;
        let template: GenericTemplate = instance.template;
        let node: MethodDefNode = get_method_def_node(c.arena, template.node);
        let previous_bindings: Dict(String, SymbolInfo) = c.generic_bindings;
        let previous: GenericTemplate = use_generic_context(c, template, instance.bindings);
        let previous_key: String = c.generic_method_key;
        let previous_depth: Int = c.generic_depth;
        c.generic_method_key = instance.func_key;
        c.generic_depth = instance.depth;

        compile_method_def(c, instance.owner_name, node);

        c.generic_depth = previous_depth;
        c.generic_method_key = previous_key;
        restore_generic_context(c, previous, previous_bindings);
    }
}

func has_pending_generics(c: Compiler) -> Bool {
    return c.generic_class_emitted < c.generic_class_worklist.length() || c.generic_func_emitted < c.generic_worklist.length() || c.generic_method_emitted < c.generic_method_worklist.length();
}

func emit_generic_vtables(c: Compiler) -> Void {
    let table_index: Int = 0;
    while (table_index < c.generic_vtables.length()) {
        let info: StructInfo = c.generic_vtables[table_index];
        let methods: Vector(Struct) = info.vtable;
        let method_count: Int = 0;
        if (methods is !null) { method_count = methods.length(); }

        let definition: String = info.vtable_name + " = global " + class_vtable_type(c, info);
        if (method_count == 0) {
            definition += " zeroinitializer\n\n";
        } else {
            definition += " [ ";
            let method_index: Int = 0;
            while (method_index < method_count) {
                let method_info: FuncInfo = methods[method_index];
                let key: String = info.name + "_" + method_info.base_name;
                let generic_method: GenericTemplate = c.generic_class_methods.lookup(key);
                let emitted: Bool = !has_template(generic_method) || c.generic_methods_queued.lookup(key);
                if (method_index > 0) { definition += ", "; }
                if emitted {
                    definition += "i8* bitcast (" + get_func_sig_str(c, method_info) + " @" + method_info.name + " to i8*)";
                } else {
                    definition += "i8* null";
                }
                method_index += 1;
            }
            definition += " ]\n\n";
        }
        c.generic_type_defs += definition;
        table_index += 1;
    }
}

func emit_pending_generics(c: Compiler) -> Void {
    // an instance may request another instance, so drain the work lists to a fixed point
    while (has_pending_generics(c)) {
        emit_pending_generic_classes(c);
        emit_pending_generic_funcs(c);
        emit_pending_generic_methods(c);
    }
    emit_generic_vtables(c);
}
