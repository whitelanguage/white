// Test: COFF_ARCHIVE
// File: tests/linker/test_archive.wl
// Focus: Checked framing, directory offsets, lazy member extraction and stale indices.
import * from "../../src/linker/coff/model.wl"
import read_coff from "../../src/linker/coff/reader.wl"
import coff_name_hash from "../../src/linker/coff/symbols.wl"
import * from "../../src/linker/coff/archive_model.wl"
import read_archive, archive_find from "../../src/linker/coff/archive.wl"
import extract_archives, begin_archive_work, resume_archive_work from "../../src/linker/coff/extract.wl"
import * from "../../src/compiler/machine/x86_64/model.wl"
import coff_object from "../../src/compiler/machine/x86_64/coff.wl"


func add_text(bytes: Vector(Byte), text: String) -> Void {
    for (let i = 0; i < text.length(); i++) { bytes.append(text[i]); }
}

func add_member(bytes: Vector(Byte), name: String, data: Vector(Byte)) -> Void {
    let field = name;
    while (field.length() < 16) { field += " "; }
    let size = String(data.length());
    while (size.length() < 10) { size += " "; }
    add_text(bytes, field + "0           0     0     0       " + size + "`\n");
    for (let i = 0; i < data.length(); i++) { bytes.append(data[i]); }
    if ((data.length() & 1) != 0) { bytes.append(Byte(10)); }
}

func make_archive(payload: Vector(Byte)) -> Vector(Byte) {
    let bytes: Vector(Byte) = [];
    add_text(bytes, "!<arch>\n");
    // first directory: one symbol, member header at 84, seven-byte name
    let index: Vector(Byte) = [Byte(0), Byte(0), Byte(0), Byte(1), Byte(0), Byte(0), Byte(0), Byte(84)];
    add_text(index, "answer");
    index.append(Byte(0));
    add_member(bytes, "/", index);
    add_member(bytes, "answer.obj/", payload);
    return bytes;
}

func main() -> Int {
    let text = [Byte(184), Byte(42), Byte(0), Byte(0), Byte(0), Byte(195)];
    let provider = coff_object(X86Object(sections=[X86CodeSection(name=".text", bytes=text, alignment=16, executable=true, writable=false)],
        symbols=[X86Symbol(name="answer", section=".text", offset=0U, external=true)], relocations=[]))?;
    catch(err) { return 1; }
    let bytes = make_archive(provider);
    let decoded = read_archive(bytes);
    if (decoded.archive is null) { print("FAIL: archive fixture ", decoded.message); return 1; }
    let archive: CoffArchive = decoded.archive;
    if (archive.members.length() != 1 || archive.symbols.length() != 1 || archive.members[0].header != 84) {
        print("FAIL: member framing");
        return 1;
    }
    let caller_bytes = coff_object(X86Object(sections=[X86CodeSection(name=".data", bytes=[Byte(0), Byte(0), Byte(0), Byte(0)], alignment=4, executable=false, writable=true)],
        symbols=[X86Symbol(name="answer", section="", offset=0U, external=true)],
        relocations=[X86Relocation(section=".data", offset=0U, kind=X86RelocationKind.Rel32, symbol="answer", addend=0L)]))?;
    catch(err) { return 1; }
    let caller_result = read_coff(caller_bytes);
    if (caller_result.object is null) { return 1; }
    let caller: CoffObject = caller_result.object;
    if (archive_find(archive, caller, caller.symbols[0].name) != 0) { return 1; }
    let name = caller.symbols[0].name;
    caller.bytes[name.offset] = Byte(99);
    archive.buckets.put(coff_name_hash(caller.bytes, name), 0);
    if (archive_find(archive, caller, name) != -1) { print("FAIL: hash bucket used as symbol identity"); return 1; }
    caller.bytes[name.offset] = Byte(97);
    let selected = extract_archives([caller], [archive]);
    if (selected.errors.length() != 0 || selected.objects.length() != 2) { print("FAIL: lazy extraction"); return 1; }
    selected = extract_archives([caller, selected.objects[1]], [archive]);
    if (selected.errors.length() != 0 || selected.objects.length() != 2) { print("FAIL: already defined symbol extracted again"); return 1; }
    if (extract_archives([], [archive]).objects.length() != 0) { print("FAIL: unused archive retained"); return 1; }

    // Discovery can add a library after the first unresolved demand, retain the existing index.
    let state = begin_archive_work([caller]);
    selected = resume_archive_work(ref state, []);
    if (selected.errors.length() != 0 || selected.objects.length() != 1 || state.unresolved.length() != 1) { return 1; }
    selected = resume_archive_work(ref state, [archive]);
    if (selected.errors.length() != 0 || selected.objects.length() != 2 || state.loaded.length() != 1) { return 1; }
    let loaded_id = state.loaded[0][0];
    selected = resume_archive_work(ref state, [archive]);
    if (selected.objects.length() != 2 || state.loaded[0][0] != loaded_id) { print("FAIL: resumed member loaded twice"); return 1; }
    if (resume_archive_work(ref state, []).errors.length() != 1 ||
        resume_archive_work(ref state, [archive], []).errors.length() != 1) { print("FAIL: invalid discovery state accepted"); return 1; }

    for (let n = 0; n < bytes.length(); n++) {
        if (n == 8) { continue; }
        let prefix: Vector(Byte) = [];
        for (let b = 0; b < n; b++) { prefix.append(bytes[b]); }
        if (read_archive(prefix).archive is !null) { print("FAIL: truncated prefix ", n); return 1; }
    }
    let saved = bytes[75];
    bytes[75] = Byte(85);
    if (read_archive(bytes).archive is !null) { print("FAIL: offset into payload accepted"); return 1; }
    bytes[75] = saved;
    bytes[76] = Byte(98);
    decoded = read_archive(bytes);
    if (decoded.archive is null) { return 1; }
    let stale: CoffArchive = decoded.archive;
    // force a demand for the stale directory spelling
    caller.bytes[caller.symbols[0].name.offset] = Byte(98);
    selected = extract_archives([caller], [stale]);
    if (selected.errors.length() != 1) { print("FAIL: lying symbol index"); return 1; }

    print("PASS: COFF archive reader and extraction");
    return 0;
}
