// Test: VECTOR_ERROR
// File: tests/language/collections/test_vector_error.wl
// Focus: Releasing a vector's initialized prefix when an element fails.

let dropped: Int = 0;

error Failure { Stop }

class Probe {
    deinit() { dropped++; }
}

func fail() -> Probe? {
    throw Failure.Stop;
}

func propagate() -> Void? {
    let values: Vector(Probe) = [Probe(), fail()?];
    return;
}

func main() -> Int {
    let values: Vector(Probe) = [Probe(), fail()?];
    catch(err) {
        if (dropped != 1) { return 1; }
    }

    let nested: Vector(Vector(Probe)) = [[Probe()], [Probe(), fail()?]];
    catch(err) {
        if (dropped != 3) { return 2; }
    }

    propagate()?;
    catch(err) {
        if (dropped != 4) { return 3; }
    }

    {
        let complete: Vector(Probe) = [Probe(), Probe()];
        if (complete.length() != 2) { return 4; }
    }
    if (dropped != 6) { return 5; }

    let empty_prefix: Vector(Probe) = [fail()?];
    catch(err) {
        if (dropped != 6) { return 6; }
    }

    let i: Int = 0;
    while (i < 3) {
        let partial: Vector(Probe) = [Probe(), fail()?];
        catch(err) {
            i++;
            continue;
        }
        return 7;
    }
    if (dropped != 9) { return 8; }

    print("PASS: vector error cleanup");
    return 0;
}
