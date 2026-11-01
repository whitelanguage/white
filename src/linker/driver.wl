// src/linker/driver.wl
import "file"
import CoffObject from "coff/model.wl"
import read_coff from "coff/reader.wl"
import PeImport, PeExport, PeOptions, PeImage from "pe/model.wl"
import write_pe from "pe/writer.wl"


func link_windows(bytes: Vector(Byte), extra_files: Vector(String), imports: Vector(PeImport), exports: Vector(PeExport), output: String, shared: Bool, verbose: Bool) -> Bool {
// decode every input before opening the output, malformed objects must leave an existing image untouched
    for (let request = 0; request < imports.length(); request++) {
        let dll = imports[request].dll;
        if (dll.ends_with(".lib") || dll.ends_with(".a")) {
            print("LinkError: Archive declaration '" + dll + "' is not supported by --linker=white, declare a DLL or use --linker=clang.");
            return false;
        }
    }
    let objects: Vector(CoffObject) = [];
    let generated = read_coff(bytes);
    if (generated.object is null) {
        print("LinkError: Generated COFF object: " + generated.message);
        return false;
    }
    objects.append(generated.object);

    for (let i = 0; i < extra_files.length(); i++) {
        let path = extra_files[i];
        let input = file.open(path)?;
        catch(err) {
            print("LinkError: Could not open '" + path + "'.");
            return false;
        }
        let content = input.read_all()?;
        catch(err) {
            input.close();
            print("LinkError: Could not read '" + path + "'.");
            return false;
        }
        input.close();

        // file buffers carry a byte length, COFF bytes are never decoded as UTF-8 here
        let data: Vector(Byte) = [];
        for (let b = 0; b < content.length(); b++) { data.append(content[b]); }
        let decoded = read_coff(data);
        if (decoded.object is null) {
            print("LinkError: '" + path + "': " + decoded.message + " at byte " + decoded.offset);
            return false;
        }
        objects.append(decoded.object);
    }

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
    let linked = write_pe(objects, PeOptions(entry=entry, imports=imports, exports=exports, image_name=image_name, is_dll=shared));
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

    let target = file.create(output)?;
    catch(err) {
        print("LinkError: Could not create '" + output + "'.");
        return false;
    }
    target.write_bytes(ready.bytes)?;
    catch(err) {
        target.close();
        print("LinkError: Could not write '" + output + "'.");
        return false;
    }
    target.close_checked()?;
    catch(err) {
        print("LinkError: Could not close '" + output + "'.");
        return false;
    }
    return true;
}
