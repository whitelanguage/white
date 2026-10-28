// src/compiler/abi/aapcs64.wl
import * from "../wir/model.wl"


struct A64HFA(
    valid: Bool,
    bits: Int,
    count: Int
)

func a64_hfa_type(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout)) -> A64HFA {
// AAPCS64 gives homogeneous float aggregates their own V-register path. Keep
// this test on WIR layouts, source structs may already have been flattened.
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length() || index >= layouts.length()) {
        return A64HFA(valid=false, bits=0, count=0);
    }

    let ptr type: WirType = ref program.arena.types[index];
    if (type.kind == WirTypeKind.FloatType && (type.bits == 32 || type.bits == 64)) {
        return A64HFA(valid=true, bits=type.bits, count=1);
    }

    if ((type.kind != WirTypeKind.Struct && type.kind != WirTypeKind.Array) ||
        !layouts[index].valid) {
        return A64HFA(valid=false, bits=0, count=0);
    }

    let bits: Int = 0;
    let count: Int = 0;
    if (type.kind == WirTypeKind.Array) {
        let element: A64HFA = a64_hfa_type(ref program, type.element, layouts);
        if (!element.valid || type.length == UIntSize(0) || type.length > UIntSize(4)) {
            return A64HFA(valid=false, bits=0, count=0);
        }

        bits = element.bits;
        count = element.count * Int(type.length);
    } else {
        let i: Int = 0;
        while (i < type.fields.length()) {
            let field: A64HFA = a64_hfa_type(ref program, type.fields[i], layouts);
            if (!field.valid || (bits != 0 && bits != field.bits)) {
                return A64HFA(valid=false, bits=0, count=0);
            }

            bits = field.bits;
            count += field.count;
            i++;
        }
    }

    let bytes: Int = bits / 8;
    if (bits == 0 || count < 1 || count > 4 ||
        layouts[index].size != UInt64(bytes * count)) {
        return A64HFA(valid=false, bits=0, count=0);
    }

    return A64HFA(valid=true, bits=bits, count=count);
}
