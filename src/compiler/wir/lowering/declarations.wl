// compiler/wir/lowering/declarations.wl
import * from "../model.wl"
import * from "../builder.wl"
import * from "types.wl"
import * from "../../context.wl"
import PARAM_VALUE, PARAM_REF from "../../../frontend/ast.wl"

func wir_function_abi(ref types: WirTypeMap, info: FuncInfo) -> WirABI {
    if (info.abi_name is null || info.abi_name.length() == 0) { return WirABI.White; }
    if (info.abi_name == "C" || info.abi_name == "c") { return WirABI.C; }
    if (info.abi_name == "system" || info.abi_name == "System" || info.abi_name == "SYSTEM") { return WirABI.System; }
    types.errors.append("Unknown ABI '" + info.abi_name + "' on function '" + info.name + "'");
    return WirABI.White;
}

func wir_function_linkage(info: FuncInfo, abi: WirABI) -> WirLinkage {
    if (abi != WirABI.White) { return WirLinkage.External; }
    if (info.base_name == "main" || (info.ann_flags & FLAG_ANN_EXPORT) != 0) { return WirLinkage.Exported; }
    return WirLinkage.Internal;
}

func wir_lower_parameter_type(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, parameter: TypeListNode) -> WirTypeID {
    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, parameter.type);
    if (type_id == NO_WIR_TYPE) { return NO_WIR_TYPE; }
    if (parameter.pass_mode == PARAM_VALUE) { return type_id; }
    if (parameter.pass_mode == PARAM_REF) { return wir_pointer_type(ref program, type_id); }
    types.errors.append("Unknown parameter passing mode " + parameter.pass_mode);
    return NO_WIR_TYPE;
}

func wir_lower_function_decl(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: FuncInfo) -> WirFuncID {
    if (!has_func(info)) {
        types.errors.append("Cannot lower an empty function declaration");
        return NO_WIR_FUNC;
    }
    if ((info.ann_flags & FLAG_ANN_INTRINSIC) != 0) { return NO_WIR_FUNC; }

    let result: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, info.ret_type);
    if (result == NO_WIR_TYPE) { return NO_WIR_FUNC; }
    let parameters: Vector(WirParam) = [];
    let i: Int = 0;
    while (info.arg_types is !null && i < info.arg_types.length()) {
        let parameter: TypeListNode = info.arg_types[i];
        let type_id: WirTypeID = wir_lower_parameter_type(ref types, ref source, ref program, parameter);
        if (type_id == NO_WIR_TYPE) { return NO_WIR_FUNC; }
        let name: String = "arg" + i;
        if (info.arg_names is !null && i < info.arg_names.length() && info.arg_names[i].length() != 0) { name = info.arg_names[i]; }
        parameters.append(wir_param(name, type_id));
        i++;
    }

    let abi: WirABI = wir_function_abi(ref types, info);
    let linkage: WirLinkage = wir_function_linkage(info, abi);
    if (linkage == WirLinkage.External && abi == WirABI.White) { return NO_WIR_FUNC; }
    return wir_add_function(ref program, info.name, parameters, result, info.is_varargs, linkage, abi);
}

func wir_find_function(program: WirModule, name: String) -> WirFuncID {
    let i: Int = 0;
    while (i < program.arena.functions.length()) {
        if (program.arena.functions[i].name == name) { return WirFuncID(UInt32(i + 1)); }
        i++;
    }
    return NO_WIR_FUNC;
}
