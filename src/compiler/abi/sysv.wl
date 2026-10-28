// src/compiler/abi/sysv.wl
import * from "../wir/model.wl"


enum X86SysVClass {
    Empty,
    Integer,
    SSE,
    Memory
}

struct X86SysVTypeClass(
    first: X86SysVClass,
    second: X86SysVClass,
    count: Int,
    size: Int,
    alignment: Int,
    memory: Bool
)

func x86_sysv_merge_class(left: X86SysVClass, right: X86SysVClass) -> X86SysVClass {
    if (left == right || right == X86SysVClass.Empty) { return left; }
    if (left == X86SysVClass.Empty) { return right; }
    if (left == X86SysVClass.Memory || right == X86SysVClass.Memory) {
        return X86SysVClass.Memory;
    }

    if (left == X86SysVClass.Integer || right == X86SysVClass.Integer) {
        return X86SysVClass.Integer;
    }

    return X86SysVClass.SSE;
}

func x86_sysv_merge_range(ref first: X86SysVClass, ref second: X86SysVClass, offset: Int, size: Int, abi_class: X86SysVClass) -> Bool {
// merge one field into the two eightbytes used by the SysV classifier
    if (offset < 0 || size < 0 || offset + size > 16) { return false; }
    if (size == 0) { return true; }

    let first_slot: Int = offset / 8;
    let last_slot: Int = (offset + size - 1) / 8;
    let slot: Int = first_slot;

    while (slot <= last_slot) {
        if (slot == 0) {
            first = x86_sysv_merge_class(first, abi_class);
        } else if (slot == 1) {
            second = x86_sysv_merge_class(second, abi_class);
        } else {
            return false;
        }
        slot++;
    }

    return first != X86SysVClass.Memory && second != X86SysVClass.Memory;
}

func x86_sysv_classify_at(
    ref program: WirModule,
    type_id: WirTypeID,
    layouts: Vector(WirTypeLayout),
    offset: Int,
    ref first: X86SysVClass,
    ref second: X86SysVClass
) -> Bool {
// classify against the final layout, padding belongs to neither class and each
// field may change the class of either eightbyte it overlaps.
    let index: Int = wir_id_index(UInt32(type_id));

    if (index < 0 || index >= program.arena.types.length() || index >= layouts.length()) {
        return false;
    }

    let type: WirType = program.arena.types[index];
    let layout: WirTypeLayout = layouts[index];

    if (!layout.valid || layout.size > 16UL || offset > 16 - Int(layout.size)) {
        return false;
    }

    if (type.kind == WirTypeKind.FloatType) {
        return x86_sysv_merge_range(ref first, ref second, offset, Int(layout.size), X86SysVClass.SSE);
    }

    if (type.kind == WirTypeKind.BoolType || type.kind == WirTypeKind.SignedInt ||
        type.kind == WirTypeKind.UnsignedInt || type.kind == WirTypeKind.Pointer ||
        type.kind == WirTypeKind.Function) {
        return x86_sysv_merge_range(ref first, ref second, offset, Int(layout.size), X86SysVClass.Integer);
    }

    if (type.kind == WirTypeKind.Array) {
        let element_index: Int = wir_id_index(UInt32(type.element));

        if (element_index < 0 || element_index >= layouts.length()) { return false; }

        let element: WirTypeLayout = layouts[element_index];

        if (!element.valid || element.size == 0UL) { return type.length == UIntSize(0); }

        let i: UIntSize = UIntSize(0);

        while (i < type.length) {
            if (!x86_sysv_classify_at(ref program, type.element, layouts, offset + Int(UInt64(i) * element.size), ref first, ref second)) {
                return false;
            }
            i++;
        }

        return true;
    }

    if (type.kind != WirTypeKind.Struct || !type.complete || layout.field_offsets.length() != type.fields.length()) {
        return false;
    }

    let i: Int = 0;

    while (i < type.fields.length()) {
        let field_index: Int = wir_id_index(UInt32(type.fields[i]));

        if (field_index < 0 || field_index >= layouts.length()) { return false; }

        let field: WirTypeLayout = layouts[field_index];
        let field_offset: Int = Int(layout.field_offsets[i]);

        if (!field.valid || field.alignment <= 0 || field_offset % field.alignment != 0) {
            return false;
        }

        if (!x86_sysv_classify_at(ref program, type.fields[i], layouts, offset + field_offset, ref first, ref second)) {
            return false;
        }
        i++;
    }

    return true;
}

func x86_sysv_classify(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout)) -> X86SysVTypeClass {
// the AMD64 ABI splits values up to sixteen bytes into two eightbytes. Larger
// values, invalid layouts and layouts we cannot describe safely use MEMORY.
    let index: Int = wir_id_index(UInt32(type_id));

    if (index < 0 || index >= layouts.length()) {
        return X86SysVTypeClass(first=X86SysVClass.Memory, second=X86SysVClass.Memory, count=0, size=0, alignment=1, memory=true);
    }

    let layout: WirTypeLayout = layouts[index];

    if (!layout.valid || layout.size > 16UL) {
        return X86SysVTypeClass(first=X86SysVClass.Memory, second=X86SysVClass.Memory, count=0, size=Int(layout.size), alignment=layout.alignment, memory=true);
    }

    let first: X86SysVClass = X86SysVClass.Empty;
    let second: X86SysVClass = X86SysVClass.Empty;

    if (!x86_sysv_classify_at(ref program, type_id, layouts, 0, ref first, ref second)) {
        return X86SysVTypeClass(first=X86SysVClass.Memory, second=X86SysVClass.Memory, count=0, size=Int(layout.size), alignment=layout.alignment, memory=true);
    }

    let count: Int = 0;

    if (layout.size > 0UL) { count = 1; }
    if (layout.size > 8UL) { count = 2; }

    return X86SysVTypeClass(first=first, second=second, count=count, size=Int(layout.size), alignment=layout.alignment, memory=false);
}

func x86_sysv_class_count(type: X86SysVTypeClass, abi_class: X86SysVClass) -> Int {
    let count: Int = 0;

    if (type.count > 0 && type.first == abi_class) { count++; }
    if (type.count > 1 && type.second == abi_class) { count++; }

    return count;
}
