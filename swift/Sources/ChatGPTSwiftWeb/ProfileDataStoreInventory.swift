import Foundation

enum ProfileDataStoreInventory {
    static func orphanedIdentifiers(
        allIdentifiers: [UUID],
        activeProfileIDs: [String]
    ) -> [UUID] {
        let activeIdentifiers = Set(activeProfileIDs.compactMap(UUID.init(uuidString:)))
        return Array(Set(allIdentifiers).subtracting(activeIdentifiers))
            .sorted { $0.uuidString < $1.uuidString }
    }
}
