// src/linker/coff/directives.wl
import "strings"
import * from "model.wl"
import * from "link_model.wl"
import coff_name_matches, coff_range from "reader.wl"
import PeExport from "../pe/model.wl"


struct CoffDirectiveToken(text: String, offset: Int)
struct CoffDirectiveTokens(tokens: Vector(CoffDirectiveToken) = [], message: String = "", offset: Int = 0)
struct CoffDirectives(
    roots: Vector(String) = [],
    root_names: Dict(String, Bool) = Dict(),
    exports: Vector(PeExport) = [],
    export_names: Dict(String, Int) = Dict(),
    matches: Dict(String, String) = Dict(),
    errors: Vector(CoffLinkError) = []
)

func coff_directive_space(byte: Byte) -> Bool {
    return byte == Byte(0) || byte == Byte(32) || (byte >= Byte(9) && byte <= Byte(13));
}

func coff_directive_tokens(object: CoffObject, span: CoffSpan) -> CoffDirectiveTokens {
// Windows quoting applies to every argument, there is no executable-name token here
    if (!coff_range(object.bytes.length(), Long(span.offset), Long(span.size), 1)) {
        return CoffDirectiveTokens(message="Invalid COFF directive data span", offset=span.offset);
    }
    let result = CoffDirectiveTokens();
    let end = span.offset + span.size;
    let pos = span.offset;
    let utf8 = false;
    if (span.size >= 3 && object.bytes[pos] == Byte(239) && object.bytes[pos + 1] == Byte(187) && object.bytes[pos + 2] == Byte(191)) {
        pos += 3;
        utf8 = true;
    }
    while (pos < end) {
        while (pos < end && coff_directive_space(object.bytes[pos])) { pos++; }
        if (pos == end) { break; }
        let start = pos;
        let quoted = false;
        let text = strings.Builder(64);
        while (pos < end) {
            let byte = object.bytes[pos];
            if (!quoted && coff_directive_space(byte)) { break; }
            if (byte == Byte(0) || (byte < Byte(32) && !coff_directive_space(byte))) {
                return CoffDirectiveTokens(message="Invalid control byte in COFF directive", offset=pos);
            }
            if (!utf8 && byte >= Byte(128)) {
                return CoffDirectiveTokens(message="Non-ASCII COFF directives require a UTF-8 BOM", offset=pos);
            }
            if (byte == Byte(92)) {
                let slashes = 0;
                while (pos < end && object.bytes[pos] == Byte(92)) { slashes++; pos++; }
                let count = slashes;
                if (pos < end && object.bytes[pos] == Byte(34)) { count /= 2; }
                for (let slash = 0; slash < count; slash++) {
                    text.write_byte(Byte(92))?;
                    catch(err) { return CoffDirectiveTokens(message="Could not allocate COFF directive token", offset=start); }
                }
                if (pos < end && object.bytes[pos] == Byte(34) && (slashes & 1) != 0) {
                    text.write_byte(Byte(34))?;
                    catch(err) { return CoffDirectiveTokens(message="Could not allocate COFF directive token", offset=start); }
                    pos++;
                }
                continue;
            }
            if (byte == Byte(34)) {
                if (quoted && pos + 1 < end && object.bytes[pos + 1] == Byte(34)) {
                    text.write_byte(Byte(34))?;
                    catch(err) { return CoffDirectiveTokens(message="Could not allocate COFF directive token", offset=start); }
                    pos += 2;
                } else {
                    quoted = !quoted;
                    pos++;
                }
                continue;
            }
            text.write_byte(byte)?;
            catch(err) { return CoffDirectiveTokens(message="Could not allocate COFF directive token", offset=start); }
            pos++;
        }
        if quoted { return CoffDirectiveTokens(message="Unterminated quote in COFF directive", offset=start); }
        let value = text.build()?;
        catch(err) { return CoffDirectiveTokens(message="Invalid UTF-8 or allocation failure in COFF directive", offset=start); }
        result.tokens.append(CoffDirectiveToken(value, start));
    }
    return result;
}

func coff_directive_is(text: String, spelling: String) -> Bool {
// only option spellings are folded, symbol names and mismatch values are case-sensitive
    if (text.length() != spelling.length()) { return false; }
    for (let i = 0; i < text.length(); i++) {
        let byte = Int(text[i]);
        if (byte >= 65 && byte <= 90) { byte += 32; }
        if (byte != Int(spelling[i])) { return false; }
    }
    return true;
}

func coff_directive_root(ref state: CoffDirectives, name: String) -> Void {
    if (state.root_names.contains_key(name)) { return; }
    state.root_names.put(name, true);
    state.roots.append(name);
}

func coff_directive_export(ref state: CoffDirectives, item: PeExport) -> Bool {
// repeated dllexport declarations are common in headers, contradictory metadata still fails
    let key = "n" + item.name;
    if (item.name.length() == 0) {
        let ordinal = item.ordinal;
        if (ordinal is null) { return false; }
        key = "o" + String(ordinal);
    }
    let found = state.export_names.lookup(key);
    if (found is !null) {
        let old_id: Int = found;
        let old = state.exports[old_id];
        let a = old.ordinal;
        let b = item.ordinal;
        if (old.symbol != item.symbol || (a is null) != (b is null)) { return false; }
        if (a is !null && b is !null && a != b) { return false; }
        state.exports[old_id].data = old.data || item.data;
    } else {
        state.export_names.put(key, state.exports.length());
        state.exports.append(item);
    }
    coff_directive_root(ref state, item.symbol);
    return true;
}

func coff_parse_export(ref state: CoffDirectives, argument: String) -> String {
    let split = 0;
    while (split < argument.length() && argument[split] != ',') { split++; }
    let head = argument.slice(0, split);
    let equal = 0;
    while (equal < head.length() && head[equal] != '=') { equal++; }
    let item = PeExport(name=head, symbol=head);
    if (equal < head.length()) {
        item.name = head.slice(0, equal);
        item.symbol = head.slice(equal + 1, head.length());
        for (let dot = 0; dot < item.symbol.length(); dot++) {
            if (item.symbol[dot] == '.') { return "Forwarded COFF exports are not supported yet"; }
        }
    }
    if (item.name.length() == 0 || item.symbol.length() == 0) { return "Invalid COFF export name or symbol"; }
    let noname = false;
    while (split < argument.length()) {
        let start = split + 1;
        split = start;
        while (split < argument.length() && argument[split] != ',') { split++; }
        let part = argument.slice(start, split);
        if (coff_directive_is(part, "noname") && !noname) { noname = true; }
        else if (coff_directive_is(part, "data") && !item.data) { item.data = true; }
        else if (part.length() > 1 && part[0] == '@' && item.ordinal is null) {
            let number = 0U;
            for (let digit = 1; digit < part.length(); digit++) {
                let byte = UInt32(part[digit]);
                if (byte < 48U || byte > 57U || number > (65535U - (byte - 48U)) / 10U) {
                    return "COFF export ordinal must be between 1 and 65535";
                }
                number = number * 10U + byte - 48U;
            }
            if (number == 0U) { return "COFF export ordinal must be between 1 and 65535"; }
            item.ordinal = number;
        } else {
            return "Unsupported or invalid COFF export attribute '" + part + "'";
        }
    }
    if noname {
        if (item.ordinal is null) { return "COFF NONAME export requires an ordinal"; }
        item.name = "";
    }
    if (!coff_directive_export(ref state, item)) { return "Conflicting COFF export declarations"; }
    return "";
}

func coff_add_directives(ref state: CoffDirectives, object: CoffObject, id: Int) -> Void {
// consume only loaded objects, an unused archive member cannot add roots or mismatch requirements
    for (let sec = 0; sec < object.sections.length(); sec++) {
        let section = object.sections[sec];
        if (!coff_name_matches(object, section.name, ".drectve")) { continue; }
        if ((section.flags & 512U) == 0U || (section.flags & 4096U) != 0U || section.relocs.length() != 0 ||
            section.lines.size != 0 || Long(section.data.size) != Long(section.size)) {
            state.errors.append(CoffLinkError(status=CoffLinkStatus.InvalidObject, object=id, section=sec,
                message="Invalid COFF directive section flags, data or relocation metadata"));
            return;
        }
        let parsed = coff_directive_tokens(object, section.data);
        if (parsed.message.length() != 0) {
            state.errors.append(CoffLinkError(status=CoffLinkStatus.InvalidObject, object=id, section=sec,
                offset=UInt32(parsed.offset), message=parsed.message));
            return;
        }
        for (let t = 0; t < parsed.tokens.length(); t++) {
            let token = parsed.tokens[t];
            let colon = 0;
            while (colon < token.text.length() && token.text[colon] != ':') { colon++; }
            let message = "";
            let status = CoffLinkStatus.InvalidObject;
            if (colon == token.text.length() || colon < 2 ||
                (token.text[0] != '/' && token.text[0] != '-')) {
                message = "Invalid COFF linker directive '" + token.text + "'";
            } else {
                let option = token.text.slice(1, colon);
                let argument = token.text.slice(colon + 1, token.text.length());
                if (argument.length() == 0) { message = "Missing COFF directive argument"; }
                else if (coff_directive_is(option, "include")) { coff_directive_root(ref state, argument); }
                else if (coff_directive_is(option, "export")) { message = coff_parse_export(ref state, argument); }
                else if (coff_directive_is(option, "failifmismatch")) {
                    let equal = 0;
                    while (equal < argument.length() && argument[equal] != '=') { equal++; }
                    if (equal == 0 || equal + 1 >= argument.length()) { message = "Invalid COFF mismatch requirement"; }
                    else {
                        let key = argument.slice(0, equal);
                        let value = argument.slice(equal + 1, argument.length());
                        let previous = state.matches.lookup(key);
                        if (previous is !null && previous != value) { message = "COFF mismatch requirement conflicts for '" + key + "'"; }
                        else { state.matches.put(key, value); }
                    }
                } else {
                    status = CoffLinkStatus.Unsupported;
                    message = "Unsupported COFF linker directive '" + option + "'";
                }
            }
            if (message.length() != 0) {
                state.errors.append(CoffLinkError(status=status, object=id, section=sec, offset=UInt32(token.offset), message=message));
                return;
            }
        }
    }
}

func coff_collect_directives(objects: Vector(CoffObject)) -> CoffDirectives {
    let result = CoffDirectives();
    for (let obj = 0; obj < objects.length(); obj++) {
        coff_add_directives(ref result, objects[obj], obj);
        if (result.errors.length() != 0) { break; }
    }
    return result;
}
