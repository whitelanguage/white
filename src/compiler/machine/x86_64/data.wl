// src/compiler/machine/x86_64/data.wl
import * from "model.wl"
import x86_is_sysv_abi from "abi.wl"
import * from "../../wir/model.wl"
import machine_address_symbol, machine_emit_globals from "../data.wl"


func x86_address_symbol(ref program: WirModule, value: WirValueID) -> String {
    return machine_address_symbol(ref program, value);
}

func x86_emit_globals(ref program: WirModule, layouts: Vector(WirTypeLayout), reachable: Vector(Bool), ref object: X86Object) -> String {
// only section policy and relocation kinds depend on the object format here
    let name = ".rdata";
    let writable = false;
    if (x86_is_sysv_abi()) {
        name = ".data.rel.ro";
        writable = true;
    }

    let data = machine_emit_globals(ref program, layouts, name, writable, reachable);
    if (data.message.length() != 0) { return data.message; }

    for (let i = 0; i < data.sections.length(); i++) {
        let s = data.sections[i];
        object.sections.append(X86CodeSection(name=s.name, bytes=s.bytes, alignment=s.alignment, executable=s.executable, writable=s.writable));
    }
    for (let j = 0; j < data.symbols.length(); j++) {
        let s = data.symbols[j];
        object.symbols.append(X86Symbol(name=s.name, section=s.section, offset=s.offset, external=s.external));
    }
    for (let k = 0; k < data.relocations.length(); k++) {
        let r = data.relocations[k];
        object.relocations.append(X86Relocation(section=r.section, offset=r.offset, kind=X86RelocationKind.Abs64, symbol=r.symbol, addend=r.addend));
    }

    return "";
}
