// tests/fixtures/linker/pe_unwind_objects.wl
import * from "../../../src/linker/coff/model.wl"
import coff_put_word from "../../../src/linker/coff/reloc.wl"


func pe_unwind_span(ref object: CoffObject, bytes: Vector(Byte)) -> CoffSpan {
    let offset = object.bytes.length();
    let i = 0;
    while (i < bytes.length()) { object.bytes.append(bytes[i]); i++; }
    return CoffSpan(offset, bytes.length());
}

func pe_unwind_name(ref object: CoffObject, name: String) -> CoffSpan {
    let offset = object.bytes.length();
    let i = 0;
    while (i < name.length()) { object.bytes.append(name[i]); i++; }
    return CoffSpan(offset, name.length());
}

func pe_unwind_object() -> CoffObject {
// two real frame shapes, reversed table rows force sorting after RVA relocations
    let object = CoffObject();
    let code = [Byte(85), Byte(72), Byte(137), Byte(229), Byte(72), Byte(131), Byte(236), Byte(32),
        Byte(184), Byte(37), Byte(0), Byte(0), Byte(0), Byte(72), Byte(131), Byte(196), Byte(32), Byte(93), Byte(195)];
    while (code.length() < 32) { code.append(Byte(144)); }
    let large = [Byte(85), Byte(72), Byte(137), Byte(229), Byte(72), Byte(129), Byte(236), Byte(0), Byte(1), Byte(0), Byte(0),
        Byte(184), Byte(42), Byte(0), Byte(0), Byte(0), Byte(72), Byte(129), Byte(196), Byte(0), Byte(1), Byte(0), Byte(0), Byte(93), Byte(195)];
    let i = 0;
    while (i < large.length()) { code.append(large[i]); i++; }
    let pdata: Vector(Byte) = [];
    while (pdata.length() < 24) { pdata.append(Byte(0)); }
    coff_put_word(pdata, 0, 4, 32UL);
    coff_put_word(pdata, 4, 4, 57UL);
    coff_put_word(pdata, 8, 4, 12UL);
    coff_put_word(pdata, 16, 4, 19UL);
    let xdata = [Byte(1), Byte(8), Byte(3), Byte(5), Byte(8), Byte(50), Byte(4), Byte(3), Byte(1), Byte(80), Byte(0), Byte(0),
        Byte(1), Byte(11), Byte(4), Byte(5), Byte(11), Byte(1), Byte(32), Byte(0), Byte(4), Byte(3), Byte(1), Byte(80)];
    let text_name = pe_unwind_name(ref object, ".text");
    let text_data = pe_unwind_span(ref object, code);
    let pdata_name = pe_unwind_name(ref object, ".pdata");
    let pdata_data = pe_unwind_span(ref object, pdata);
    let xdata_name = pe_unwind_name(ref object, ".xdata");
    let xdata_data = pe_unwind_span(ref object, xdata);
    object.sections.append(CoffSection(name=text_name, size=UInt32(code.length()), address=0U, data=text_data, flags=0x60000020U,
        alignment=16, relocs=[], lines=CoffSpan()));
    object.sections.append(CoffSection(name=pdata_name, size=24U, address=0U, data=pdata_data, flags=0x40000040U, alignment=4,
        relocs=[CoffReloc(0U, 0, 3U), CoffReloc(4U, 0, 3U), CoffReloc(8U, 2, 3U),
            CoffReloc(12U, 0, 3U), CoffReloc(16U, 0, 3U), CoffReloc(20U, 2, 3U)], lines=CoffSpan()));
    object.sections.append(CoffSection(name=xdata_name, size=24U, address=0U, data=xdata_data, flags=0x40000040U,
        alignment=4, relocs=[], lines=CoffSpan()));
    object.symbols.append(CoffSymbol(name=pe_unwind_name(ref object, "Small"), value=0U, section=1, type=0U, storage=Byte(2), table_index=0, aux=CoffSpan()));
    object.symbols.append(CoffSymbol(name=pe_unwind_name(ref object, "Large"), value=32U, section=1, type=0U, storage=Byte(2), table_index=1, aux=CoffSpan()));
    object.symbols.append(CoffSymbol(name=pe_unwind_name(ref object, "unwind"), value=0U, section=3, type=0U, storage=Byte(3), table_index=2, aux=CoffSpan()));
    object.symbol_map = [0, 1, 2];
    return object;
}
