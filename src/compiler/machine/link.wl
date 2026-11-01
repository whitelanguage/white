// src/compiler/machine/link.wl
import Compiler from "../context.wl"
import WirModule, WirLinkage from "../wir/model.wl"
import PeImport, PeExport from "../../linker/pe/model.wl"
import pe_import_dll from "../../linker/pe/imports.wl"


func machine_pe_imports(source: Compiler) -> Vector(PeImport) {
// declarations carry DLL ownership, unresolved symbols without it remain link errors
    let result: Vector(PeImport) = [];
    for (let i = 0; i < source.extern_libraries.length(); i++) {
        let declaration = source.extern_libraries[i];
        let dll = pe_import_dll(declaration.library);
        if (dll.length() != 0 && !dll.ends_with(".dll") && !dll.ends_with(".lib") && !dll.ends_with(".a")) {
            dll += ".dll";
        }
        result.append(PeImport(dll=dll, name=declaration.symbol));
    }
    return result;
}

func machine_pe_exports(program: WirModule) -> Vector(PeExport) {
// exports are frontend metadata, keeping them here avoids interpreting our own .drectve text
    let result: Vector(PeExport) = [];
    for (let i = 0; i < program.arena.functions.length(); i++) {
        let function = program.arena.functions[i];
        if (function.export_symbol && function.linkage != WirLinkage.External && function.blocks.length() != 0) {
            result.append(PeExport(name=function.name));
        }
    }
    for (let g = 0; g < program.arena.globals.length(); g++) {
        let global = program.arena.globals[g];
        if (global.export_symbol && global.linkage != WirLinkage.External) {
            result.append(PeExport(name=global.name));
        }
    }
    return result;
}
