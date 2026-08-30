// compiler/wir/builder.wl
import * from "model.wl"
import wir_layout_for_target from "layout.wl"

func new_wir_arena() -> WirArena {
    return WirArena(types=[], values=[], instructions=[], blocks=[], functions=[], globals=[], constants=[]);
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
    return wir_add_type(ref program, WirType(kind=kind, name="", complete=true, bits=bits, element=NO_WIR_TYPE, length=UIntSize(0U), fields=[], parameters=[], result=NO_WIR_TYPE, variadic=false, abi=WirABI.White));
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
    return wir_add_type(ref program, WirType(kind=WirTypeKind.Pointer, name="", complete=true, bits=0, element=element, length=UIntSize(0U), fields=[], parameters=[], result=NO_WIR_TYPE, variadic=false, abi=WirABI.White));
}

func wir_array_type(ref program: WirModule, element: WirTypeID, length: UIntSize) -> WirTypeID {
    let i: Int = 0;
    while (i < program.arena.types.length()) {
        let current: WirType = program.arena.types[i];
        if (current.kind == WirTypeKind.Array && current.element == element && current.length == length) { return WirTypeID(UInt32(i + 1)); }
        i++;
    }
    return wir_add_type(ref program, WirType(kind=WirTypeKind.Array, name="", complete=true, bits=0, element=element, length=length, fields=[], parameters=[], result=NO_WIR_TYPE, variadic=false, abi=WirABI.White));
}

func wir_declare_struct(ref program: WirModule, name: String) -> WirTypeID {
    return wir_add_type(ref program, WirType(kind=WirTypeKind.Struct, name=name, complete=false, bits=0, element=NO_WIR_TYPE, length=UIntSize(0U), fields=[], parameters=[], result=NO_WIR_TYPE, variadic=false, abi=WirABI.White));
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

func wir_function_type(ref program: WirModule, parameters: Vector(WirTypeID), result: WirTypeID, variadic: Bool, abi: WirABI) -> WirTypeID {
    let i: Int = 0;
    while (i < program.arena.types.length()) {
        let current: WirType = program.arena.types[i];
        if (current.kind == WirTypeKind.Function && current.result == result && current.variadic == variadic && current.abi == abi && wir_type_list_equal(current.parameters, parameters)) { return WirTypeID(UInt32(i + 1)); }
        i++;
    }
    return wir_add_type(ref program, WirType(kind=WirTypeKind.Function, name="", complete=true, bits=0, element=NO_WIR_TYPE, length=UIntSize(0U), fields=[], parameters=parameters, result=result, variadic=variadic, abi=abi));
}

func new_wir_module(target: String, pointer_bits: Int) -> WirModule {
    let layout: WirDataLayout = wir_layout_for_target(target);
    if (layout.pointer_bits != pointer_bits) { layout.valid = false; }
    let program: WirModule = WirModule(target=target, pointer_bits=pointer_bits, is_shared=false, data_layout=layout, files=[], arena=new_wir_arena(), void_type=NO_WIR_TYPE, bool_type=NO_WIR_TYPE);
    program.void_type = wir_add_type(ref program, WirType(kind=WirTypeKind.VoidType, name="", complete=true, bits=0, element=NO_WIR_TYPE, length=UIntSize(0U), fields=[], parameters=[], result=NO_WIR_TYPE, variadic=false, abi=WirABI.White));
    program.bool_type = wir_add_type(ref program, WirType(kind=WirTypeKind.BoolType, name="", complete=true, bits=1, element=NO_WIR_TYPE, length=UIntSize(0U), fields=[], parameters=[], result=NO_WIR_TYPE, variadic=false, abi=WirABI.White));
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

func wir_value_type(program: WirModule, value_id: WirValueID) -> WirTypeID {
    return program.arena.values[wir_id_index(UInt32(value_id))].type_id;
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

func wir_add_constant(ref program: WirModule, value: WirConstant) -> WirValueID {
    program.arena.constants.append(value);
    let constant_id: WirConstID = WirConstID(UInt32(program.arena.constants.length()));
    return wir_add_value(ref program, WirValue(name="", type_id=value.type_id, kind=WirValueKind.Constant, owner=UInt32(constant_id), index=-1, integer=UInt128(0U), float_bits=UInt64(0)));
}

func wir_const_zero(ref program: WirModule, type_id: WirTypeID) -> WirValueID {
    return wir_add_constant(ref program, WirConstant(kind=WirConstKind.Zero, type_id=type_id, elements=[], bytes="", target=NO_WIR_VALUE, addend=0L));
}

func wir_const_aggregate(ref program: WirModule, type_id: WirTypeID, elements: Vector(WirValueID)) -> WirValueID {
    return wir_add_constant(ref program, WirConstant(kind=WirConstKind.Aggregate, type_id=type_id, elements=elements, bytes="", target=NO_WIR_VALUE, addend=0L));
}

func wir_const_bytes(ref program: WirModule, type_id: WirTypeID, bytes: String) -> WirValueID {
    return wir_add_constant(ref program, WirConstant(kind=WirConstKind.Bytes, type_id=type_id, elements=[], bytes=bytes, target=NO_WIR_VALUE, addend=0L));
}

func wir_const_address(ref program: WirModule, type_id: WirTypeID, target: WirValueID, addend: Long) -> WirValueID {
    return wir_add_constant(ref program, WirConstant(kind=WirConstKind.Address, type_id=type_id, elements=[], bytes="", target=target, addend=addend));
}

func wir_add_function(ref program: WirModule, name: String, parameters: Vector(WirParam), result: WirTypeID, variadic: Bool, linkage: WirLinkage, abi: WirABI) -> WirFuncID {
    let function_id: WirFuncID = WirFuncID(UInt32(program.arena.functions.length() + 1));
    let parameter_types: Vector(WirTypeID) = [];
    let i: Int = 0;
    while (i < parameters.length()) {
        parameter_types.append(parameters[i].type_id);
        i++;
    }
    let type_id: WirTypeID = wir_function_type(ref program, parameter_types, result, variadic, abi);
    let values: Vector(WirValueID) = [];
    i = 0;
    while (i < parameters.length()) {
        let parameter: WirValue = WirValue(name=parameters[i].name, type_id=parameters[i].type_id, kind=WirValueKind.FunctionParameter, owner=UInt32(function_id), index=i, integer=UInt128(0U), float_bits=UInt64(0));
        values.append(wir_add_value(ref program, parameter));
        i++;
    }
    let address: WirValueID = wir_add_value(ref program, WirValue(name=name, type_id=type_id, kind=WirValueKind.Function, owner=UInt32(function_id), index=-1, integer=UInt128(0U), float_bits=UInt64(0)));
    program.arena.functions.append(WirFunction(name=name, type_id=type_id, address=address, parameters=values, blocks=[], entry=NO_WIR_BLOCK, linkage=linkage, export_symbol=false, abi=abi));
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
    program.arena.instructions.append(WirInstruction(opcode=opcode, type_id=type_id, call_type=NO_WIR_TYPE, atomic_op=WirAtomicOp.None, memory_order=WirMemoryOrder.None, result=result, operands=operands, edges=edges, location=location));
    program.arena.blocks[wir_id_index(UInt32(block_id))].instructions.append(instruction_id);
    return result;
}

func wir_stack_alloc(ref program: WirModule, block: WirBlockID, type_id: WirTypeID, name: String, location: WirLocation) -> WirValueID {
    let address: WirValueID = wir_append(ref program, block, WirOpcode.StackAlloc, wir_pointer_type(ref program, type_id), [], [], location);
    let instructions: Vector(WirInstID) = program.arena.blocks[wir_id_index(UInt32(block))].instructions;
    if (instructions.length() >= 2) {
        let previous: WirInstID = instructions[instructions.length() - 2];
        let opcode: WirOpcode = program.arena.instructions[wir_id_index(UInt32(previous))].opcode;
        if (wir_is_terminator(opcode)) {
            instructions[instructions.length() - 2] = instructions[instructions.length() - 1];
            instructions[instructions.length() - 1] = previous;
        }
    }
    wir_name_value(ref program, address, name);
    return address;
}

func wir_load(ref program: WirModule, block: WirBlockID, address: WirValueID, name: String, location: WirLocation) -> WirValueID {
    let address_value: WirValue = program.arena.values[wir_id_index(UInt32(address))];
    let pointer: WirType = program.arena.types[wir_id_index(UInt32(address_value.type_id))];
    let value: WirValueID = wir_append(ref program, block, WirOpcode.Load, pointer.element, [address], [], location);
    wir_name_value(ref program, value, name);
    return value;
}

func wir_store(ref program: WirModule, block: WirBlockID, value: WirValueID, address: WirValueID, location: WirLocation) -> Void {
    wir_append(ref program, block, WirOpcode.Store, program.void_type, [value, address], [], location);
}

func wir_atomic_load(ref program: WirModule, block: WirBlockID, address: WirValueID, order: WirMemoryOrder, name: String, location: WirLocation) -> WirValueID {
    let address_value: WirValue = program.arena.values[wir_id_index(UInt32(address))];
    let pointer: WirType = program.arena.types[wir_id_index(UInt32(address_value.type_id))];
    let value: WirValueID = wir_append(ref program, block, WirOpcode.AtomicLoad, pointer.element, [address], [], location);
    program.arena.instructions[program.arena.instructions.length() - 1].memory_order = order;
    wir_name_value(ref program, value, name);
    return value;
}

func wir_atomic_store(ref program: WirModule, block: WirBlockID, value: WirValueID, address: WirValueID, order: WirMemoryOrder, location: WirLocation) -> Void {
    wir_append(ref program, block, WirOpcode.AtomicStore, program.void_type, [value, address], [], location);
    program.arena.instructions[program.arena.instructions.length() - 1].memory_order = order;
}

func wir_atomic_rmw(ref program: WirModule, block: WirBlockID, operation: WirAtomicOp, address: WirValueID, value: WirValueID, order: WirMemoryOrder, name: String, location: WirLocation) -> WirValueID {
    let result: WirValueID = wir_append(ref program, block, WirOpcode.AtomicRmw, wir_value_type(program, value), [address, value], [], location);
    let instruction_index: Int = program.arena.instructions.length() - 1;
    program.arena.instructions[instruction_index].atomic_op = operation;
    program.arena.instructions[instruction_index].memory_order = order;
    wir_name_value(ref program, result, name);
    return result;
}

func wir_field(ref program: WirModule, block: WirBlockID, aggregate: WirValueID, field: Int, name: String, location: WirLocation) -> WirValueID {
    let aggregate_type: WirType = program.arena.types[wir_id_index(UInt32(wir_value_type(program, aggregate)))];
    let field_id: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, 32), UInt128(UInt32(field)));
    let value: WirValueID = wir_append(ref program, block, WirOpcode.Field, aggregate_type.fields[field], [aggregate, field_id], [], location);
    wir_name_value(ref program, value, name);
    return value;
}

func wir_field_address(ref program: WirModule, block: WirBlockID, aggregate: WirValueID, field: Int, name: String, location: WirLocation) -> WirValueID {
    let pointer: WirType = program.arena.types[wir_id_index(UInt32(wir_value_type(program, aggregate)))];
    let aggregate_type: WirType = program.arena.types[wir_id_index(UInt32(pointer.element))];
    let field_id: WirValueID = wir_const_int(ref program, wir_unsigned_int_type(ref program, 32), UInt128(UInt32(field)));
    let result_type: WirTypeID = wir_pointer_type(ref program, aggregate_type.fields[field]);
    let value: WirValueID = wir_append(ref program, block, WirOpcode.FieldAddress, result_type, [aggregate, field_id], [], location);
    wir_name_value(ref program, value, name);
    return value;
}

func wir_index(ref program: WirModule, block: WirBlockID, aggregate: WirValueID, index: WirValueID, name: String, location: WirLocation) -> WirValueID {
    let aggregate_type: WirType = program.arena.types[wir_id_index(UInt32(wir_value_type(program, aggregate)))];
    let value: WirValueID = wir_append(ref program, block, WirOpcode.Index, aggregate_type.element, [aggregate, index], [], location);
    wir_name_value(ref program, value, name);
    return value;
}

func wir_index_address(ref program: WirModule, block: WirBlockID, aggregate: WirValueID, index: WirValueID, name: String, location: WirLocation) -> WirValueID {
    let pointer: WirType = program.arena.types[wir_id_index(UInt32(wir_value_type(program, aggregate)))];
    let element: WirTypeID = pointer.element;
    let aggregate_type: WirType = program.arena.types[wir_id_index(UInt32(element))];
    if (aggregate_type.kind == WirTypeKind.Array) { element = aggregate_type.element; }
    let result_type: WirTypeID = wir_pointer_type(ref program, element);
    let value: WirValueID = wir_append(ref program, block, WirOpcode.IndexAddress, result_type, [aggregate, index], [], location);
    wir_name_value(ref program, value, name);
    return value;
}

func wir_struct_value(ref program: WirModule, block: WirBlockID, type_id: WirTypeID, fields: Vector(WirValueID), name: String, location: WirLocation) -> WirValueID {
    let value: WirValueID = wir_append(ref program, block, WirOpcode.StructValue, type_id, fields, [], location);
    wir_name_value(ref program, value, name);
    return value;
}

func wir_array_value(ref program: WirModule, block: WirBlockID, type_id: WirTypeID, elements: Vector(WirValueID), name: String, location: WirLocation) -> WirValueID {
    let value: WirValueID = wir_append(ref program, block, WirOpcode.ArrayValue, type_id, elements, [], location);
    wir_name_value(ref program, value, name);
    return value;
}

func wir_binary(ref program: WirModule, block: WirBlockID, opcode: WirOpcode, type_id: WirTypeID, left: WirValueID, right: WirValueID, name: String, location: WirLocation) -> WirValueID {
    let value: WirValueID = wir_append(ref program, block, opcode, type_id, [left, right], [], location);
    wir_name_value(ref program, value, name);
    return value;
}

func wir_unary(ref program: WirModule, block: WirBlockID, opcode: WirOpcode, type_id: WirTypeID, operand: WirValueID, name: String, location: WirLocation) -> WirValueID {
    let value: WirValueID = wir_append(ref program, block, opcode, type_id, [operand], [], location);
    wir_name_value(ref program, value, name);
    return value;
}

func wir_call(ref program: WirModule, block: WirBlockID, function: WirValueID, arguments: Vector(WirValueID), name: String, location: WirLocation) -> WirValueID {
    let callee: WirValue = program.arena.values[wir_id_index(UInt32(function))];
    return wir_call_typed(ref program, block, function, callee.type_id, arguments, name, location);
}

func wir_call_typed(ref program: WirModule, block: WirBlockID, function: WirValueID, call_type: WirTypeID, arguments: Vector(WirValueID), name: String, location: WirLocation) -> WirValueID {
    let signature: WirType = program.arena.types[wir_id_index(UInt32(call_type))];
    let operands: Vector(WirValueID) = [function];
    let i: Int = 0;
    while (i < arguments.length()) {
        operands.append(arguments[i]);
        i++;
    }
    let value: WirValueID = wir_append(ref program, block, WirOpcode.Call, signature.result, operands, [], location);
    program.arena.instructions[program.arena.instructions.length() - 1].call_type = call_type;
    if (value != NO_WIR_VALUE) { wir_name_value(ref program, value, name); }
    return value;
}

func wir_retain(ref program: WirModule, block: WirBlockID, value: WirValueID, location: WirLocation) -> Void {
    wir_append(ref program, block, WirOpcode.Retain, program.void_type, [value], [], location);
}

func wir_release(ref program: WirModule, block: WirBlockID, value: WirValueID, location: WirLocation) -> Void {
    wir_append(ref program, block, WirOpcode.Release, program.void_type, [value], [], location);
}

func wir_cast_opcode(program: WirModule, source_id: WirTypeID, target_id: WirTypeID) -> WirOpcode {
    let source: WirType = program.arena.types[wir_id_index(UInt32(source_id))];
    let target: WirType = program.arena.types[wir_id_index(UInt32(target_id))];
    let source_integer: Bool = source.kind == WirTypeKind.BoolType || source.kind == WirTypeKind.SignedInt || source.kind == WirTypeKind.UnsignedInt;
    let target_integer: Bool = target.kind == WirTypeKind.BoolType || target.kind == WirTypeKind.SignedInt || target.kind == WirTypeKind.UnsignedInt;

    if (source_integer && target_integer) {
        if (source.bits > target.bits) { return WirOpcode.Truncate; }
        if (source.bits < target.bits && source.kind == WirTypeKind.SignedInt) { return WirOpcode.SignExtend; }
        if (source.bits < target.bits) { return WirOpcode.ZeroExtend; }
        return WirOpcode.Bitcast;
    }
    if (source.kind == WirTypeKind.FloatType && target.kind == WirTypeKind.FloatType) {
        if (source.bits < target.bits) { return WirOpcode.FloatExtend; }
        if (source.bits > target.bits) { return WirOpcode.FloatTruncate; }
        return WirOpcode.Bitcast;
    }
    if (source_integer && target.kind == WirTypeKind.FloatType) {
        if (source.kind == WirTypeKind.SignedInt) { return WirOpcode.SignedIntToFloat; }
        return WirOpcode.UnsignedIntToFloat;
    }
    if (source.kind == WirTypeKind.FloatType && target_integer) {
        if (target.kind == WirTypeKind.SignedInt) { return WirOpcode.FloatToSignedInt; }
        return WirOpcode.FloatToUnsignedInt;
    }
    if (source.kind == WirTypeKind.Pointer && target.kind == WirTypeKind.Pointer) { return WirOpcode.Bitcast; }
    if (source.kind == WirTypeKind.Pointer && target_integer) { return WirOpcode.PointerToInt; }
    if (source_integer && target.kind == WirTypeKind.Pointer) { return WirOpcode.IntToPointer; }
    return WirOpcode.Invalid;
}

func wir_cast(ref program: WirModule, block: WirBlockID, value: WirValueID, type_id: WirTypeID, name: String, location: WirLocation) -> WirValueID {
    let source_id: WirTypeID = wir_value_type(program, value);
    if (source_id == type_id) { return value; }
    let opcode: WirOpcode = wir_cast_opcode(program, source_id, type_id);
    let result: WirValueID = wir_append(ref program, block, opcode, type_id, [value], [], location);
    wir_name_value(ref program, result, name);
    return result;
}

func wir_pointer_offset(ref program: WirModule, block: WirBlockID, pointer: WirValueID, offset: Int, target_type: WirTypeID) -> WirValueID {
    let size_type: WirTypeID = wir_unsigned_int_type(ref program, program.pointer_bits);
    let address: WirValueID = wir_cast(ref program, block, pointer, size_type, "", no_wir_location());
    let encoded: UInt128 = UInt128(0U);
    if (offset < 0) {
        let limit: UInt128 = UInt128(1U) << UInt128(program.pointer_bits);
        encoded = limit - UInt128(-offset);
    } else {
        encoded = UInt128(offset);
    }
    let amount: WirValueID = wir_const_int(ref program, size_type, encoded);
    let adjusted: WirValueID = wir_binary(ref program, block, WirOpcode.Add, size_type, address, amount, "", no_wir_location());
    return wir_cast(ref program, block, adjusted, target_type, "", no_wir_location());
}

func wir_module_uses_opcode(program: WirModule, opcode: WirOpcode) -> Bool {
    let i: Int = 0;
    while (i < program.arena.instructions.length()) {
        if (program.arena.instructions[i].opcode == opcode) { return true; }
        i++;
    }
    return false;
}

func wir_return(ref program: WirModule, block: WirBlockID, value: WirValueID, location: WirLocation) -> Void {
    let operands: Vector(WirValueID) = [];
    if (value != NO_WIR_VALUE) { operands.append(value); }
    wir_append(ref program, block, WirOpcode.Return, program.void_type, operands, [], location);
}

func wir_trap(ref program: WirModule, block: WirBlockID, location: WirLocation) -> Void {
    wir_append(ref program, block, WirOpcode.Trap, program.void_type, [], [], location);
}

func wir_add_global(ref program: WirModule, name: String, type_id: WirTypeID, initializer: WirValueID, linkage: WirLinkage, is_const: Bool) -> WirGlobalID {
    return wir_add_aligned_global(ref program, name, type_id, initializer, linkage, is_const, 0);
}

func wir_add_aligned_global(ref program: WirModule, name: String, type_id: WirTypeID, initializer: WirValueID, linkage: WirLinkage, is_const: Bool, alignment: Int) -> WirGlobalID {
    let global_id: WirGlobalID = WirGlobalID(UInt32(program.arena.globals.length() + 1));
    let pointer_type: WirTypeID = wir_pointer_type(ref program, type_id);
    let address: WirValueID = wir_add_value(ref program, WirValue(name=name, type_id=pointer_type, kind=WirValueKind.Global, owner=UInt32(global_id), index=-1, integer=UInt128(0U), float_bits=UInt64(0)));
    program.arena.globals.append(WirGlobal(name=name, type_id=type_id, address=address, initializer=initializer, linkage=linkage, export_symbol=false, is_const=is_const, alignment=alignment));
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
