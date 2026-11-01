import Testing
@testable import stackd

/// The real Keychain must be unreachable from tests (an early test run once deleted the user's key).
@Suite struct KeychainGuardTests {
    @Test func keychainIsDisabledInTestProcess() throws {
        // Stop before touching anything if detection ever fails, so this test can't write a real item.
        try #require(KeychainStore.isDisabled)
        #expect(KeychainStore.loadAPIKey() == nil)
        #expect(KeychainStore.saveAPIKey("bxd_test_guard") == false)
    }
}
