// tests/fixtures/native_fragments.wl
struct Bytes1(values: Byte[1])
struct Bytes2(values: Byte[2])
struct Bytes3(values: Byte[3])
struct Bytes4(values: Byte[4])
struct Bytes5(values: Byte[5])
struct Bytes6(values: Byte[6])
struct Bytes7(values: Byte[7])
struct Bytes8(values: Byte[8])
struct Bytes9(values: Byte[9])
struct Bytes10(values: Byte[10])
struct Bytes11(values: Byte[11])
struct Bytes12(values: Byte[12])
struct Bytes13(values: Byte[13])
struct Bytes14(values: Byte[14])
struct Bytes15(values: Byte[15])
struct Bytes16(values: Byte[16])
struct Bytes80(values: Byte[80])

extern "C" {
    func native_bytes1(value: Bytes1) -> Bytes1;
    func native_bytes2(value: Bytes2) -> Bytes2;
    func native_bytes3(value: Bytes3) -> Bytes3;
    func native_bytes4(value: Bytes4) -> Bytes4;
    func native_bytes5(value: Bytes5) -> Bytes5;
    func native_bytes6(value: Bytes6) -> Bytes6;
    func native_bytes7(value: Bytes7) -> Bytes7;
    func native_bytes8(value: Bytes8) -> Bytes8;
    func native_bytes9(value: Bytes9) -> Bytes9;
    func native_bytes10(value: Bytes10) -> Bytes10;
    func native_bytes11(value: Bytes11) -> Bytes11;
    func native_bytes12(value: Bytes12) -> Bytes12;
    func native_bytes13(value: Bytes13) -> Bytes13;
    func native_bytes14(value: Bytes14) -> Bytes14;
    func native_bytes15(value: Bytes15) -> Bytes15;
    func native_bytes16(value: Bytes16) -> Bytes16;
    func native_bytes80(value: Bytes80) -> Bytes80;
    func native_after_bulk(a: Int, b: Int, c: Int, value: Bytes80, d: Int, e: Int) -> Int;
    func native_fragment_exports() -> Int;
}

@ExportLib
func exported_bytes1(value: Bytes1) -> Bytes1 { return value; }
@ExportLib
func exported_bytes2(value: Bytes2) -> Bytes2 { return value; }
@ExportLib
func exported_bytes3(value: Bytes3) -> Bytes3 { return value; }
@ExportLib
func exported_bytes4(value: Bytes4) -> Bytes4 { return value; }
@ExportLib
func exported_bytes5(value: Bytes5) -> Bytes5 { return value; }
@ExportLib
func exported_bytes6(value: Bytes6) -> Bytes6 { return value; }
@ExportLib
func exported_bytes7(value: Bytes7) -> Bytes7 { return value; }
@ExportLib
func exported_bytes8(value: Bytes8) -> Bytes8 { return value; }
@ExportLib
func exported_bytes9(value: Bytes9) -> Bytes9 { return value; }
@ExportLib
func exported_bytes10(value: Bytes10) -> Bytes10 { return value; }
@ExportLib
func exported_bytes11(value: Bytes11) -> Bytes11 { return value; }
@ExportLib
func exported_bytes12(value: Bytes12) -> Bytes12 { return value; }
@ExportLib
func exported_bytes13(value: Bytes13) -> Bytes13 { return value; }
@ExportLib
func exported_bytes14(value: Bytes14) -> Bytes14 { return value; }
@ExportLib
func exported_bytes15(value: Bytes15) -> Bytes15 { return value; }
@ExportLib
func exported_bytes16(value: Bytes16) -> Bytes16 { return value; }
@ExportLib
func exported_bytes80(value: Bytes80) -> Bytes80 { return value; }

@ExportLib
func exported_after_bulk(a: Int, b: Int, c: Int, value: Bytes80, d: Int, e: Int) -> Int {
    return a + b + c + Int(value.values[79]) + d + e;
}

func main() -> Int {
    let a1: Byte[1] = [Byte(1)];
    let v1 = Bytes1(a1);
    let r1 = native_bytes1(v1);
    if (r1.values[0] != Byte(101) || r1.values[0] != Byte(101) || v1.values[0] != Byte(1)) { return 1; }
    let a2: Byte[2] = [Byte(1), Byte(2)];
    let v2 = Bytes2(a2);
    let r2 = native_bytes2(v2);
    if (r2.values[0] != Byte(101) || r2.values[1] != Byte(2) || v2.values[0] != Byte(1)) { return 2; }
    let a3: Byte[3] = [Byte(1), Byte(2), Byte(3)];
    let v3 = Bytes3(a3);
    let r3 = native_bytes3(v3);
    if (r3.values[0] != Byte(101) || r3.values[2] != Byte(3) || v3.values[0] != Byte(1)) { return 3; }
    let a4: Byte[4] = [Byte(1), Byte(2), Byte(3), Byte(4)];
    let v4 = Bytes4(a4);
    let r4 = native_bytes4(v4);
    if (r4.values[0] != Byte(101) || r4.values[3] != Byte(4) || v4.values[0] != Byte(1)) { return 4; }
    let a5: Byte[5] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5)];
    let v5 = Bytes5(a5);
    let r5 = native_bytes5(v5);
    if (r5.values[0] != Byte(101) || r5.values[4] != Byte(5) || v5.values[0] != Byte(1)) { return 5; }
    let a6: Byte[6] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6)];
    let v6 = Bytes6(a6);
    let r6 = native_bytes6(v6);
    if (r6.values[0] != Byte(101) || r6.values[5] != Byte(6) || v6.values[0] != Byte(1)) { return 6; }
    let a7: Byte[7] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7)];
    let v7 = Bytes7(a7);
    let r7 = native_bytes7(v7);
    if (r7.values[0] != Byte(101) || r7.values[6] != Byte(7) || v7.values[0] != Byte(1)) { return 7; }
    let a8: Byte[8] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8)];
    let v8 = Bytes8(a8);
    let r8 = native_bytes8(v8);
    if (r8.values[0] != Byte(101) || r8.values[7] != Byte(8) || v8.values[0] != Byte(1)) { return 8; }
    let a9: Byte[9] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8), Byte(9)];
    let v9 = Bytes9(a9);
    let r9 = native_bytes9(v9);
    if (r9.values[0] != Byte(101) || r9.values[8] != Byte(9) || v9.values[0] != Byte(1)) { return 9; }
    let a10: Byte[10] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8), Byte(9), Byte(10)];
    let v10 = Bytes10(a10);
    let r10 = native_bytes10(v10);
    if (r10.values[0] != Byte(101) || r10.values[9] != Byte(10) || v10.values[0] != Byte(1)) { return 10; }
    let a11: Byte[11] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8), Byte(9), Byte(10), Byte(11)];
    let v11 = Bytes11(a11);
    let r11 = native_bytes11(v11);
    if (r11.values[0] != Byte(101) || r11.values[10] != Byte(11) || v11.values[0] != Byte(1)) { return 11; }
    let a12: Byte[12] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8), Byte(9), Byte(10), Byte(11), Byte(12)];
    let v12 = Bytes12(a12);
    let r12 = native_bytes12(v12);
    if (r12.values[0] != Byte(101) || r12.values[11] != Byte(12) || v12.values[0] != Byte(1)) { return 12; }
    let a13: Byte[13] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8), Byte(9), Byte(10), Byte(11), Byte(12), Byte(13)];
    let v13 = Bytes13(a13);
    let r13 = native_bytes13(v13);
    if (r13.values[0] != Byte(101) || r13.values[12] != Byte(13) || v13.values[0] != Byte(1)) { return 13; }
    let a14: Byte[14] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8), Byte(9), Byte(10), Byte(11), Byte(12), Byte(13), Byte(14)];
    let v14 = Bytes14(a14);
    let r14 = native_bytes14(v14);
    if (r14.values[0] != Byte(101) || r14.values[13] != Byte(14) || v14.values[0] != Byte(1)) { return 14; }
    let a15: Byte[15] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8), Byte(9), Byte(10), Byte(11), Byte(12), Byte(13), Byte(14), Byte(15)];
    let v15 = Bytes15(a15);
    let r15 = native_bytes15(v15);
    if (r15.values[0] != Byte(101) || r15.values[14] != Byte(15) || v15.values[0] != Byte(1)) { return 15; }
    let a16: Byte[16] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8), Byte(9), Byte(10), Byte(11), Byte(12), Byte(13), Byte(14), Byte(15), Byte(16)];
    let v16 = Bytes16(a16);
    let r16 = native_bytes16(v16);
    if (r16.values[0] != Byte(101) || r16.values[15] != Byte(16) || v16.values[0] != Byte(1)) { return 16; }
    let a80: Byte[80] = [Byte(1), Byte(2), Byte(3), Byte(4), Byte(5), Byte(6), Byte(7), Byte(8), Byte(9), Byte(10), Byte(11), Byte(12), Byte(13), Byte(14), Byte(15), Byte(16), Byte(17), Byte(18), Byte(19), Byte(20), Byte(21), Byte(22), Byte(23), Byte(24), Byte(25), Byte(26), Byte(27), Byte(28), Byte(29), Byte(30), Byte(31), Byte(32), Byte(33), Byte(34), Byte(35), Byte(36), Byte(37), Byte(38), Byte(39), Byte(40), Byte(41), Byte(42), Byte(43), Byte(44), Byte(45), Byte(46), Byte(47), Byte(48), Byte(49), Byte(50), Byte(51), Byte(52), Byte(53), Byte(54), Byte(55), Byte(56), Byte(57), Byte(58), Byte(59), Byte(60), Byte(61), Byte(62), Byte(63), Byte(64), Byte(65), Byte(66), Byte(67), Byte(68), Byte(69), Byte(70), Byte(71), Byte(72), Byte(73), Byte(74), Byte(75), Byte(76), Byte(77), Byte(78), Byte(79), Byte(80)];
    let v80 = Bytes80(a80);
    let r80 = native_bytes80(v80);
    if (r80.values[0] != Byte(101) || r80.values[79] != Byte(80) || v80.values[0] != Byte(1)) { return 80; }
    if (native_after_bulk(1, 2, 3, v80, 4, 5) != 95) { return 81; }
    let indirect: Function(Bytes3) -> Bytes3 = native_bytes3;
    let indirect_result = indirect(v3);
    if (indirect_result.values[0] != Byte(101)) { return 82; }
    if (native_fragment_exports() != 0) { return 83; }
    print("PASS: native aggregate fragments and parameter staging");
    return 0;
}
