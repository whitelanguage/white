// src/linker/inputs.wl
import "file"
import "sys"


struct LinkInput(path: String, bytes: Vector(Byte) = [], missing: Bool = false, message: String = "")

func is_archive_name(name: String) -> Bool {
    let length = name.length();
    if (length >= 2 && name[length - 2] == '.' && (name[length - 1] == 'a' || name[length - 1] == 'A')) { return true; }
    return length >= 4 && name[length - 4] == '.' && (name[length - 3] == 'l' || name[length - 3] == 'L') &&
        (name[length - 2] == 'i' || name[length - 2] == 'I') && (name[length - 1] == 'b' || name[length - 1] == 'B');
}

func read_link_input(path: String) -> LinkInput {
// open once, a failed read must not turn into a search for a different library
    let input = file.File(path, "rb");
    if (!input.is_open()) {
        if (input.last_error() == file.Error.NotFound) { return LinkInput(path=path, missing=true); }
        return LinkInput(path=path, message="Could not open '" + path + "'.");
    }
    let content = input.read_all()?;
    catch(err) {
        input.close();
        return LinkInput(path=path, message="Could not read '" + path + "'.");
    }
    input.close();

    // file buffers carry a byte length, native object data is never decoded as UTF-8.
    let bytes: Vector(Byte) = [];
    for (let i = 0; i < content.length(); i++) { bytes.append(content[i]); }
    return LinkInput(path=path, bytes=bytes);
}

func find_link_library(name: String, paths: Vector(String)) -> LinkInput {
// explicit -L directories win in command-line order, cwd is the final fallback
    if (!is_archive_name(name)) { return LinkInput(path=name, message="Expected an archive library name: '" + name + "'."); }
    for (let ch = 0; ch < name.length(); ch++) {
        let byte = name[ch];
        if (byte == Byte(0) || byte == '/' || byte == '\\' || byte == ':') {
            return LinkInput(path=name, message="Library name must not contain a path: '" + name + "'.");
        }
    }
    for (let dir = 0; dir <= paths.length(); dir++) {
        let prefix = ".";
        if (dir < paths.length()) { prefix = paths[dir]; }
        if (!prefix.ends_with("/") && (sys.OS != sys.Os.Windows || !prefix.ends_with("\\"))) {
            if (sys.OS == sys.Os.Windows) { prefix += "\\"; }
            else { prefix += "/"; }
        }
        let candidate = read_link_input(prefix + name);
        if (!candidate.missing) { return candidate; }
    }
    return LinkInput(path=name, message="Could not find library '" + name + "' in the -L directories or current directory.");
}
