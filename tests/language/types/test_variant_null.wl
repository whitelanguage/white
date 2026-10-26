// Test: VARIANT_NULL_TAGS
// File: tests/language/types/test_variant_null.wl
// Focus: Distinct Null and nullptr keys, checked pointer recovery, and rehashing.

func exercise() -> Bool {
    let values = Dict(1);
    values.put(null, null);
    values.put(nullptr, nullptr);
    if (values.size != 2) { return false; }

    let absent: Null = values.get(null)?;
    catch(err) { return false; }
    let raw: AnyPtr = values.get(nullptr)?;
    catch(err) { return false; }
    let ptr empty: Int = values.get(nullptr)?;
    catch(err) { return false; }
    if (absent is !null || raw is !nullptr || empty is !nullptr) { return false; }

    let number = 42;
    let ptr address: Int = ref number;
    values.put("pointer", address);
    let ptr restored: Int = values.get("pointer")?;
    catch(err) { return false; }
    if (restored != address) { return false; }

    let i = 0;
    while (i < 100) {
        values.put(i, i);
        i++;
    }
    if (!values.contains_key(null) || !values.contains_key(nullptr)) { return false; }
    values.remove(null);
    if (values.contains_key(null) || !values.contains_key(nullptr)) { return false; }
    values.put(null, "Null");
    let text: String = values.get(null)?;
    catch(err) { return false; }
    if (text != "Null") { return false; }
    values.remove(nullptr);
    return values.contains_key(null) && !values.contains_key(nullptr);
}

func main() -> Int {
    let inferred = {"absent": null, "pointer": nullptr};
    let absent: Null = inferred.get("absent")?;
    catch(err) { return 1; }
    let raw: AnyPtr = inferred.get("pointer")?;
    catch(err) { return 1; }
    let empty: Auto = {};
    empty.put(null, 1);
    if (absent is !null || raw is !nullptr || empty.size != 1) { return 1; }

    if (!exercise()) {
        print("FAIL: Variant Null and nullptr tags");
        return 1;
    }
    print("PASS: Variant Null and nullptr tags");
    return 0;
}
