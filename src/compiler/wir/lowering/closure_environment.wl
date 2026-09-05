// compiler/wir/lowering/closure_environment.wl

import * from "../model.wl"
import * from "../builder.wl"
import * from "../layout.wl"
import * from "../runtime.wl"
import * from "state.wl"
import * from "types.wl"
import * from "ownership.wl"
import * from "declarations.wl"
import * from "../../context.wl"
import * from "../../../frontend/ast.wl"
import * from "../../../frontend/arena.wl"

func wir_reference_parameter(program: WirModule, binding: WirBinding) -> Bool {
    if (binding.address == NO_WIR_VALUE) { return false; }
    return program.arena.values[wir_id_index(UInt32(binding.address))].kind == WirValueKind.FunctionParameter;
}

func wir_capture_binding(state: WirFunctionLowering, name: String) -> WirBinding? {
    let i: Int = state.bindings.length() - 1;
    while (i >= 0) {
        if (state.bindings[i].name == name) { return state.bindings[i]; }
        i--;
    }
    throw Error.InvalidData;
}

func wir_closure_captures(ref state: WirFunctionLowering, ref source: Compiler, ref program: WirModule, node: FunctionDefNode) -> Vector(WirBinding) {
    let scope: CaptureScope = CaptureScope(local_vars=Dict(), captured_vars=Dict(), captured_list=[]);
    let i: Int = 0;
    while (node.params is !null && i < node.params.length()) {
        let parameter: ParamNode = node.params[i];
        if (has_node(parameter.default_val)) {
            state.errors.append("Local function '" + node.name_tok.value + "' cannot declare default parameters");
            return null;
        }
        scope.local_vars.put(parameter.name_tok.value, true);
        i++;
    }
    if (node.name_tok.value.length() != 0) { scope.local_vars.put(node.name_tok.value, true); }
    analyze_captures(source.arena, node.body, scope);

    let captures: Vector(WirBinding) = [];
    i = 0;
    while (i < scope.captured_list.length()) {
        let name: String = scope.captured_list[i];
        let binding: WirBinding = wir_capture_binding(state, name)?;
        catch(err) {
            i++;
            continue;
        }
        if (wir_reference_parameter(program, binding)) {
            state.errors.append("Local function '" + node.name_tok.value + "' cannot capture reference parameter '" + name + "'");
            return null;
        }
        captures.append(binding);
        i++;
    }
    return captures;
}

func wir_closure_environment_type(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, captures: Vector(WirBinding), name: String) -> WirTypeID {
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    // the callable prefix lets recursive references use the environment without another wrapper
    let fields: Vector(WirTypeID) = [raw_pointer, raw_pointer];
    let i: Int = 0;
    while (i < captures.length()) {
        let field: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, captures[i].source_type);
        if (field == NO_WIR_TYPE) { return NO_WIR_TYPE; }
        fields.append(field);
        i++;
    }
    let type_id: WirTypeID = wir_declare_struct(ref program, name);
    wir_define_struct(ref program, type_id, fields);
    return type_id;
}

func wir_closure_environment_drop(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, env_type: WirTypeID, captures: Vector(WirBinding), name: String) -> WirFuncID {
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let function_id: WirFuncID = wir_add_function(ref program, name, [wir_param("environment", raw_pointer)], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let state: WirFunctionLowering = WirFunctionLowering(function=function_id, return_type=TYPE_VOID, entry=entry, block=entry, bindings=[], loops=[], error_targets=[], owned_values=[], errors=[], terminated=false, next_block=0);
    let environment: WirValueID = wir_cast(ref program, entry, function.parameters[0], wir_pointer_type(ref program, env_type), "environment", no_wir_location());

    let i: Int = 0;
    while (i < captures.length()) {
        let capture: WirBinding = captures[i];
        if (wir_value_needs_drop(ref source, capture.source_type)) {
            let address: WirValueID = wir_field_address(ref program, state.block, environment, i + 2, "", no_wir_location());
            wir_emit_ownership_slot(ref state, ref source, ref program, address, capture.source_type, false);
        }
        i++;
    }
    wir_return(ref program, state.block, NO_WIR_VALUE, no_wir_location());
    i = 0;
    while (i < state.errors.length()) {
        types.errors.append("In closure environment drop '" + name + "': " + state.errors[i]);
        i++;
    }
    return function_id;
}

func wir_alloc_closure_environment(ref state: WirFunctionLowering, ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, env_type: WirTypeID, captures: Vector(WirBinding), drop_id: WirFuncID, type_tag: Int) -> WirValueID {
    let layout: WirTypeLayout = wir_type_layout(program, env_type);
    if (!layout.valid || layout.size > UInt64(wir_max_object_size(program.data_layout)) - UInt64(WIR_OBJECT_HEADER_SIZE)) {
        state.errors.append("Closure environment is too large for the target address space");
        return NO_WIR_VALUE;
    }
    let allocator: FuncInfo = wir_compiler_link_function(ref source, "memory_alloc");
    if (!has_func(allocator)) {
        state.errors.append("Closure construction requires the memory_alloc compiler link");
        return NO_WIR_VALUE;
    }
    let allocator_id: WirFuncID = wir_find_function(program, allocator.name);
    if (allocator_id == NO_WIR_FUNC) { allocator_id = wir_lower_function_decl(ref types, ref source, ref program, allocator); }
    if (allocator_id == NO_WIR_FUNC) { return NO_WIR_VALUE; }

    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let total_size: UInt64 = layout.size + UInt64(WIR_OBJECT_HEADER_SIZE);
    let raw: WirValueID = wir_call(ref program, state.block, wir_function_value(program, allocator_id), [wir_const_int(ref program, size_type, UInt128(total_size))], "", no_wir_location());
    wir_append(ref program, state.block, WirOpcode.NullCheck, program.void_type, [raw], [], no_wir_location());

    let drop_address: WirValueID = wir_const_address(ref program, raw_pointer, wir_function_value(program, drop_id), 0L);
    let drop_slot: WirValueID = wir_cast(ref program, state.block, raw, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    wir_store(ref program, state.block, drop_address, drop_slot, no_wir_location());
    let uint32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let refcount_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_REFCOUNT_OFFSET, wir_pointer_type(ref program, uint32_type));
    let type_slot: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE + WIR_ARC_TYPE_OFFSET, wir_pointer_type(ref program, uint32_type));
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(1U)), refcount_slot, no_wir_location());
    wir_store(ref program, state.block, wir_const_int(ref program, uint32_type, UInt128(UInt32(type_tag))), type_slot, no_wir_location());

    let environment: WirValueID = wir_pointer_offset(ref program, state.block, raw, WIR_OBJECT_HEADER_SIZE, wir_pointer_type(ref program, env_type));
    let i: Int = 0;
    while (i < captures.length()) {
        let capture: WirBinding = captures[i];
        let value: WirValueID = wir_load(ref program, state.block, capture.address, capture.name, no_wir_location());
        if (wir_value_needs_drop(ref source, capture.source_type)) {
            wir_emit_ownership_value(ref state, ref source, ref program, value, capture.source_type, true);
        }
        let address: WirValueID = wir_field_address(ref program, state.block, environment, i + 2, "", no_wir_location());
        wir_store(ref program, state.block, value, address, no_wir_location());
        i++;
    }
    return wir_cast(ref program, state.block, environment, raw_pointer, "environment", no_wir_location());
}

func wir_initialize_closure_environment(ref state: WirFunctionLowering, ref types: WirTypeMap, ref program: WirModule, environment: WirValueID, code: WirValueID) -> Void {
    let raw_pointer: WirTypeID = wir_opaque_pointer(ref types, ref program);
    let code_slot: WirValueID = wir_cast(ref program, state.block, environment, wir_pointer_type(ref program, raw_pointer), "", no_wir_location());
    let context_slot: WirValueID = wir_pointer_offset(ref program, state.block, environment, program.pointer_bits / 8, wir_pointer_type(ref program, raw_pointer));
    wir_store(ref program, state.block, code, code_slot, no_wir_location());
    wir_store(ref program, state.block, environment, context_slot, no_wir_location());
}
