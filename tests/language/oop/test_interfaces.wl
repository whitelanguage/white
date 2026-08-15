// Test: INTERFACE_POLYMORPHISM_AND_MULTIPLE_COMPLIANCE
// File: tests/language/oop/test_interfaces.wl
// Focus: Interface implementation, dynamic dispatch (vtable routing), and multiple interface compliance.


interface Drawable {
    func draw() -> Void;
}

interface Resizable {
    func resize(factor: Float) -> Void;
}

class Circle with Drawable {
    func draw() -> Void { }
}

class Square with Drawable {
    func draw() -> Void { }
}

class Sprite with Drawable, Resizable {
    let size: Float = 0.0;

    init(size: Float) {
        self.size = size;
    }

    func draw() -> Void {
        // No-op
    }

    func resize(factor: Float) -> Void {
        self.size = self.size * factor;
    }
}

func get_drawable(is_circle: Bool) -> Drawable {
    if is_circle {
        return Circle();
    }
    return Square();
}

func main() -> Int {
    // basic Interface dispatch
    let c: Circle = Circle();
    let sq: Square = Square();
    let d1: Drawable = c;
    let d2: Drawable = sq;
    // ensure internal vtable routing does not crash
    d1.draw();
    d2.draw();

    // interface as parameter & return
    let d3: Drawable = get_drawable(true);
    let d4: Drawable = get_drawable(false);
    d3.draw();
    d4.draw();

    // Arrays
    let arr: Drawable[4] = [Circle(), Square(), Circle(), Square()];
    let arr_ok: Bool = (arr.length() == 4);

    // multiple Interfaces
    let sp: Sprite = Sprite(10.0);
    let d_sp: Drawable = sp;
    let r_sp: Resizable = sp;
    
    d_sp.draw();
    r_sp.resize(2.5); // resize 10.0 -> 25.0

    let sprite_ok: Bool = (sp.size == 25.0);

    if (arr_ok && sprite_ok) {
        print("PASS: Interface polymorphism and multiple compliance");
        return 0;
    } else {
        print("FAIL: VTable routing or interface compliance error");
        return 1;
    }
}