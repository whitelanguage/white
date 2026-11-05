// tests/fixtures/modules/environment/consumer.wl
import "provider.wl" as provider


const OFFSET: Int = 101;

func calculate() -> Int {
    let box = provider.wrap("white");
    return provider.read(box) + OFFSET;
}
