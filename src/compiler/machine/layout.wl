// src/compiler/machine/layout.wl
import * from "../wir/model.wl"
import wir_layout_for_target from "../wir/layout.wl"


func machine_layout_valid(program: WirModule) -> Bool {
// encoders use native offsets and loads, a mismatched layout cannot be corrected during emission
    let expected = wir_layout_for_target(program.target);
    let actual = program.data_layout;
    return expected.valid && actual.valid && program.pointer_bits == expected.pointer_bits &&
           actual.little_endian == expected.little_endian && actual.pointer_bits == expected.pointer_bits &&
           actual.pointer_alignment == expected.pointer_alignment && actual.i64_alignment == expected.i64_alignment &&
           actual.i128_alignment == expected.i128_alignment && actual.f64_alignment == expected.f64_alignment &&
           actual.stack_alignment == expected.stack_alignment;
}
