import Foundation

struct RelayLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
}
