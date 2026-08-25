// compiler/wir/layout.wl

import * from "model.wl"

func wir_invalid_data_layout() -> WirDataLayout {
    return WirDataLayout(valid=false, little_endian=true, pointer_bits=0, pointer_alignment=0, i64_alignment=0, i128_alignment=0, f64_alignment=0, stack_alignment=0);
}

func wir_layout_for_target(target: String) -> WirDataLayout {
    if (target == "i686-pc-windows-msvc") {
        return WirDataLayout(valid=true, little_endian=true, pointer_bits=32, pointer_alignment=4, i64_alignment=8, i128_alignment=16, f64_alignment=8, stack_alignment=4);
    }
    if (target == "i686-unknown-linux-gnu") {
        return WirDataLayout(valid=true, little_endian=true, pointer_bits=32, pointer_alignment=4, i64_alignment=4, i128_alignment=16, f64_alignment=4, stack_alignment=16);
    }
    if (target == "armv7-unknown-linux-gnueabihf") {
        return WirDataLayout(valid=true, little_endian=true, pointer_bits=32, pointer_alignment=4, i64_alignment=8, i128_alignment=8, f64_alignment=8, stack_alignment=8);
    }
    if (target == "x86_64-pc-windows-msvc" || target == "x86_64-unknown-linux-gnu" ||
        target == "aarch64-unknown-linux-gnu" || target == "x86_64-apple-darwin" ||
        target == "arm64-apple-darwin" || target == "aarch64-apple-darwin") {
        return WirDataLayout(valid=true, little_endian=true, pointer_bits=64, pointer_alignment=8, i64_alignment=8, i128_alignment=16, f64_alignment=8, stack_alignment=16);
    }
    return wir_invalid_data_layout();
}

func wir_invalid_type_layout() -> WirTypeLayout {
    return WirTypeLayout(valid=false, size=0UL, alignment=0, field_offsets=[]);
}

func wir_align_size(value: UInt128, alignment: Int) -> UInt128 {
    if (alignment <= 1) { return value; }
    let step: UInt128 = UInt128(alignment);
    let remainder: UInt128 = value % step;
    if (remainder == UInt128(0U)) { return value; }
    return value + step - remainder;
}

func wir_max_object_size(layout: WirDataLayout) -> UInt128 {
    if (layout.pointer_bits != 32 && layout.pointer_bits != 64) { return UInt128(0U); }
    return (UInt128(1U) << UInt128(layout.pointer_bits)) - UInt128(1U);
}

func wir_scalar_layout(program: WirModule, type: WirType) -> WirTypeLayout {
    if (type.kind == WirTypeKind.BoolType) { return WirTypeLayout(valid=true, size=1UL, alignment=1, field_offsets=[]); }
    if (type.kind == WirTypeKind.Pointer || type.kind == WirTypeKind.Function) {
        return WirTypeLayout(valid=true, size=UInt64(program.data_layout.pointer_bits / 8), alignment=program.data_layout.pointer_alignment, field_offsets=[]);
    }
    if (type.kind == WirTypeKind.FloatType) {
        if (type.bits == 32) { return WirTypeLayout(valid=true, size=4UL, alignment=4, field_offsets=[]); }
        if (type.bits == 64) { return WirTypeLayout(valid=true, size=8UL, alignment=program.data_layout.f64_alignment, field_offsets=[]); }
        return wir_invalid_type_layout();
    }
    if (type.kind != WirTypeKind.SignedInt && type.kind != WirTypeKind.UnsignedInt) { return wir_invalid_type_layout(); }
    if (type.bits <= 0 || type.bits > 128) { return wir_invalid_type_layout(); }
    if (type.bits <= 8) { return WirTypeLayout(valid=true, size=1UL, alignment=1, field_offsets=[]); }
    if (type.bits <= 16) { return WirTypeLayout(valid=true, size=2UL, alignment=2, field_offsets=[]); }
    if (type.bits <= 32) { return WirTypeLayout(valid=true, size=4UL, alignment=4, field_offsets=[]); }
    if (type.bits <= 64) { return WirTypeLayout(valid=true, size=8UL, alignment=program.data_layout.i64_alignment, field_offsets=[]); }
    return WirTypeLayout(valid=true, size=16UL, alignment=program.data_layout.i128_alignment, field_offsets=[]);
}

func wir_layout_type(program: WirModule, type_id: WirTypeID, states: Vector(Int), cache: Vector(WirTypeLayout)) -> WirTypeLayout {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length() || !program.data_layout.valid) { return wir_invalid_type_layout(); }
    if (states[index] == 2) { return cache[index]; }
    if (states[index] == 1) { return wir_invalid_type_layout(); }
    states[index] = 1;

    let type: WirType = program.arena.types[index];
    let result: WirTypeLayout = wir_scalar_layout(program, type);
    if (type.kind == WirTypeKind.Array) {
        let element: WirTypeLayout = wir_layout_type(program, type.element, states, cache);
        if (element.valid) {
            let size: UInt128 = UInt128(element.size) * UInt128(type.length);
            if (size <= wir_max_object_size(program.data_layout)) {
                result = WirTypeLayout(valid=true, size=UInt64(size), alignment=element.alignment, field_offsets=[]);
            }
        }
    } else if (type.kind == WirTypeKind.Struct && type.complete) {
        let offsets: Vector(UInt64) = [];
        let size: UInt128 = UInt128(0U);
        let alignment: Int = 1;
        let valid: Bool = true;
        let i: Int = 0;
        while (i < type.fields.length()) {
            let field: WirTypeLayout = wir_layout_type(program, type.fields[i], states, cache);
            if (!field.valid) { valid = false; break; }
            size = wir_align_size(size, field.alignment);
            if (size > wir_max_object_size(program.data_layout)) { valid = false; break; }
            offsets.append(UInt64(size));
            size += UInt128(field.size);
            if (field.alignment > alignment) { alignment = field.alignment; }
            i++;
        }
        if (valid) {
            size = wir_align_size(size, alignment);
            if (size <= wir_max_object_size(program.data_layout)) {
                result = WirTypeLayout(valid=true, size=UInt64(size), alignment=alignment, field_offsets=offsets);
            }
        }
    }

    cache[index] = result;
    states[index] = 2;
    return result;
}

func wir_type_layout(program: WirModule, type_id: WirTypeID) -> WirTypeLayout {
    let states: Vector(Int) = [];
    let cache: Vector(WirTypeLayout) = [];
    let i: Int = 0;
    while (i < program.arena.types.length()) {
        states.append(0);
        cache.append(wir_invalid_type_layout());
        i++;
    }
    return wir_layout_type(program, type_id, states, cache);
}

func wir_type_size(program: WirModule, type_id: WirTypeID) -> UInt64 {
    return wir_type_layout(program, type_id).size;
}

func wir_type_alignment(program: WirModule, type_id: WirTypeID) -> Int {
    return wir_type_layout(program, type_id).alignment;
}
