import SwiftUI
import UniformTypeIdentifiers

class MediaUploadsIndicatorInfoProvider: ObservableObject {
    @Published var isUploading: Bool = false
    @Published var totalCount: Int = 0
    @Published var currentIndex: Int = 0
    @Published var uploadMessage: String? = nil
    @Published var currentProgress: Double = 0.0
    private var currentType: UTType = .image
    
    func startUpload(totalCount: Int) {
        DispatchQueue.main.async {
            self.isUploading = true
            self.totalCount = totalCount
            self.currentIndex = 0
            self.currentProgress = 0.0
            self.uploadMessage = totalCount > 0 ? "Preparing uploads..." : nil
        }
    }
    
    func setCurrentIndex(_ index: Int, type: UTType) {
        DispatchQueue.main.async {
            self.currentIndex = index
            self.currentType = type
            self.currentProgress = 0.0
            self.updateMessage()
        }
    }
    
    func updateProgress(_ progress: Double) {
        DispatchQueue.main.async {
            self.currentProgress = progress
            self.updateMessage()
        }
    }
    
    private func updateMessage() {
        let isVideo = self.currentType.conforms(to: .movie) || self.currentType.conforms(to: .video)
        let mediaType = isVideo ? "video" : "image"
        let pct = Int(self.currentProgress * 100)
        if self.totalCount > 1 {
            self.uploadMessage = "Uploading \(mediaType) (\(self.currentIndex) of \(self.totalCount)) - \(pct)%..."
        } else {
            self.uploadMessage = "Uploading \(mediaType) - \(pct)%..."
        }
    }
    
    func reset() {
        DispatchQueue.main.async {
            self.isUploading = false
            self.totalCount = 0
            self.currentIndex = 0
            self.currentProgress = 0.0
            self.uploadMessage = nil
        }
    }
}
