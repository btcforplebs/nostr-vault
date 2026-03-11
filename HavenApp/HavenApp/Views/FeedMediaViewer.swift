import SwiftUI
import AVKit

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct FeedMediaViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            let ext = url.pathExtension.lowercased()
            let isVideo = ["mp4", "mov", "webm", "m4v"].contains(ext)
            
            if isVideo {
                VideoPlayerView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .tint(.white)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        let delta = value / lastScale
                                        lastScale = value
                                        scale *= delta
                                    }
                                    .onEnded { _ in
                                        lastScale = 1.0
                                        if scale < 1.0 {
                                            withAnimation(.spring()) {
                                                scale = 1.0
                                                offset = .zero
                                            }
                                        }
                                    }
                            )
                            .simultaneousGesture(
                                DragGesture()
                                    .onChanged { value in
                                        if scale > 1.0 {
                                            offset = CGSize(
                                                width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height
                                            )
                                        }
                                    }
                                    .onEnded { _ in
                                        lastOffset = offset
                                        if scale <= 1.0 {
                                            withAnimation(.spring()) {
                                                offset = .zero
                                                lastOffset = .zero
                                            }
                                        }
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.spring()) {
                                    if scale > 1.0 {
                                        scale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    } else {
                                        scale = 2.0
                                    }
                                }
                            }
                    case .failure:
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.orange)
                            Text("Failed to load image")
                                .foregroundColor(.white)
                                .font(.headline)
                            Text(url.absoluteString)
                                .foregroundColor(.secondary)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(20)
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
    }
}
