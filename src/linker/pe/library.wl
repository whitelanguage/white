// src/linker/pe/library.wl
import PeExportBinding from "model.wl"
import pe_import_dll, pe_import_name from "imports.wl"
import CoffLibraryPart, CoffLibraryResult from "../coff/library_model.wl"
import library_word, library_text, write_coff_library from "../coff/library_write.wl"
import import_support_members from "../coff/import_support.wl"


func write_import_library(dll: String, exports: Vector(PeExportBinding)) -> CoffLibraryResult {
// use the final PE bindings so ordinal assignment and data classification cannot drift from the DLL
    if (pe_import_dll(dll).length() == 0) { return CoffLibraryResult(message="Invalid DLL name for import library"); }
    if (exports.length() > 65532) { return CoffLibraryResult(message="Too many exports for COFF import library member indices"); }
    let parts = import_support_members(dll);
    for (let e = 0; e < exports.length(); e++) {
        let binding = exports[e];
        let symbol = binding.name;
        if (symbol.length() == 0) { symbol = binding.symbol; }
        if (!pe_import_name(symbol, true) || symbol.starts_with("__imp_") || binding.ordinal == 0U ||
            binding.ordinal > 65535U || binding.hint > 65535U) {
            return CoffLibraryResult(message="Invalid export binding for COFF import library");
        }
        let payload_size = Long(symbol.length()) + Long(dll.length()) + 2L;
        if (payload_size + 20L > 2147483647L) { return CoffLibraryResult(message="COFF import member exceeds the supported size"); }
        let bytes: Vector(Byte) = [];
        library_word(ref bytes, 0U, 2);
        library_word(ref bytes, 65535U, 2);
        library_word(ref bytes, 0U, 2);
        library_word(ref bytes, 0x8664U, 2);
        library_word(ref bytes, 0U, 4);
        library_word(ref bytes, UInt32(payload_size), 4);
        let flags = 4U;
        let hint = binding.hint;
        if (binding.name.length() == 0) { flags = 0U; hint = binding.ordinal; }
        if (binding.is_data) { flags |= 1U; }
        library_word(ref bytes, hint, 2);
        library_word(ref bytes, flags, 2);
        library_text(ref bytes, symbol);
        library_text(ref bytes, dll);
        let names: Vector(String) = [];
        if (!binding.is_data) { names.append(symbol); }
        names.append("__imp_" + symbol);
        parts.append(CoffLibraryPart(bytes, names));
    }
    return write_coff_library(parts);
}
