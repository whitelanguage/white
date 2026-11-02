// src/linker/coff/archive_model.wl
import CoffSpan, CoffError from "model.wl"


struct ArchiveMember(header: Int, data: CoffSpan, name: CoffSpan)
struct ArchiveSymbol(name: CoffSpan, member: Int, next: Int = -1)
struct CoffArchive(
    bytes: Vector(Byte),
    members: Vector(ArchiveMember) = [],
    symbols: Vector(ArchiveSymbol) = [],
    offsets: Dict(Int, Int) = Dict(),
    buckets: Dict(UInt64, Int) = Dict()
)
struct ArchiveResult(archive: Optional(CoffArchive) = null, status: CoffError = CoffError.None, offset: Int = 0, message: String = "")
