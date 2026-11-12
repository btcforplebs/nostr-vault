import Foundation

extension MeshKeySigner {
    /// A `/files` event signed with this device's mesh key, or nil (no mesh
    /// key yet, or not a `/files` event: `FileNote.meshKeyMaySign`). The file
    /// note (1063), its kind 5 and the room's AUTH (22242); the vault refuses
    /// the account key for all three (haven-go files_relay.go), so nothing
    /// else may sign them, and this still signs no posts.
    static func fileNotes(kind: Int, tags: [[String]], content: String = "") -> NostrEvent? {
        guard FileNote.meshKeyMaySign(kind: kind, tags: tags) else { return nil }
        return sign(kind: kind, content: content, tags: tags)
    }
}
