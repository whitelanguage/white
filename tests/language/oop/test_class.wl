// Test: OOP_CORE_LOGIC
// File: tests/language/oop/test_class.wl
// Focus: VTable method dispatch, field mutation, and class initialization.


struct Vector3(x: Int, y: Int, z: Int)

class BankAccount {
    let _id: Int = 0;
    let owner: String = null;
    let balance: Int = 0;

    init(id: Int, name: String, val: Int) -> Void {
        self._id = id;
        self.owner = name;
        self.balance = val;
    }

    func deposit(amount: Int) -> Void {
        self.balance = self.balance + amount;
    }

    func withdraw(amount: Int) -> Bool {
        if (self.balance >= amount) {
            self.balance = self.balance - amount;
            return true;
        }
        return false;
    }

    func get_balance() -> Int {
        return self.balance;
    }
}

func main() -> Int {
    let v: Vector3 = Vector3(10, 20, 30);
    if (v.z != 30) {
        print("FAIL: Struct field offset error");
        return 1;
    }

    let acc: BankAccount = BankAccount(1001, "dev_test_user", 500);
    
    acc.deposit(200);
    let deposit_ok: Bool = (acc.get_balance() == 700);

    let overdraw_blocked: Bool = (acc.withdraw(1000) == false);
    let valid_draw_ok: Bool = acc.withdraw(600);

    if (deposit_ok && overdraw_blocked && valid_draw_ok && acc.get_balance() == 100) {
        print("PASS: Class methods and state mutation");
    } else {
        print("FAIL: Class method or state result");
        return 1;
    }

    return 0;
}
