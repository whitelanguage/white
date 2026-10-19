// Test: CATCH_TEMPORARIES
// File: tests/language/errors/test_catch_temps.wl
// Focus: Release nested call arguments on both paths before a continuing catch joins.

let dropped: Int = 0;

error Failure { Expected }

class Probe {
    deinit() { dropped++; }
}

struct Record(items: Vector(Probe), extra: Vector(Int))


func inspect(value: Record, fail: Bool) -> Int? {
    if fail { throw Failure.Expected; }
    return value.items.length();
}

func main() -> Int {
    let result: Int = 0;
    let caught: Bool = false;
    result = inspect(Record(items=[Probe()], extra=[]), true)?;
    catch(err) { caught = true; }
    if (!caught || result != 0 || dropped != 1) {
        print("FAIL: failed argument cleanup: ", dropped);
        return 1;
    }

    result = inspect(Record(items=[Probe(), Probe()], extra=[]), false)?;
    catch(err) { return 1; }
    if (result != 2 || dropped != 3) {
        print("FAIL: successful argument cleanup: ", dropped);
        return 1;
    }

    caught = false;
    inspect(Record(items=[Probe()], extra=[1, 2]), true)?;
    catch(err) { caught = true; }
    if (!caught || dropped != 4) {
        print("FAIL: discarded result cleanup: ", dropped);
        return 1;
    }

    print("PASS: catch temporary ownership");
    return 0;
}
