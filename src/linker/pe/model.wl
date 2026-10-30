// src/linker/pe/model.wl
import CoffPlacement, CoffLinkError from "../coff/link_model.wl"


struct PeOptions(
    entry: String = "mainCRTStartup",
    image_base: UInt64 = 5368709120UL,
    stack_reserve: UInt64 = 1048576UL,
    stack_commit: UInt64 = 4096UL,
    heap_reserve: UInt64 = 1048576UL,
    heap_commit: UInt64 = 4096UL
)

struct PeInput(object: Int, section: Int)

struct PeSection(
    name: Vector(Byte),
    flags: UInt32,
    alignment: Int = 1,
    size: UInt32 = 0U,
    initialized_size: UInt32 = 0U,
    rva: UInt32 = 0U,
    raw_offset: UInt32 = 0U,
    raw_size: UInt32 = 0U,
    parts: Vector(PeInput) = []
)

struct PeLayout(
    sections: Vector(PeSection) = [],
    placements: Vector(Vector(CoffPlacement)) = [],
    headers_size: UInt32 = 0U,
    image_size: UInt32 = 0U,
    file_size: UInt32 = 0U
)

struct PeLayoutResult(layout: Optional(PeLayout) = null, errors: Vector(CoffLinkError) = [])

struct PeImage(bytes: Vector(Byte), layout: PeLayout, entry_rva: UInt32, fixed_base: Bool)
struct PeImageResult(image: Optional(PeImage) = null, errors: Vector(CoffLinkError) = [])
