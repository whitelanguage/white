// src/linker/coff/alternates.wl
import CoffObject from "model.wl"
import CoffAlias, CoffSymbolRef from "link_model.wl"
import CoffDirectives from "directives.wl"
import pe_import_symbol from "../pe/imports.wl"


func coff_alternate_queries(ref query: CoffObject, directives: CoffDirectives, first: Int, object: Int) -> Vector(CoffAlias) {
// keep decoded names in the query object, alias edges use the same byte-name index as relocations
    let aliases: Vector(CoffAlias) = [];
    for (let i = first; i < directives.alternates.length(); i++) {
        let item = directives.alternates[i];
        let source = pe_import_symbol(ref query, item.source, 0, 0U, true);
        let target = pe_import_symbol(ref query, item.target, 0, 0U, true);
        aliases.append(CoffAlias(CoffSymbolRef(object, source), CoffSymbolRef(object, target)));
    }
    return aliases;
}
