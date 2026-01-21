import Foundation
import Combine

class StatsService: ObservableObject {
    @Published var storageSize: Int64 = 0
    @Published var mediaSize: Int64 = 0
    @Published var loadedNotesCount: Int = 0
    
    private var nostrService = NostrService.shared
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Observe NostrService for note counts
        nostrService.$events // Although 'events' is not published directly in NostrService (it says "manually notified")
            // NostrService says "willChange.send()" on eventUpdateSubject sink.
            // So we can observe objectWillChange or hook into it?
            // Actually NostrService.swift says:
            // self.objectWillChange.send()
            // So we can just observe nostrService
        
        nostrService.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.loadedNotesCount = self?.nostrService.events.count ?? 0
                }
            }
            .store(in: &cancellables)
            
        refreshStats()
    }
    
    func refreshStats() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let relayDir = home.appendingPathComponent("haven_relay")
            let blossomDir = relayDir.appendingPathComponent("blossom")
            
            let storage = self?.calculateSize(of: relayDir) ?? 0
            let media = self?.calculateSize(of: blossomDir) ?? 0
            
            DispatchQueue.main.async {
                self?.storageSize = storage
                self?.mediaSize = media
            }
        }
    }
    
    private func calculateSize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            // Skip the blossom directory for the main storage count to avoid double counting if desired?
            // "Storage Used" usually implies *total* used by the app.
            // "Media Storage" is a subset.
            // I'll count total for storage, and specific for media.
            if let attributes = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = attributes.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
    
    var formattedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: storageSize, countStyle: .file)
    }
    
    var formattedMediaSize: String {
        ByteCountFormatter.string(fromByteCount: mediaSize, countStyle: .file)
    }
}
