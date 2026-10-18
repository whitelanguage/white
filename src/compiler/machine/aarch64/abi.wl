// src/compiler/machine/aarch64/abi.wl
import A64Register from "model.wl"
import * from "../../wir/model.wl"
import a64_scalar_float from "fp.wl"
import * from "types.wl"


func a64_argument_register(index: Int, floating: Bool) -> A64Register {
// AAPCS64 has independent banks for the first eight integer and FP arguments.
    if (index < 0 || index > 7) {
        return A64Register.None;
    }

    if floating {
        if (index == 0) { return A64Register.V0; }
        if (index == 1) { return A64Register.V1; }
        if (index == 2) { return A64Register.V2; }
        if (index == 3) { return A64Register.V3; }
        if (index == 4) { return A64Register.V4; }
        if (index == 5) { return A64Register.V5; }
        if (index == 6) { return A64Register.V6; }

        return A64Register.V7;
    }

    if (index == 0) { return A64Register.X0; }
    if (index == 1) { return A64Register.X1; }
    if (index == 2) { return A64Register.X2; }
    if (index == 3) { return A64Register.X3; }
    if (index == 4) { return A64Register.X4; }
    if (index == 5) { return A64Register.X5; }
    if (index == 6) { return A64Register.X6; }

    return A64Register.X7;
}

func a64_pair_argument_index(index: Int) -> Int {
// AAPCS64 gives 16-byte integral arguments an even-numbered register pair.
    if (index < 0) {
        return -1;
    }

    let first: Int = index;
    if ((first & 1) != 0) {
        first++;
    }
    if (first > 6) {
        return -1;
    }

    return first;
}

func a64_result_register(floating: Bool) -> A64Register {
    if floating { return A64Register.V0; }

    return A64Register.X0;
}

func a64_indirect_result_register() -> A64Register {
// Unlike an ordinary argument, an indirect result pointer is passed in X8.
    return A64Register.X8;
}

func a64_stack_argument_offset(index: Int) -> Int {
    if (index < 8) { return -1; }

    return (index - 8) * 8;
}

func a64_call_frame(argument_count: Int) -> Int {
    let bytes: Int = 0;

    if (argument_count > 8) {
        bytes = (argument_count - 8) * 8;
    }

    return (bytes + 15) & -16;
}

struct A64HFA(
    valid: Bool,
    bits: Int,
    count: Int
)

struct A64ArgumentState(integer: Int, floating: Int, stack: Int)

struct A64ArgumentLocation(
    valid: Bool,
    on_stack: Bool,
    offset: Int,
    first: Int,
    count: Int,
    floating: Bool,
    indirect: Bool
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

func a64_stack_argument(ref state: A64ArgumentState, size: Int, alignment: Int, indirect: Bool) -> A64ArgumentLocation {
    let aligned: Int = alignment;
    if (aligned < 8) { aligned = 8; }
    if (aligned > 16) { aligned = 16; }
    state.stack = a64_align(state.stack, aligned);

    let offset: Int = state.stack;
    let bytes: Int = size;
    if (bytes < 8) { bytes = 8; }
    state.stack += a64_align(bytes, 8);

    return A64ArgumentLocation(valid=true, on_stack=true, offset=offset, first=-1, count=0, floating=false, indirect=indirect);
}

func a64_argument_location(
    ref program: WirModule,
    type_id: WirTypeID,
    layouts: Vector(WirTypeLayout),
    ref state: A64ArgumentState
) -> A64ArgumentLocation {
// Keep this classifier shared by the caller, callee and outgoing-frame scan.
// Small changes to one side of AAPCS64 otherwise tend to produce valid objects
// which only fail after the first call with more than eight arguments.
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length() || index >= layouts.length()) {
        return A64ArgumentLocation(valid=false, on_stack=false, offset=-1, first=-1, count=0, floating=false, indirect=false);
    }

    let ptr type: WirType = ref program.arena.types[index];
    let layout: WirTypeLayout = layouts[index];
    if (type.kind == WirTypeKind.Struct || type.kind == WirTypeKind.Array) {
        if (!layout.valid || layout.size == 0UL || layout.size > 2147483647UL) {
            return A64ArgumentLocation(valid=false, on_stack=false, offset=-1, first=-1, count=0, floating=false, indirect=false);
        }

        let hfa: A64HFA = a64_hfa_type(ref program, type_id, layouts);
        if (hfa.valid) {
            if (state.floating + hfa.count <= 8) {
                let first: Int = state.floating;
                state.floating += hfa.count;
                return A64ArgumentLocation(valid=true, on_stack=false, offset=-1, first=first, count=hfa.count, floating=true, indirect=false);
            }
            state.floating = 8;
            return a64_stack_argument(ref state, Int(layout.size), layout.alignment, false);
        }

        let count: Int = a64_aggregate_register_count(layout);
        if (count != 0) {
            let first: Int = a64_align_aggregate_argument(state.integer, layout);
            if (first + count <= 8) {
                state.integer = first + count;
                return A64ArgumentLocation(valid=true, on_stack=false, offset=-1, first=first, count=count, floating=false, indirect=false);
            }
            state.integer = 8;
            return a64_stack_argument(ref state, Int(layout.size), layout.alignment, false);
        }

        if (state.integer < 8) {
            let first: Int = state.integer;
            state.integer++;
            return A64ArgumentLocation(valid=true, on_stack=false, offset=-1, first=first, count=1, floating=false, indirect=true);
        }
        return a64_stack_argument(ref state, 8, 8, true);
    }

    let width: Int = a64_integer_width(ref program, type_id);
    if (width == 128) {
        let first: Int = state.integer;
        if ((first & 1) != 0) { first++; }
        if (first + 2 <= 8) {
            state.integer = first + 2;
            return A64ArgumentLocation(valid=true, on_stack=false, offset=-1, first=first, count=2, floating=false, indirect=false);
        }
        state.integer = 8;
        return a64_stack_argument(ref state, 16, 16, false);
    }

    let floating: Bool = a64_scalar_float(ref program, type_id);
    let scalar: Int = a64_scalar_width(ref program, type_id);
    if (scalar == 0) {
        return A64ArgumentLocation(valid=false, on_stack=false, offset=-1, first=-1, count=0, floating=false, indirect=false);
    }

    if floating {
        if (state.floating < 8) {
            let first: Int = state.floating;
            state.floating++;
            return A64ArgumentLocation(valid=true, on_stack=false, offset=-1, first=first, count=1, floating=true, indirect=false);
        }
        return a64_stack_argument(ref state, scalar / 8, scalar / 8, false);
    }

    if (state.integer < 8) {
        let first: Int = state.integer;
        state.integer++;
        return A64ArgumentLocation(valid=true, on_stack=false, offset=-1, first=first, count=1, floating=false, indirect=false);
    }
    return a64_stack_argument(ref state, scalar / 8, scalar / 8, false);
}

func a64_aggregate_register_count(layout: WirTypeLayout) -> Int {
    if (!layout.valid || layout.size == 0UL || layout.size > 16UL) {
        return 0;
    }

    return (Int(layout.size) + 7) / 8;
}

func a64_align_aggregate_argument(index: Int, layout: WirTypeLayout) -> Int {
    if (layout.alignment >= 16 && index % 2 != 0) {
        return index + 1;
    }
    return index;
}
