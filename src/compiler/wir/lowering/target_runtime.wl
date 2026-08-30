// compiler/wir/lowering/target_runtime.wl

import * from "../model.wl"
import * from "../builder.wl"
import * from "declarations.wl"
import * from "globals.wl"
import * from "../../context.wl"

func wir_windows_target(program: WirModule) -> Bool {
    return program.target == "i686-pc-windows-msvc" || program.target == "x86_64-pc-windows-msvc";
}

func wir_runtime_function(ref source: Compiler, program: WirModule, link_name: String, errors: Vector(String)) -> WirFuncID {
    let info: FuncInfo = wir_compiler_link_function(ref source, link_name);
    if (!has_func(info)) {
        errors.append("Windows entry point requires compiler link '" + link_name + "'");
        return NO_WIR_FUNC;
    }
    let function_id: WirFuncID = wir_find_function(program, info.name);
    if (function_id == NO_WIR_FUNC) { errors.append("Windows entry point cannot find WIR function '" + info.name + "'"); }
    return function_id;
}

func wir_emit_windows_abi(ref program: WirModule) -> Void {
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    if (wir_find_global(program, "_fltused") == NO_WIR_GLOBAL) {
        let value: WirValueID = wir_const_int(ref program, int_type, UInt128(39029U));
        wir_add_global(ref program, "_fltused", int_type, value, WirLinkage.Exported, false);
    }
    if (wir_find_function(program, "__main") == NO_WIR_FUNC) {
        let function_id: WirFuncID = wir_add_function(ref program, "__main", [], program.void_type, false, WirLinkage.Exported, WirABI.White);
        let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
        wir_return(ref program, entry, NO_WIR_VALUE, no_wir_location());
    }
}

func wir_emit_windows_dll_entry(ref program: WirModule) -> Void {
    if (wir_find_function(program, "DllMainCRTStartup") != NO_WIR_FUNC) { return; }
    let pointer: WirTypeID = wir_pointer_type(ref program, program.void_type);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let parameters: Vector(WirParam) = [wir_param("instance", pointer), wir_param("reason", int_type), wir_param("reserved", pointer)];
    let function_id: WirFuncID = wir_add_function(ref program, "DllMainCRTStartup", parameters, int_type, false, WirLinkage.Exported, WirABI.System);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    wir_return(ref program, entry, wir_const_int(ref program, int_type, UInt128(1U)), no_wir_location());
}

func wir_emit_windows_main_entry(ref source: Compiler, ref program: WirModule, errors: Vector(String)) -> Void {
    if (wir_find_function(program, "mainCRTStartup") != NO_WIR_FUNC) { return; }
    let main_id: WirFuncID = wir_find_function(program, "main");
    if (main_id == NO_WIR_FUNC) {
        errors.append("Windows executable has no main function");
        return;
    }
    let exit_id: WirFuncID = wir_runtime_function(ref source, program, "process_exit", errors);
    if (exit_id == NO_WIR_FUNC) { return; }

    let main_function: WirFunction = program.arena.functions[wir_id_index(UInt32(main_id))];
    let main_type: WirType = program.arena.types[wir_id_index(UInt32(main_function.type_id))];
    if (main_type.parameters.length() != 0 && main_type.parameters.length() != 2) {
        errors.append("Windows entry point requires main() or main(argc, argv)");
        return;
    }

    let function_id: WirFuncID = wir_add_function(ref program, "mainCRTStartup", [], program.void_type, false, WirLinkage.Exported, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function_id, "entry", []);
    let status: WirValueID = NO_WIR_VALUE;
    if (main_type.parameters.length() == 0) {
        status = wir_call(ref program, entry, wir_function_value(program, main_id), [], "status", no_wir_location());
        wir_call(ref program, entry, wir_function_value(program, exit_id), [status], "", no_wir_location());
        wir_append(ref program, entry, WirOpcode.Unreachable, program.void_type, [], [], no_wir_location());
        return;
    }

    let args_id: WirFuncID = wir_runtime_function(ref source, program, "startup_args", errors);
    let free_id: WirFuncID = wir_runtime_function(ref source, program, "startup_args_free", errors);
    if (args_id == NO_WIR_FUNC || free_id == NO_WIR_FUNC) { return; }
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let argc_slot: WirValueID = wir_stack_alloc(ref program, entry, int_type, "argc.addr", no_wir_location());
    wir_store(ref program, entry, wir_const_int(ref program, int_type, UInt128(0U)), argc_slot, no_wir_location());
    let raw_argv: WirValueID = wir_call(ref program, entry, wir_function_value(program, args_id), [argc_slot], "argv.raw", no_wir_location());
    let raw_type: WirTypeID = wir_value_type(program, raw_argv);
    let missing: WirValueID = wir_binary(ref program, entry, WirOpcode.Equal, program.bool_type, raw_argv, wir_null(ref program, raw_type), "argv.missing", no_wir_location());
    let failed: WirBlockID = wir_add_block(ref program, function_id, "startup.failed", []);
    let ready: WirBlockID = wir_add_block(ref program, function_id, "startup.ready", []);
    wir_append(ref program, entry, WirOpcode.Branch, program.void_type, [missing], [wir_edge(failed, []), wir_edge(ready, [])], no_wir_location());

    let failed_status: WirValueID = wir_const_int(ref program, int_type, UInt128(127U));
    wir_call(ref program, failed, wir_function_value(program, exit_id), [failed_status], "", no_wir_location());
    wir_append(ref program, failed, WirOpcode.Unreachable, program.void_type, [], [], no_wir_location());

    let argc: WirValueID = wir_load(ref program, ready, argc_slot, "argc", no_wir_location());
    let argv: WirValueID = wir_cast(ref program, ready, raw_argv, main_type.parameters[1], "argv", no_wir_location());
    status = wir_call(ref program, ready, wir_function_value(program, main_id), [argc, argv], "status", no_wir_location());
    wir_call(ref program, ready, wir_function_value(program, free_id), [argc, raw_argv], "", no_wir_location());
    wir_call(ref program, ready, wir_function_value(program, exit_id), [status], "", no_wir_location());
    wir_append(ref program, ready, WirOpcode.Unreachable, program.void_type, [], [], no_wir_location());
}

func wir_emit_target_runtime(ref source: Compiler, ref program: WirModule, errors: Vector(String)) -> Void {
    if (!wir_windows_target(program)) { return; }
    let has_runtime: Bool = source.is_shared || has_func(wir_compiler_link_function(ref source, "process_exit"));
    if (!has_runtime) { return; }
    wir_emit_windows_abi(ref program);
    if (source.is_shared) { wir_emit_windows_dll_entry(ref program); }
    else { wir_emit_windows_main_entry(ref source, ref program, errors); }
}
