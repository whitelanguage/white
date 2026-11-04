// tests/linker/test_coff_directives.wl
import * from "../../src/linker/coff/model.wl"
import * from "../../src/linker/coff/link_model.wl"
import * from "../../src/linker/coff/directives.wl"
import coff_resolve_symbols from "../../src/linker/coff/symbols.wl"
import pe_import_symbol from "../../src/linker/pe/imports.wl"
import * from "../../src/linker/pe/model.wl"
import write_pe from "../../src/linker/pe/writer.wl"
import pe_leaf_object from "../fixtures/linker/pe_objects.wl"


func directive_object(text: String) -> CoffObject {
    let object = CoffObject();
    let name = ".drectve";
    for (let i = 0; i < name.length(); i++) { object.bytes.append(name[i]); }
    for (let j = 0; j < text.length(); j++) { object.bytes.append(text[j]); }
    object.sections.append(CoffSection(name=CoffSpan(0, name.length()), data=CoffSpan(name.length(), text.length()),
        size=UInt32(text.length()), address=0U, flags=0x00100A00U, alignment=1, relocs=[], lines=CoffSpan()));
    return object;
}

func main() -> Int {
    let quoted = directive_object(" /include:\"two words\" -EXPORT:Public=entry,@7 /failifmismatch:\"key=two words\" ");
    let tokens = coff_directive_tokens(quoted, quoted.sections[0].data);
    if (tokens.message.length() != 0 || tokens.tokens.length() != 3 ||
        tokens.tokens[0].text != "/include:two words" || tokens.tokens[1].text != "-EXPORT:Public=entry,@7" ||
        tokens.tokens[2].text != "/failifmismatch:key=two words" || tokens.tokens[0].offset != 9) {
        print("FAIL: directive tokenization or source offset");
        return 1;
    }
    let invalid_span = coff_directive_tokens(quoted, CoffSpan(-1, 4));
    if (invalid_span.message.length() == 0) { return 1; }
    let truncated = coff_directive_tokens(quoted, CoffSpan(0, quoted.bytes.length() + 1));
    if (truncated.message.length() == 0) { return 1; }
    let state = coff_collect_directives([quoted, quoted]);
    if (state.errors.length() != 0 || state.roots.length() != 2 || state.exports.length() != 1) { return 1; }
    let ordinal = state.exports[0].ordinal;
    let match = state.matches.lookup("key");
    if (state.exports[0].name != "Public" || ordinal is null || ordinal != 7U ||
        match is null || match != "two words") {
        print("FAIL: repeated directives or export metadata");
        return 1;
    }
    // A large token list checks the same forward scan as an ordinary compiler object.
    let many = directive_object("");
    let option = "/include:entry ";
    for (let copy = 0; copy < 4096; copy++) {
        for (let byte = 0; byte < option.length(); byte++) { many.bytes.append(option[byte]); }
    }
    many.sections[0].data.size = many.bytes.length() - 8;
    many.sections[0].size = UInt32(many.sections[0].data.size);
    state = coff_collect_directives([many]);
    if (state.errors.length() != 0 || state.roots.length() != 1 || state.roots[0] != "entry") { return 1; }

    let query = CoffObject();
    pe_import_symbol(ref query, "missing", 0, 0U, true);
    let resolution = coff_resolve_symbols([query]);
    if (resolution.errors.length() != 0) { print("FAIL: unused undefined symbol became required"); return 1; }
    resolution = coff_resolve_symbols([query], [CoffSymbolRef(0, 0)]);
    if (resolution.errors.length() != 1 || resolution.errors[0].status != CoffLinkStatus.UndefinedSymbol) { return 1; }
    resolution = coff_resolve_symbols([query], [CoffSymbolRef(-1, 0), CoffSymbolRef(0, 1)]);
    if (resolution.errors.length() != 2 || resolution.errors[0].status != CoffLinkStatus.InvalidObject ||
        resolution.errors[1].status != CoffLinkStatus.InvalidObject) { return 1; }

    let leaf = pe_leaf_object()?;
    catch(err) { return 1; }
    let defaults = directive_object("/defaultlib:Answer /defaultlib:ANSWER.lib /nodefaultlib:answer /NODEFAULTLIB");
    let libraries = coff_collect_directives([defaults]);
    if (libraries.errors.length() != 0 || libraries.libraries.length() != 1 || !libraries.no_libraries ||
        libraries.libraries[0].name != "Answer.lib" || libraries.libraries[0].key != "answer.lib" ||
        !libraries.excluded.contains_key("answer.lib")) { print("FAIL: default library normalization"); return 1; }
    let unprocessed = write_pe([leaf, directive_object("/defaultlib:answer")], PeOptions(entry="entry"));
    if (unprocessed.image is !null || unprocessed.errors.length() != 1 ||
        unprocessed.errors[0].status != CoffLinkStatus.Unsupported) { print("FAIL: unresolved discovery accepted by PE writer"); return 1; }
    let suppressed = write_pe([leaf, defaults], PeOptions(entry="entry"));
    if (suppressed.image is null) { print("FAIL: excluded default required discovery"); return 1; }
    let exported = directive_object("/export:Public=entry,@7 /export:Public=entry,@7");
    let image = write_pe([leaf, exported], PeOptions(entry="entry"));
    let ready = image.image;
    if (ready is null || image.errors.length() != 0) { print("FAIL: directive export image"); return 1; }
    let linked: PeImage = ready;
    if (linked.exports.length() != 1 || linked.exports[0].name != "Public" || linked.exports[0].ordinal != 7U ||
        exported.sections[0].flags != 0x00100A00U || exported.sections[0].discarded) {
        print("FAIL: export binding or input reuse");
        return 1;
    }
    image = write_pe([leaf, exported], PeOptions(entry="entry"));
    if (image.image is null) { return 1; }
    image = write_pe([leaf], PeOptions(entry="entry", exports=[PeExport(name="entry"), PeExport(name="entry")]));
    if (image.errors.length() != 1 || image.errors[0].message != "Duplicate PE export name 'entry'") { return 1; }
    print("PASS: COFF directive tokens, required symbols and reusable inputs");
    return 0;
}
