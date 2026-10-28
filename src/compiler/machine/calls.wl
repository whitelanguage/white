// src/compiler/machine/calls.wl
import * from "../wir/model.wl"


func machine_call_signature(ref program: WirModule, instruction: WirInstruction) -> WirType {
// the declared varargs signature describes the fixed prefix, frame planning needs every operand.
    let signature = program.arena.types[wir_id_index(UInt32(instruction.call_type))];
    if (!signature.variadic) { return signature; }
    let params: Vector(WirTypeID) = [];
    let i = 1;
    while (i < instruction.operands.length()) {
        params.append(program.arena.values[wir_id_index(UInt32(instruction.operands[i]))].type_id);
        i++;
    }
    signature.parameters = params;
    return signature;
}
