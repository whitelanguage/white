// src/linker/driver.wl
import "file"
import CoffObject from "coff/model.wl"
import read_coff from "coff/reader.wl"
import CoffArchive from "coff/archive_model.wl"
import read_archive from "coff/archive.wl"
import ArchiveSelection, begin_archive_work, resume_archive_work, extract_archives from "coff/extract.wl"
import coff_collect_directives from "coff/directives.wl"
import LinkLibraries, discover_default_libraries, active_link_libraries from "libraries.wl"
import PeImport, PeExport, PeOptions, PeImage from "pe/model.wl"
import write_pe from "pe/writer.wl"
import write_import_library from "pe/library.wl"
import LinkInput, is_archive_name, read_link_input, find_link_library from "inputs.wl"


func windows_implib_path(output: String) -> String {
    let len = output.length();
    if (len >= 4 && output[len - 4] == '.' && (output[len - 3] == 'd' || output[len - 3] == 'D') &&
        (output[len - 2] == 'l' || output[len - 2] == 'L') && (output[len - 1] == 'l' || output[len - 1] == 'L')) {
        return output.slice(0, len - 4) + ".lib";
    }
    return output + ".lib";
}

func write_link_output(path: String, bytes: Vector(Byte)) -> Bool {
// a successful build must include close errors, the file module buffers writes
    let target = file.create(path)?;
    catch(err) {
        print("LinkError: Could not create '" + path + "'.");
        return false;
    }
    target.write_bytes(bytes)?;
    catch(err) {
        target.close();
        print("LinkError: Could not write '" + path + "'.");
        return false;
    }
    target.close_checked()?;
    catch(err) {
        print("LinkError: Could not close '" + path + "'.");
        return false;
    }
    return true;
}

func link_windows(bytes: Vector(Byte), extra_files: Vector(String), imports: Vector(PeImport), exports: Vector(PeExport), output: String, shared: Bool, verbose: Bool, library_paths: Vector(String), libraries: Vector(String), gc_sections: Bool = false) -> Bool {
// decode every input before opening the output, malformed objects must leave an existing image untouched
    let objects: Vector(CoffObject) = [];
    let archives: Vector(CoffArchive) = [];
    let archive_paths: Vector(String) = [];
    let generated = read_coff(bytes);
    if (generated.object is null) {
        print("LinkError: Generated COFF object: " + generated.message);
        return false;
    }
    let primary: CoffObject = generated.object;
    objects.append(primary);

    let inputs: Vector(LinkInput) = [];
    let supplied: Dict(String, Bool) = Dict();
    for (let extra = 0; extra < extra_files.length(); extra++) {
        let input = read_link_input(extra_files[extra]);
        if (input.missing || input.message.length() != 0) {
            let message = input.message;
            if (input.missing) { message = "Could not open '" + input.path + "'."; }
            print("LinkError: " + message);
            return false;
        }
        inputs.append(input);
        supplied.put(input.path, true);
    }
    let requested: Dict(String, Bool) = Dict();
    for (let lib = 0; lib < libraries.length(); lib++) {
        let name = libraries[lib];
        if (!is_archive_name(name) || requested.contains_key(name)) { continue; }
        requested.put(name, true);
        let input = find_link_library(name, library_paths);
        if (input.message.length() != 0) {
            print("LinkError: " + input.message);
            return false;
        }
        if (supplied.contains_key(input.path)) { continue; }
        if verbose { print("Found library: " + input.path); }
        inputs.append(input);
        supplied.put(input.path, true);
    }

    for (let i = 0; i < inputs.length(); i++) {
        let path = inputs[i].path;
        let data = inputs[i].bytes;
        if (is_archive_name(path)) {
            let decoded = read_archive(data);
            if (decoded.archive is null) {
                print("LinkError: '" + path + "': " + decoded.message + " at byte " + decoded.offset);
                return false;
            }
            let archive: CoffArchive = decoded.archive;
            archives.append(archive);
            archive_paths.append(path);
        } else {
            let decoded = read_coff(data);
            if (decoded.object is null) {
                print("LinkError: '" + path + "': " + decoded.message + " at byte " + decoded.offset);
                return false;
            }
            let object: CoffObject = decoded.object;
            objects.append(object);
        }
    }
    let initial = coff_collect_directives(objects);
    if (initial.errors.length() != 0) {
        for (let bad = 0; bad < initial.errors.length(); bad++) {
            print("LinkError: Object " + initial.errors[bad].object + ": " + initial.errors[bad].message);
        }
        return false;
    }
    let selected = ArchiveSelection();
    if (archives.length() == 0 && initial.libraries.length() == 0) {
        selected = extract_archives(objects, archives);
    } else {
        let state = begin_archive_work(objects);
        if (state.errors.length() != 0) { selected = ArchiveSelection(errors=state.errors); }
        else {
            let discovery = LinkLibraries(archives=archives, paths=archive_paths, supplied=supplied);
            for (let explicit = 0; explicit < archives.length(); explicit++) { discovery.default_keys.append(""); }
            while true {
                if (!discover_default_libraries(ref discovery, state.directives, library_paths, verbose)) { return false; }
                let enabled = active_link_libraries(discovery, state.directives);
                selected = resume_archive_work(ref state, discovery.archives, enabled);
                if (!selected.pending_libraries || selected.errors.length() != 0) { break; }
            }
            archive_paths = discovery.paths;
        }
    }
    if (selected.errors.length() != 0) {
        for (let e = 0; e < selected.errors.length(); e++) {
            let diagnostic = selected.errors[e];
            if (selected.library >= 0) {
                print("LinkError: '" + archive_paths[selected.library] + "' at byte " + diagnostic.offset + ": " + diagnostic.message);
            } else {
                print("LinkError: Object " + diagnostic.object + ": " + diagnostic.message);
            }
        }
        return false;
    }
    objects = selected.objects;
    let requests: Vector(PeImport) = [];
    for (let src = 0; src < imports.length(); src++) { requests.append(imports[src]); }
    for (let imp = 0; imp < selected.imports.length(); imp++) { requests.append(selected.imports[imp]); }

    let entry = "mainCRTStartup";
    if shared { entry = "DllMainCRTStartup"; }
    let image_name = output;
    for (let part = output.length() - 1; part >= 0; part--) {
        if (output[part] == '/' || output[part] == '\\') {
            image_name = output.slice(part + 1, output.length());
            break;
        }
    }
    if verbose { print("Linking PE image with White"); }
    let linked = write_pe(objects, PeOptions(entry=entry, imports=requests, exports=exports, image_name=image_name, is_dll=shared, libraries_ready=true, gc_sections=gc_sections));
    if (linked.errors.length() != 0) {
        for (let e = 0; e < linked.errors.length(); e++) {
            let diagnostic = linked.errors[e];
            print("LinkError: Object " + diagnostic.object + ", section " + diagnostic.section + ": " + diagnostic.message);
        }
        return false;
    }
    let image = linked.image;
    if (image is null) {
        print("LinkError: No PE image was produced.");
        return false;
    }
    let ready: PeImage = image;
    let library: Vector(Byte) = [];
    let library_path = "";
    if shared {
        let encoded = write_import_library(image_name, ready.exports);
        if (encoded.message.length() != 0) {
            print("LinkError: " + encoded.message);
            return false;
        }
        library = encoded.bytes;
        library_path = windows_implib_path(output);
    }

    // finish both encodings before touching either destination, I/O failures still fail the build.
    if (!write_link_output(output, ready.bytes)) { return false; }
    if (shared && !write_link_output(library_path, library)) { return false; }
    return true;
}
