import SwiftUI
import AVKit

struct AudioPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0.0
    @State private var duration: Double = 0.0
    
    // Timer to update scrub bar
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 20) {
            // Big Audio Icon
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 150, height: 150)
                .foregroundColor(.havenPurple)
                .shadow(color: .havenPurple.opacity(0.3), radius: 10, x: 0, y: 5)
            
            // Audio info
            VStack(spacing: 4) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal)
                
                Text(url.pathExtension.isEmpty ? "Audio File" : url.pathExtension.uppercased())
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Scrubber
            VStack(spacing: 8) {
                Slider(value: $progress, in: 0...(duration > 0 ? duration : 1), onEditingChanged: { editing in
                    if !editing {
                        let targetTime = CMTime(seconds: progress, preferredTimescale: 600)
                        player?.seek(to: targetTime)
                    }
                })
                .accentColor(.havenPurple)
                
                HStack {
                    Text(formatTime(progress))
                    Spacer()
                    Text(formatTime(duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 40)
            
            // Controls
            HStack(spacing: 30) {
                Button(action: {
                    seek(seconds: -15)
                }) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                
                Button(action: togglePlayPause) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.havenPurple)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    seek(seconds: 15)
                }) {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(30)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
        .cornerRadius(20)
        .shadow(radius: 10)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .onReceive(timer) { _ in
            guard let player = player else { return }
            if isPlaying {
                progress = player.currentTime().seconds
            }
        }
    }
    
    private func setupPlayer() {
        let newPlayer = AVPlayer(url: url)
        
        // Use KVO to get duration as soon as it's ready
        Task {
            if let duration = try? await newPlayer.currentItem?.asset.load(.duration) {
                await MainActor.run {
                    self.duration = duration.seconds
                }
            }
        }
        
        // Auto-play
        newPlayer.play()
        self.player = newPlayer
        self.isPlaying = true
    }
    
    private func togglePlayPause() {
        guard let player = player else { return }
        
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
    
    private func seek(seconds: Double) {
        guard let player = player else { return }
        let currentTime = player.currentTime().seconds
        let newTime = max(0, min(currentTime + seconds, duration))
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
        progress = newTime
    }
    
    private func formatTime(_ seconds: Double) -> String {
        if seconds.isNaN || seconds.isInfinite {
            return "0:00"
        }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
