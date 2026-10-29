// tests/fixtures/native_storage.wl
import "process"


struct TextRecord(text: String)
struct BoolRecord(flag: Bool)
struct BoolArray(flags: Bool[3])
struct CharRecord(letter: Char)
struct FailureRecord(result: Void?)
enum StorageKind { Text, Flag }
struct KindRecord(kind: StorageKind)

class TextObject {
    let text: String = "valid";
}
class FlagObject {
    let flag: Bool = true;
}

extern "C" {
    func native_missing_slot() -> ptr String;
    func native_echo_slot(slot: AnyPtr) -> AnyPtr;
    func native_write_bool(slot: AnyPtr) -> Void;
    func native_missing_record() -> ptr TextRecord;
    func native_invalid_optional() -> ptr Optional(String);
    func native_absent_optional() -> ptr Optional(String);
    func native_bool_slot() -> ptr Bool;
    func native_bool_record() -> ptr BoolRecord;
    func native_bool_array() -> ptr BoolArray;
    func native_bool_optional() -> ptr Optional(Bool);
    func native_inactive_bool() -> ptr Optional(Bool);
    func native_char_slot() -> ptr Char;
    func native_char() -> Char;
    func native_valid_char() -> Char;
    func native_char_out_of_range() -> Char;
    func native_char_record() -> ptr CharRecord;
    func native_bad_char_export() -> Int;
    func native_good_char_export() -> Int;
    func native_unknown_error() -> Void?;
    func native_failure_slot() -> ptr FailureRecord;
}

@ExportLib
func exported_native_char(value: Char) -> Int {
    if (UInt32(value) == 1114111U) { return 17; }
    return 0;
}

func main(argc: Int, ptr argv: String) -> Int {
    if (argc > 1) {
        let mode = process.argument(argc, argv, 1);
        if (mode is null) { return 9; }
        if (mode == "deref") {
            let ptr slot: String = native_missing_slot();
            let value = deref slot;
        } else if (mode == "index") {
            let ptr slot: String = native_missing_slot();
            let value = slot[0];
        } else if (mode == "field") {
            let ptr record: TextRecord = native_missing_record();
            let value = record.text;
        } else if (mode == "record") {
            let ptr record: TextRecord = native_missing_record();
            let value = deref record;
        } else if (mode == "union") {
            let ptr slot: Optional(String) = native_invalid_optional();
            let value = deref slot;
        } else if (mode == "bool") {
            let ptr slot: Bool = native_bool_slot();
            let value = deref slot;
        } else if (mode == "bool-index") {
            let ptr slot: Bool = native_bool_slot();
            let value = slot[0];
        } else if (mode == "bool-field") {
            let ptr record: BoolRecord = native_bool_record();
            let value = record.flag;
        } else if (mode == "bool-record") {
            let ptr record: BoolRecord = native_bool_record();
            let value = deref record;
        } else if (mode == "bool-array") {
            let ptr record: BoolArray = native_bool_array();
            let value = deref record;
        } else if (mode == "bool-optional") {
            let ptr slot: Optional(Bool) = native_bool_optional();
            let value = deref slot;
        } else if (mode == "bool-object") {
            let object = FlagObject();
            native_write_bool(ref object.flag);
            let ptr slot: FlagObject = native_echo_slot(ref object);
            let value = slot.flag;
        } else if (mode == "char") {
            let ptr slot: Char = native_char_slot();
            let value = slot[0];
        } else if (mode == "char-return") {
            let value = native_char();
        } else if (mode == "char-callable") {
            let callback = native_char;
            let value = callback();
        } else if (mode == "char-export") {
            native_bad_char_export();
        } else if (mode == "char-range") {
            let value = native_char_out_of_range();
        } else if (mode == "char-record") {
            let ptr record: CharRecord = native_char_record();
            let value = deref record;
        } else if (mode == "failure") {
            let ptr slot: FailureRecord = native_failure_slot();
            let value = deref slot;
        }
        print("FAIL: invalid native storage was accepted", mode);
        return 1;
    }

    let text = "valid";
    let ptr slot: String = native_echo_slot(ref text);
    let copy = deref slot;
    if (copy != text || slot[0] != text) { return 2; }
    let record = TextRecord(text);
    let ptr address: TextRecord = native_echo_slot(ref record);
    if (address.text != text || (deref address).text != text) { return 3; }
    let object = TextObject();
    let ptr object_slot: TextObject = native_echo_slot(ref object);
    if (object_slot.text != text) { return 10; }
    let kind = KindRecord(StorageKind.Flag);
    let ptr kind_slot: KindRecord = native_echo_slot(ref kind);
    if ((deref kind_slot).kind != StorageKind.Flag) { return 12; }
    let ptr absent: Optional(String) = native_absent_optional();
    let nothing = deref absent;
    if (nothing is !null) { return 4; }
    let ptr inactive: Optional(Bool) = native_inactive_bool();
    if ((deref inactive) is !null) { return 11; }
    let flag = true;
    let ptr flag_slot: Bool = native_echo_slot(ref flag);
    if (!(deref flag_slot)) { return 5; }
    let letter = '你';
    let ptr char_slot: Char = native_echo_slot(ref letter);
    if (char_slot[0] != letter || UInt32(native_valid_char()) != 1114111U) { return 6; }
    if (native_good_char_export() != 17) { return 8; }
    let direct_error = false;
    native_unknown_error()?;
    catch(err) {
        print(err);
        direct_error = true;
    }
    let callback = native_unknown_error;
    let indirect_error = false;
    callback()?;
    catch(err) {
        print(err);
        indirect_error = true;
    }
    if (!direct_error || !indirect_error) { return 7; }
    print("PASS: raw storage and native scalar boundaries");
    return 0;
}
