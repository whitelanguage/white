// Test: COFF_IMPORT_OBJECT
// File: tests/linker/test_import_object.wl
// Focus: Short import headers, name transformations, bounded strings and lazy bindings.
import CoffError from "../../src/linker/coff/model.wl"
import read_coff_import from "../../src/linker/coff/import_object.wl"
import pe_emit_word from "../../src/linker/pe/reloc.wl"
import pe_import_refs from "../fixtures/linker/pe_import_objects.wl"
import read_archive from "../../src/linker/coff/archive.wl"
import CoffArchive from "../../src/linker/coff/archive_model.wl"
import extract_archives from "../../src/linker/coff/extract.wl"


func import_text(bytes: Vector(Byte), text: String) -> Void {
    for (let i = 0; i < text.length(); i++) { bytes.append(text[i]); }
    bytes.append(Byte(0));
}

func import_bytes(symbol: String, flags: UInt32, target: String = "") -> Vector(Byte) {
    let payload: Vector(Byte) = [];
    import_text(payload, symbol);
    import_text(payload, "Sample.DLL");
    if ((flags >> 2U) == 4U) { import_text(payload, target); }
    let bytes: Vector(Byte) = [];
    pe_emit_word(ref bytes, 0UL, 2);
    pe_emit_word(ref bytes, 65535UL, 2);
    pe_emit_word(ref bytes, 0UL, 2);
    pe_emit_word(ref bytes, 0x8664UL, 2);
    pe_emit_word(ref bytes, 0UL, 4);
    pe_emit_word(ref bytes, UInt64(payload.length()), 4);
    pe_emit_word(ref bytes, 7UL, 2);
    pe_emit_word(ref bytes, UInt64(flags), 2);
    for (let b = 0; b < payload.length(); b++) { bytes.append(payload[b]); }
    return bytes;
}

func import_member(bytes: Vector(Byte), name: String, payload: Vector(Byte)) -> Void {
    let field = name;
    while (field.length() < 16) { field += " "; }
    let size = String(payload.length());
    while (size.length() < 10) { size += " "; }
    let header = field + "0           0     0     0       " + size + "`\n";
    for (let h = 0; h < header.length(); h++) { bytes.append(header[h]); }
    for (let p = 0; p < payload.length(); p++) { bytes.append(payload[p]); }
    if ((payload.length() & 1) != 0) { bytes.append(Byte(10)); }
}

func import_archive(payload: Vector(Byte), symbols: Vector(String)) -> CoffArchive? {
    let directory: Vector(Byte) = [];
    let size = 4 + 4 * symbols.length();
    for (let s = 0; s < symbols.length(); s++) { size += symbols[s].length() + 1; }
    let offset = 8 + 60 + size + (size & 1);
    // the archive's first directory is big-endian, the short member remains little-endian.
    let words: Vector(UInt32) = [UInt32(symbols.length())];
    for (let w = 0; w < symbols.length(); w++) { words.append(UInt32(offset)); }
    for (let n = 0; n < words.length(); n++) {
        directory.append(Byte(words[n] >> 24U));
        directory.append(Byte(words[n] >> 16U));
        directory.append(Byte(words[n] >> 8U));
        directory.append(Byte(words[n]));
    }
    for (let name = 0; name < symbols.length(); name++) { import_text(directory, symbols[name]); }
    let bytes: Vector(Byte) = [];
    let magic = "!<arch>\n";
    for (let m = 0; m < magic.length(); m++) { bytes.append(magic[m]); }
    import_member(bytes, "/", directory);
    import_member(bytes, "sample.obj/", payload);
    let result = read_archive(bytes);
    if (result.archive is null) { throw Error.InvalidArgument; }
    return result.archive;
}

func main() -> Int {
    let symbols = ["answer", "answer", "_answer", "_answer@4", "local"];
    for (let mode = 0; mode <= 4; mode++) {
        let result = read_coff_import(import_bytes(symbols[mode], UInt32(mode) << 2U, "answer"));
        if (result.entry is null) { print("FAIL: import mode ", mode, " ", result.message); return 1; }
        let entry = result.entry;
        if (entry.dll != "sample.dll" || entry.symbol != symbols[mode] || entry.is_data) { print("FAIL: import identity ", mode); return 1; }
        if (mode == 0) {
            if (entry.ordinal is null || entry.ordinal != 7U || entry.name != "" || entry.hint != 0U) { print("FAIL: ordinal binding"); return 1; }
        } else if (entry.ordinal is !null || entry.name != "answer" || entry.hint != 7U) { print("FAIL: import name ", mode); return 1; }
    }
    for (let kind = 1; kind <= 2; kind++) {
        let result = read_coff_import(import_bytes("data", 4U | UInt32(kind)));
        if (result.entry is null) { print("FAIL: data header"); return 1; }
        let entry = result.entry;
        if (!entry.is_data || entry.is_const != (kind == 2)) { print("FAIL: data kind"); return 1; }
    }
    let valid = import_bytes("answer", 4U);
    for (let n = 0; n < valid.length(); n++) {
        let prefix: Vector(Byte) = [];
        for (let b = 0; b < n; b++) { prefix.append(valid[b]); }
        // correct the size field so truncation reaches the name scanner too.
        if (n >= 20) { prefix[12] = Byte(n - 20); }
        if (read_coff_import(prefix).entry is !null) { print("FAIL: truncated import ", n); return 1; }
    }
    for (let flag = 0; flag < 65536; flag++) {
        if (flag <= 18 && (flag & 3) != 3) { continue; }
        valid[18] = Byte(flag & 255);
        valid[19] = Byte(flag >> 8);
        if (read_coff_import(valid).entry is !null) { print("FAIL: import flags ", flag); return 1; }
    }
    valid[18] = Byte(4);
    valid[19] = Byte(0);
    valid[4] = Byte(2);
    if (read_coff_import(valid).status != CoffError.UnsupportedObject) { print("FAIL: bigobj version"); return 1; }
    valid[4] = Byte(0);
    valid[6] = Byte(76);
    if (read_coff_import(valid).entry is !null) { print("FAIL: wrong machine"); return 1; }
    valid[6] = Byte(100);
    valid[valid.length() - 1] = Byte(1);
    if (read_coff_import(valid).entry is !null) { print("FAIL: unterminated name"); return 1; }
    valid[valid.length() - 1] = Byte(0);
    valid.append(Byte(0));
    valid[12] = Byte(valid.length() - 20);
    if (read_coff_import(valid).entry is !null) { print("FAIL: trailing payload"); return 1; }
    if (read_coff_import(import_bytes("_", 8U)).entry is !null) { print("FAIL: empty decorated name"); return 1; }

    let caller = pe_import_refs(["answer", "__imp_answer"])?;
    catch(err) { print("FAIL: caller fixture"); return 1; }
    let archive = import_archive(import_bytes("answer", 4U), ["answer", "__imp_answer"])?;
    catch(err) { print("FAIL: archive fixture"); return 1; }
    let selected = extract_archives([caller], [archive]);
    if (selected.errors.length() != 0 || selected.objects.length() != 1 || selected.imports.length() != 1 ||
        selected.objects[0].symbols.length() != caller.symbols.length()) {
        print("FAIL: import names leaked into object layout or selected twice");
        return 1;
    }
    let data = import_archive(import_bytes("answer", 5U), ["answer"])?;
    catch(err) { print("FAIL: data fixture"); return 1; }
    if (extract_archives([caller], [data]).errors.length() == 0) { print("FAIL: data import defined a bare call target"); return 1; }
    if (extract_archives([], [archive]).imports.length() != 0) { print("FAIL: unused DLL retained"); return 1; }
    print("PASS: Short COFF import objects");
    return 0;
}
