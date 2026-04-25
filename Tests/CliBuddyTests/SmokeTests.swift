import Testing

@Suite struct SmokeTests {
    @Test func trivial() {
        #expect(1 + 1 == 2)
    }
}
