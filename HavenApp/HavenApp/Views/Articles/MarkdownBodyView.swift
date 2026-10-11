import SwiftUI

// MARK: - Markdown body

/// Renders the block subset produced by `MarkdownParser`.
///
/// Inline emphasis is handed to `AttributedString`'s markdown initializer,
/// which covers bold/italic/links; anything it rejects falls back to the raw
/// text rather than dropping the line.
struct MarkdownBodyView: View {
    let markdown: String
    var onImageTap: ((URL) -> Void)? = nil
    /// Set while the reader is in highlight mode: text blocks become tappable
    /// and hand back their plain text.
    var onHighlight: ((String) -> Void)? = nil
    /// Other people's highlights, keyed by block id: those blocks get a tint
    /// and a count that opens them.
    var highlights: [String: [ArticleHighlight]] = [:]
    var onShowHighlights: (([ArticleHighlight]) -> Void)? = nil

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block {
                case .heading(let level, let text):
                    inlineText(text)
                        .font(.appSystem(size: headingSize(level), weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .highlightable(text, onHighlight, shown: highlights[block.id] ?? [], onShow: onShowHighlights)
                        .padding(.top, level <= 2 ? 8 : 2)

                case .paragraph(let text):
                    inlineText(text)
                        .font(.appSystem(size: 16))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .highlightable(text, onHighlight, shown: highlights[block.id] ?? [], onShow: onShowHighlights)

                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(.appSystem(size: 16, weight: .bold)).foregroundColor(.havenPurple)
                        inlineText(text).font(.appSystem(size: 16)).fixedSize(horizontal: false, vertical: true)
                    }
                    .highlightable(text, onHighlight, shown: highlights[block.id] ?? [], onShow: onShowHighlights)

                case .ordered(let index, let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index).")
                            .font(.appSystem(size: 16, weight: .bold))
                            .foregroundColor(.havenPurple)
                            .monospacedDigit()
                        inlineText(text).font(.appSystem(size: 16)).fixedSize(horizontal: false, vertical: true)
                    }
                    .highlightable(text, onHighlight, shown: highlights[block.id] ?? [], onShow: onShowHighlights)

                case .quote(let text):
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle().fill(Color.havenPurple).frame(width: 3)
                        inlineText(text)
                            .font(.appSystem(size: 16))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .highlightable(text, onHighlight, shown: highlights[block.id] ?? [], onShow: onShowHighlights)

                case .code(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.appSystem(size: 13, design: .monospaced))
                            .padding(10)
                    }
                    .background(Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                case .image(let url):
                    RetryableAsyncImage(url: url, contentMode: .fill, targetSize: CGSize(width: 900, height: 600))
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onTapGesture { onImageTap?(url) }

                case .rule:
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 24
        case 2: return 20
        case 3: return 18
        default: return 16
        }
    }

    @ViewBuilder
    private func inlineText(_ text: String) -> some View {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed).textSelection(.enabled)
        } else {
            Text(text).textSelection(.enabled)
        }
    }
}

private extension View {
    /// In highlight mode, tint the block and make the whole of it a tap target
    /// that reports its text without markdown.
    ///
    /// Outside highlight mode, a block other people highlighted gets a soft
    /// yellow tint and a count under it that opens who highlighted it.
    @ViewBuilder
    func highlightable(_ markdown: String, _ onHighlight: ((String) -> Void)?,
                       shown: [ArticleHighlight] = [], onShow: (([ArticleHighlight]) -> Void)? = nil) -> some View {
        if let onHighlight {
            self
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.havenPurple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { onHighlight(ArticleEngagement.plainText(markdown)) }
        } else if !shown.isEmpty {
            VStack(alignment: .trailing, spacing: 4) {
                self
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button { onShow?(shown) } label: {
                    Label("\(shown.count)", systemImage: "highlighter")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.yellow.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(shown.count == 1 ? "1 highlight" : "\(shown.count) highlights"))
            }
        } else {
            self
        }
    }
}
