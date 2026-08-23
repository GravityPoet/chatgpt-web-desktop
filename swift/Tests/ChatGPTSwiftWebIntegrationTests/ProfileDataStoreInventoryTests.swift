import XCTest
@testable import ChatGPTSwiftWeb

final class ProfileDataStoreInventoryTests: XCTestCase {
    func testFindsOnlyIdentifiersNotBackedByAnActiveProfile() {
        let active = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let orphan = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let result = ProfileDataStoreInventory.orphanedIdentifiers(
            allIdentifiers: [orphan, active],
            activeProfileIDs: ["default", active.uuidString]
        )

        XCTAssertEqual(result, [orphan])
    }

    func testDeduplicatesAndSortsOrphanedIdentifiers() {
        let later = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let earlier = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let result = ProfileDataStoreInventory.orphanedIdentifiers(
            allIdentifiers: [later, earlier, later],
            activeProfileIDs: ["not-a-uuid"]
        )

        XCTAssertEqual(result, [earlier, later])
    }
}
