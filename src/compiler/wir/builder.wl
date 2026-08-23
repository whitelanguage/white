// compiler/wir/builder.wl
import * from "model.wl"

func new_wir_arena() -> WirArena {
    return WirArena(types=[], values=[], instructions=[], blocks=[], functions=[], globals=[]);
}

func wir_add_type(ref program: WirModule, value: WirType) -> WirTypeID {
    program.arena.types.append(value);
    return WirTypeID(UInt32(program.arena.types.length()));
}

func wir_scalar_type(ref program: WirModule, kind: WirTypeKind, bits: Int) -> WirTypeID {
    let i: Int = 0;
    while (i < program.arena.types.length()) {
        let current: WirType = program.arena.types[i];
        if (current.kind == kind && current.bits == bits) { return WirTypeID(UInt32(i + 1)); }
        i++;
    }
    return wir_add_type(ref program, WirType(kind=kind, name="", complete=true, bits=bits, element=NO_WIR_TYPE, length=UIntSize(0U), fields=[], parameters=[], result=NO_WIR_TYPE, variadic=false));
}

func wir_signed_int_type(ref program: WirModule, bits: Int) -> WirTypeID {
    return wir_scalar_type(ref program, WirTypeKind.SignedInt, bits);
}

func wir_unsigned_int_type(ref program: WirModule, bits: Int) -> WirTypeID {
    return wir_scalar_type(ref program, WirTypeKind.UnsignedInt, bits);
}

func wir_float_type(ref program: WirModule, bits: Int) -> WirTypeID {
    return wir_scalar_type(ref program, WirTypeKind.FloatType, bits);
}

func wir_pointer_type(ref program: WirModule, element: WirTypeID) -> WirTypeID {
    let i: Int = 0;
    while (i < program.arena.types.length()) {
        let current: WirType = program.arena.types[i];
        if (current.kind == WirTypeKind.Pointer && current.element == element) { return WirTypeID(UInt32(i + 1)); }
        i++;
    }
    return wir_add_type(ref program, WirType(kind=WirTypeKind.Pointer, name="", complete=true, bits=0, element=element, length=UIntSize(0U), fields=[], parameters=[], result=NO_WIR_TYPE, variadic=false));
}

func wir_array_type(ref program: WirModule, element: WirTypeID, length: UIntSize) -> WirTypeID {
    let i: Int = 0;
    while (i < program.arena.types.length()) {
        let current: WirType = program.arena.types[i];
        if (current.kind == WirTypeKind.Array && current.element == element && current.length == length) { return WirTypeID(UInt32(i + 1)); }
        i++;
    }
    return wir_add_type(ref program, WirType(kind=WirTypeKind.Array, name="", complete=true, bits=0, element=element, length=length, fields=[], parameters=[], result=NO_WIR_TYPE, variadic=false));
}

func wir_declare_struct(ref program: WirModule, name: String) -> WirTypeID {
    return wir_add_type(ref program, WirType(kind=WirTypeKind.Struct, name=name, complete=false, bits=0, element=NO_WIR_TYPE, length=UIntSize(0U), fields=[], parameters=[], result=NO_WIR_TYPE, variadic=false));
}

func wir_define_struct(ref program: WirModule, type_id: WirTypeID, fields: Vector(WirTypeID)) -> Void {
    let index: Int = wir_id_index(UInt32(type_id));
    let value: WirType = program.arena.types[index];
    value.fields = fields;
    value.complete = true;
    program.arena.types[index] = value;
}

func wir_struct_type(ref program: WirModule, fields: Vector(WirTypeID)) -> WirTypeID {
    let type_id: WirTypeID = wir_declare_struct(ref program, "");
    wir_define_struct(ref program, type_id, fields);
    return type_id;
}

func wir_type_list_equal(left: Vector(WirTypeID), right: Vector(WirTypeID)) -> Bool {
    if (left.length() != right.length()) { return false; }
    let i: Int = 0;
    while (i < left.length()) {
        if (left[i] != right[i]) { return false; }
        i++;
    }
    return true;
}

func wir_function_type(ref program: WirModule, parameters: Vector(WirTypeID), result: WirTypeID, variadic: Bool) -> WirTypeID {
    let i: Int = 0;
    while (i < program.arena.types.length()) {
        let current: WirType = program.arena.types[i];
        if (current.kind == WirTypeKind.Function && current.result == result && current.variadic == variadic && wir_type_list_equal(current.parameters, parameters)) { return WirTypeID(UInt32(i + 1)); }
        i++;
    }
    return wir_add_type(ref program, WirType(kind=WirTypeKind.Function, name="", complete=true, bits=0, element=NO_WIR_TYPE, length=UIntSize(0U), fields=[], parameters=parameters, result=result, variadic=variadic));
}

func new_wir_module(target: String) -> WirModule {
    let program: WirModule = WirModule(target=target, files=[], arena=new_wir_arena(), void_type=NO_WIR_TYPE, bool_type=NO_WIR_TYPE);
    program.void_type = wir_add_type(ref program, WirType(kind=WirTypeKind.VoidType, name="", complete=true, bits=0, element=NO_WIR_TYPE, length=UIntSize(0U), fields=[], parameters=[], result=NO_WIR_TYPE, variadic=false));
    program.bool_type = wir_add_type(ref program, WirType(kind=WirTypeKind.BoolType, name="", complete=true, bits=1, element=NO_WIR_TYPE, length=UIntSize(0U), fields=[], parameters=[], result=NO_WIR_TYPE, variadic=false));
    return program;
}

func wir_add_source(ref program: WirModule, path: String) -> WirFileID {
    program.files.append(WirSourceFile(path=path));
    return WirFileID(UInt32(program.files.length()));
}

func wir_add_value(ref program: WirModule, value: WirValue) -> WirValueID {
    program.arena.values.append(value);
    return WirValueID(UInt32(program.arena.values.length()));
}

func wir_param(name: String, type_id: WirTypeID) -> WirParam {
    return WirParam(name=name, type_id=type_id);
}

func wir_name_value(ref program: WirModule, value_id: WirValueID, name: String) -> Void {
    let index: Int = wir_id_index(UInt32(value_id));
    let value: WirValue = program.arena.values[index];
    value.name = name;
    program.arena.values[index] = value;
}

func wir_const_int(ref program: WirModule, type_id: WirTypeID, value: UInt128) -> WirValueID {
    return wir_add_value(ref program, WirValue(name="", type_id=type_id, kind=WirValueKind.Integer, owner=0U, index=-1, integer=value, float_bits=UInt64(0)));
}

func wir_const_float(ref program: WirModule, type_id: WirTypeID, value: Float) -> WirValueID {
    let type: WirType = program.arena.types[wir_id_index(UInt32(type_id))];
    let bits: UInt64 = UInt64(0);
    if (type.bits == 32) {
        let narrowed: Float32 = Float32(value);
        let raw: AnyPtr = AnyPtr(ref narrowed);
        let ptr encoded: UInt32 = raw;
        bits = UInt64(deref encoded);
    } else {
        let raw: AnyPtr = AnyPtr(ref value);
        let ptr encoded: UInt64 = raw;
        bits = deref encoded;
    }
    return wir_const_float_bits(ref program, type_id, bits);
}

func wir_const_float_bits(ref program: WirModule, type_id: WirTypeID, bits: UInt64) -> WirValueID {
    return wir_add_value(ref program, WirValue(name="", type_id=type_id, kind=WirValueKind.FloatValue, owner=0U, index=-1, integer=UInt128(0U), float_bits=bits));
}

func wir_const_bool(ref program: WirModule, value: Bool) -> WirValueID {
    let integer: UInt128 = UInt128(0U);
    if value { integer = UInt128(1U); }
    return wir_add_value(ref program, WirValue(name="", type_id=program.bool_type, kind=WirValueKind.BoolValue, owner=0U, index=-1, integer=integer, float_bits=UInt64(0)));
}

func wir_null(ref program: WirModule, type_id: WirTypeID) -> WirValueID {
    return wir_add_value(ref program, WirValue(name="", type_id=type_id, kind=WirValueKind.Null, owner=0U, index=-1, integer=UInt128(0U), float_bits=UInt64(0)));
}

func wir_add_function(ref program: WirModule, name: String, parameters: Vector(WirParam), result: WirTypeID, variadic: Bool, linkage: WirLinkage) -> WirFuncID {
    let function_id: WirFuncID = WirFuncID(UInt32(program.arena.functions.length() + 1));
    let parameter_types: Vector(WirTypeID) = [];
    let i: Int = 0;
    while (i < parameters.length()) {
        parameter_types.append(parameters[i].type_id);
        i++;
    }
    let type_id: WirTypeID = wir_function_type(ref program, parameter_types, result, variadic);
    let values: Vector(WirValueID) = [];
    i = 0;
    while (i < parameters.length()) {
        let parameter: WirValue = WirValue(name=parameters[i].name, type_id=parameters[i].type_id, kind=WirValueKind.FunctionParameter, owner=UInt32(function_id), index=i, integer=UInt128(0U), float_bits=UInt64(0));
        values.append(wir_add_value(ref program, parameter));
        i++;
    }
    let address: WirValueID = wir_add_value(ref program, WirValue(name=name, type_id=type_id, kind=WirValueKind.Function, owner=UInt32(function_id), index=-1, integer=UInt128(0U), float_bits=UInt64(0)));
    program.arena.functions.append(WirFunction(name=name, type_id=type_id, address=address, parameters=values, blocks=[], entry=NO_WIR_BLOCK, linkage=linkage));
    return function_id;
}

func wir_add_block(ref program: WirModule, function_id: WirFuncID, name: String, parameters: Vector(WirParam)) -> WirBlockID {
    let block_id: WirBlockID = WirBlockID(UInt32(program.arena.blocks.length() + 1));
    let values: Vector(WirValueID) = [];
    let i: Int = 0;
    while (i < parameters.length()) {
        let parameter: WirValue = WirValue(name=parameters[i].name, type_id=parameters[i].type_id, kind=WirValueKind.BlockParameter, owner=UInt32(block_id), index=i, integer=UInt128(0U), float_bits=UInt64(0));
        values.append(wir_add_value(ref program, parameter));
        i++;
    }
    program.arena.blocks.append(WirBlock(name=name, function=function_id, parameters=values, instructions=[]));

    let function_index: Int = wir_id_index(UInt32(function_id));
    let function: WirFunction = program.arena.functions[function_index];
    function.blocks.append(block_id);
    if (function.entry == NO_WIR_BLOCK) { function.entry = block_id; }
    program.arena.functions[function_index] = function;
    return block_id;
}

func wir_edge(target: WirBlockID, arguments: Vector(WirValueID)) -> WirEdge {
    return WirEdge(target=target, arguments=arguments);
}

func wir_append(ref program: WirModule, block_id: WirBlockID, opcode: WirOpcode, type_id: WirTypeID, operands: Vector(WirValueID), edges: Vector(WirEdge), location: WirLocation) -> WirValueID {
    let instruction_id: WirInstID = WirInstID(UInt32(program.arena.instructions.length() + 1));
    let result: WirValueID = NO_WIR_VALUE;
    if (type_id != program.void_type) {
        result = wir_add_value(ref program, WirValue(name="", type_id=type_id, kind=WirValueKind.Instruction, owner=UInt32(instruction_id), index=-1, integer=UInt128(0U), float_bits=UInt64(0)));
    }
    program.arena.instructions.append(WirInstruction(opcode=opcode, type_id=type_id, result=result, operands=operands, edges=edges, location=location));
    program.arena.blocks[wir_id_index(UInt32(block_id))].instructions.append(instruction_id);
    return result;
}

func wir_add_global(ref program: WirModule, name: String, type_id: WirTypeID, initializer: WirValueID, linkage: WirLinkage, is_const: Bool) -> WirGlobalID {
    let global_id: WirGlobalID = WirGlobalID(UInt32(program.arena.globals.length() + 1));
    let pointer_type: WirTypeID = wir_pointer_type(ref program, type_id);
    let address: WirValueID = wir_add_value(ref program, WirValue(name=name, type_id=pointer_type, kind=WirValueKind.Global, owner=UInt32(global_id), index=-1, integer=UInt128(0U), float_bits=UInt64(0)));
    program.arena.globals.append(WirGlobal(name=name, type_id=type_id, address=address, initializer=initializer, linkage=linkage, is_const=is_const));
    return global_id;
}

func wir_function_value(program: WirModule, function_id: WirFuncID) -> WirValueID {
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    return function.address;
}

func wir_global_value(program: WirModule, global_id: WirGlobalID) -> WirValueID {
    let global: WirGlobal = program.arena.globals[wir_id_index(UInt32(global_id))];
    return global.address;
}
