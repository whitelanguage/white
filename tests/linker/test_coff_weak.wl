// tests/linker/test_coff_weak.wl
import * from "../../src/linker/coff/model.wl"
import * from "../../src/linker/coff/link_model.wl"
import coff_resolve_symbols from "../../src/linker/coff/symbols.wl"
import * from "../../src/linker/pe/model.wl"
import write_pe from "../../src/linker/pe/writer.wl"


func fixture() -> CoffObject {
    let bytes: Vector(Byte) = [Byte(184), Byte(42), Byte(0), Byte(0), Byte(0), Byte(195)];
    let section_name = bytes.length();
    for (let a = 0; a < 5; a++) { bytes.append(".text"[a]); }
    let alias_name = bytes.length();
    for (let b = 0; b < 6; b++) { bytes.append("answer"[b]); }
    let target_name = bytes.length();
    for (let d = 0; d < 8; d++) { bytes.append("fallback"[d]); }
    let aux = bytes.length();
    for (let z = 0; z < 18; z++) { bytes.append(Byte(0)); }

    let section = CoffSection(name=CoffSpan(section_name, 5), size=6U, address=0U, data=CoffSpan(0, 6),
        flags=0x60500020U, alignment=16, relocs=[], lines=CoffSpan());
    let weak = CoffSymbol(name=CoffSpan(alias_name, 6), value=0U, section=0, type=32U, storage=Byte(105),
        table_index=0, aux=CoffSpan(aux, 18), weak_target=1, weak_search=3U);
    let target = CoffSymbol(name=CoffSpan(target_name, 8), value=0U, section=1, type=32U, storage=Byte(2),
        table_index=2, aux=CoffSpan());
    return CoffObject(bytes=bytes, sections=[section], symbols=[weak, target], symbol_map=[0, -1, 1]);
}

func main() -> Int {
    let object = fixture();
    let symbols = coff_resolve_symbols([object]);
    if (symbols.errors.length() != 0 || symbols.targets[0][0].object != 0 || symbols.targets[0][0].symbol != 1) {
        print("FAIL: weak fallback binding");
        return 1;
    }
    let image = write_pe([object], PeOptions(entry="answer", exports=[PeExport(name="public_answer", symbol="answer")]));
    let result = image.image;
    if (result is null) {
        print("FAIL: weak entry or export");
        return 1;
    }
    let linked: PeImage = result;
    if (linked.entry_rva != linked.layout.placements[0][0].rva || linked.exports.length() != 1 || linked.exports[0].is_data) {
        print("FAIL: weak code binding lost section classification");
        return 1;
    }
    object.sections[0].flags = 0xC0300040U;
    image = write_pe([object], PeOptions(entry="", is_dll=true, exports=[PeExport(name="answer")]));
    let data_result = image.image;
    if (data_result is null) { return 1; }
    let data_image: PeImage = data_result;
    if (!data_image.exports[0].is_data) {
        print("FAIL: weak data export was classified as code");
        return 1;
    }

    // Absolute zero is a defined fallback, it must not be turned into an unresolved name.
    object.symbols[1].section = -1;
    symbols = coff_resolve_symbols([object]);
    if (symbols.errors.length() != 0 || symbols.targets[0][0].symbol != 1) { return 1; }
    image = write_pe([object], PeOptions(entry="answer"));
    if (image.errors.length() != 1 || image.errors[0].status != CoffLinkStatus.InvalidLayout) {
        print("FAIL: absolute weak entry reached section indexing");
        return 1;
    }
    image = write_pe([object], PeOptions(entry="", is_dll=true, exports=[PeExport(name="answer")]));
    if (image.errors.length() != 1 || image.errors[0].status != CoffLinkStatus.InvalidLayout) {
        print("FAIL: absolute weak export reached section indexing");
        return 1;
    }

    object = fixture();
    object.symbols[1].section = 0;
    object.sections[0].relocs = [CoffReloc(0U, 0, 4U)];
    symbols = coff_resolve_symbols([object]);
    if (symbols.errors.length() != 1 || symbols.errors[0].symbol != 0 || symbols.errors[0].other.symbol != 1) {
        print("FAIL: missing fallback diagnostic lost the terminal name");
        return 1;
    }
    object.symbols[0].weak_search = 2U;
    symbols = coff_resolve_symbols([object]);
    if (symbols.errors.length() != 1 || symbols.errors[0].status != CoffLinkStatus.Unsupported) { return 1; }

    print("PASS: Weak COFF bindings, entries and exports");
    return 0;
}
