// src/compiler/machine/object.wl
struct MachineSection(
    name: String,
    bytes: Vector(Byte),
    alignment: Int,
    executable: Bool,
    writable: Bool
)

struct MachineSymbol(
    name: String,
    section: String,
    offset: UInt32,
    external: Bool
)

struct MachineRelocation(
    section: String,
    offset: UInt32,
    kind: UInt32,
    symbol: String,
    addend: Long
)

struct MachineObject(
    machine: UInt32,
    sections: Vector(MachineSection),
    symbols: Vector(MachineSymbol),
    relocations: Vector(MachineRelocation)
)
