// src/compiler/machine/allocator.wl
import * from "../wir/model.wl"


func machine_rematerializable(ref program: WirModule, value: WirValueID) -> Bool {
// constants and addresses can be rebuilt, evicting them avoids spilling a computed value
    let index = wir_id_index(UInt32(value));
    if (index < 0 || index >= program.arena.values.length()) { return false; }

    let kind = program.arena.values[index].kind;
    if (kind == WirValueKind.Constant) {
        let owner = wir_id_index(program.arena.values[index].owner);
        if (owner < 0 || owner >= program.arena.constants.length()) { return false; }

        let ptr constant: WirConstant = ref program.arena.constants[owner];
        return constant.kind == WirConstKind.Zero || constant.kind == WirConstKind.Address;
    }

    if (kind == WirValueKind.Instruction) {
        let owner = wir_id_index(program.arena.values[index].owner);
        return owner >= 0 && owner < program.arena.instructions.length() && program.arena.instructions[owner].opcode == WirOpcode.StackAlloc;
    }

    return kind == WirValueKind.Integer || kind == WirValueKind.FloatValue || kind == WirValueKind.BoolValue ||
           kind == WirValueKind.Null || kind == WirValueKind.Global || kind == WirValueKind.Function;
}
