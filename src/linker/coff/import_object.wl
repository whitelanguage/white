// src/linker/coff/import_object.wl
// header fields: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#import-header
import "strings"
import CoffError from "model.wl"
import coff_u16, coff_u32 from "reader.wl"
import PeImport from "../pe/model.wl"
import pe_import_dll from "../pe/imports.wl"


struct CoffImportResult(entry: Optional(PeImport) = null, status: CoffError = CoffError.InvalidObject, offset: Int = 0, message: String = "")

func coff_is_import(bytes: Vector(Byte)) -> Bool {
    return bytes.length() >= 4 && coff_u16(bytes, 0) == 0U && coff_u16(bytes, 2) == 65535U;
}

func read_coff_import(bytes: Vector(Byte)) -> CoffImportResult {
// short import members describe loader bindings, they have no ordinary section or relocation table
    if (bytes.length() < 20 || !coff_is_import(bytes)) {
        return CoffImportResult(message="Truncated or invalid COFF import header");
    }
    if (coff_u16(bytes, 4) != 0U) {
        return CoffImportResult(status=CoffError.UnsupportedObject, offset=4, message="Unsupported COFF import version or bigobj header");
    }
    if (coff_u16(bytes, 6) != 0x8664U) {
        return CoffImportResult(status=CoffError.UnsupportedObject, offset=6, message="COFF import machine must be AMD64");
    }
    if (coff_u32(bytes, 12) != UInt32(bytes.length() - 20)) {
        return CoffImportResult(offset=12, message="COFF import payload size does not match its member");
    }
    let flags = coff_u16(bytes, 18);
    let kind = flags & 3U;
    let naming = (flags >> 2U) & 7U;
    if ((flags & 65504U) != 0U || kind == 3U || naming > 4U) {
        return CoffImportResult(offset=18, message="Invalid COFF import type, name mode or reserved bits");
    }

    let texts: Vector(String) = [];
    let cursor = 20;
    let count = 2;
    if (naming == 4U) { count = 3; }
    for (let field = 0; field < count; field++) {
        let start = cursor;
        let buffer = strings.Builder(64);
        while (cursor < bytes.length() && bytes[cursor] != Byte(0)) {
            let byte = Int(bytes[cursor]);
            if (byte < 32 || byte > 126) {
                return CoffImportResult(offset=cursor, message="COFF import names must be printable ASCII");
            }
            buffer.write_byte(bytes[cursor])?;
            catch(err) { return CoffImportResult(offset=cursor, message="Could not allocate COFF import name"); }
            cursor++;
        }
        if (cursor == bytes.length() || cursor == start) {
            return CoffImportResult(offset=start, message="Missing or empty COFF import name");
        }
        let text = buffer.build()?;
        catch(err) { return CoffImportResult(offset=start, message="Could not allocate COFF import name"); }
        texts.append(text);
        cursor++;
    }
    if (cursor != bytes.length()) {
        return CoffImportResult(offset=cursor, message="Unexpected bytes after COFF import names");
    }
    let symbol = texts[0];
    let dll = pe_import_dll(texts[1]);
    if (dll.length() == 0 || symbol.starts_with("__imp_")) {
        return CoffImportResult(offset=20, message="Invalid COFF import DLL or public symbol");
    }
    let entry = PeImport(dll=dll, symbol=symbol, is_data=kind != 0U, is_const=kind == 2U);
    let ordinal = coff_u16(bytes, 16);
    if (naming == 0U) {
        entry.ordinal = ordinal;
    } else {
        let name = symbol;
        if (naming == 2U || naming == 3U) {
            if (name[0] == '?' || name[0] == '@' || name[0] == '_') { name = name.slice(1, name.length()); }
            if (naming == 3U) {
                for (let pos = 0; pos < name.length(); pos++) {
                    if (name[pos] == '@') { name = name.slice(0, pos); break; }
                }
            }
        } else if (naming == 4U) { name = texts[2]; }
        if (name.length() == 0) {
            return CoffImportResult(offset=20, message="COFF import decoration leaves an empty export name");
        }
        entry.name = name;
        entry.hint = ordinal;
    }
    return CoffImportResult(entry=entry, status=CoffError.None);
}
