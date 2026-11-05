// Test: FALLIBLE_RETURN_CONTEXT
// File: tests/language/errors/test_fallible_return_context.wl
// Focus: Success values infer their type before being wrapped in a fallible result.

struct Cell<T>(value: Optional(T) = null)
struct Pair(values: Int[2])

let dropped: Int = 0;

class Probe {
    deinit() {
        dropped++;
    }
}

class Source {
    func values() -> Vector(String)? {
        return [];
    }
}

func empty_strings() -> Vector(String)? {
    return [];
}

func strings() -> Vector(String)? {
    return ["white"];
}

func empty_dict() -> Dict(String, Int)? {
    return {};
}

func constructed_dict() -> Dict(String, Int)? {
    return Dict();
}

func empty_cell() -> Cell(String)? {
    return Cell();
}

func optional_strings(absent: Bool) -> Optional(Vector(String))? {
    if absent {
        return null;
    }
    return [];
}

func number() -> UInt64? {
    return 1;
}

func small() -> Byte? {
    return 42;
}

func negative() -> Int8? {
    return -7;
}

func fraction() -> Float32? {
    return 1.5;
}

func fixed() -> Int[2]? {
    return [3, 4];
}

func fixed_value() -> Int[2] {
    return [5, 6];
}

func fixed_call() -> Int[2]? {
    return fixed_value();
}

func fixed_local() -> Int[2]? {
    let values: Int[2] = [7, 8];
    return values;
}

func fixed_field() -> Int[2]? {
    let pair = Pair([9, 10]);
    return pair.values;
}

func owned_values() -> Vector(Probe)? {
    return [Probe()];
}

func fixed_words() -> String[2]? {
    return ["white", "language"];
}

func fixed_probes() -> Probe[2]? {
    return [Probe(), Probe()];
}

func check_fixed_owner() -> Bool {
    let words = fixed_words()?;
    catch(err) { return false; }
    let probes = fixed_probes()?;
    catch(err) { return false; }
    return words[0] == "white" && words[1] == "language";
}

func check_owner() -> Bool {
    let values = owned_values()?;
    catch(err) { return false; }
    return values.length() == 1;
}

func main() -> Int {
    let empty = empty_strings()?;
    catch(err) { return 1; }
    let words = strings()?;
    catch(err) { return 1; }
    let map = empty_dict()?;
    catch(err) { return 1; }
    let constructed = constructed_dict()?;
    catch(err) { return 1; }
    let cell = empty_cell()?;
    catch(err) { return 1; }
    let present = optional_strings(false)?;
    catch(err) { return 1; }
    let absent = optional_strings(true)?;
    catch(err) { return 1; }
    if (empty.length() != 0 || words.length() != 1 || words[0] != "white" ||
        map.size != 0 || constructed.size != 0 || cell.value is !null ||
        present is null || absent is !null) {
        return 1;
    }
    if (present.length() != 0) { return 1; }

    let unsigned_value = number()?;
    catch(err) { return 1; }
    let byte_value = small()?;
    catch(err) { return 1; }
    let signed_value = negative()?;
    catch(err) { return 1; }
    let float_value = fraction()?;
    catch(err) { return 1; }
    let array = fixed()?;
    catch(err) { return 1; }
    let from_call = fixed_call()?;
    catch(err) { return 1; }
    let from_local = fixed_local()?;
    catch(err) { return 1; }
    let from_field = fixed_field()?;
    catch(err) { return 1; }
    if (unsigned_value != 1UL || byte_value != Byte(42) || signed_value != Int8(-7) ||
        float_value != 1.5f || array[0] != 3 || array[1] != 4) {
        return 1;
    }
    if (from_call[0] != 5 || from_call[1] != 6 || from_local[0] != 7 ||
        from_local[1] != 8 || from_field[0] != 9 || from_field[1] != 10) {
        return 1;
    }

    func local() -> UInt64? {
        return 1;
    }
    let local_value = local()?;
    catch(err) { return 1; }
    if (local_value != 1UL) { return 1; }
    let source = Source();
    let method_values = source.values()?;
    catch(err) { return 1; }
    if (local_value != 1UL || method_values.length() != 0) { return 1; }
    if (!check_owner() || dropped != 1) { return 1; }
    if (!check_fixed_owner() || dropped != 3) { return 1; }

    print("PASS: fallible return context");
    return 0;
}
