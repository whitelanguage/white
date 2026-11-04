// src/linker/libraries.wl
import CoffArchive from "coff/archive_model.wl"
import read_archive from "coff/archive.wl"
import CoffDirectives from "coff/directives.wl"
import find_link_library from "inputs.wl"


struct LinkLibraries(
    archives: Vector(CoffArchive) = [],
    paths: Vector(String) = [],
    default_keys: Vector(String) = [],
    supplied: Dict(String, Bool) = Dict(),
    cursor: Int = 0
)

func discover_default_libraries(ref libs: LinkLibraries, directives: CoffDirectives, paths: Vector(String), verbose: Bool) -> Bool {
// every name is visited once, a cyclic set of default directives cannot keep reopening archives
    while (libs.cursor < directives.libraries.length()) {
        let request = directives.libraries[libs.cursor];
        libs.cursor++;
        if (directives.no_libraries || directives.excluded.contains_key(request.key)) { continue; }
        if (libs.cursor > 4096) {
            print("LinkError: Too many COFF default library requests.");
            return false;
        }
        let input = find_link_library(request.name, paths);
        if (input.message.length() != 0) {
            print("LinkError: Default library '" + request.name + "' from object " + request.object + ": " + input.message);
            return false;
        }
        if (libs.supplied.contains_key(input.path)) { continue; }
        let decoded = read_archive(input.bytes);
        if (decoded.archive is null) {
            print("LinkError: '" + input.path + "': " + decoded.message + " at byte " + decoded.offset);
            return false;
        }
        let archive: CoffArchive = decoded.archive;
        libs.archives.append(archive);
        libs.paths.append(input.path);
        libs.default_keys.append(request.key);
        libs.supplied.put(input.path, true);
        if verbose { print("Found default library: " + input.path); }
    }
    return true;
}

func active_link_libraries(libs: LinkLibraries, directives: CoffDirectives) -> Vector(Bool) {
// late exclusions stop further default extraction, already loaded members and explicit inputs remain
    let enabled: Vector(Bool) = [];
    for (let i = 0; i < libs.default_keys.length(); i++) {
        let key = libs.default_keys[i];
        enabled.append(key.length() == 0 || (!directives.no_libraries && !directives.excluded.contains_key(key)));
    }
    return enabled;
}
