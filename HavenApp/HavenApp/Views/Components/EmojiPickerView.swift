import SwiftUI

/// The emoji picker. Reacting (`init(onSelect:)`), the editable quick bar
/// comes first and the tabs start with Recents, the account's own custom
/// emoji and each set it added (NIP-30/51, read only). Choosing the default
/// reaction (`init(onSelectEmoji:)`) offers Unicode only, as before.
/// Android: `EmojiPickerSheet.kt`.
struct EmojiPickerView: View {
    @Environment(\.presentationMode) var presentationMode
    private let reacting: Bool
    private let onSelect: (ReactionPick) -> Void

    @ObservedObject private var palette = EmojiPaletteStore.shared
    @ObservedObject private var emojiList = EmojiListService.shared

    @State private var searchText = ""
    @State private var customEmoji = ""
    @State private var selectedCategory = ""
    // Editing the quick bar: tap a slot, then any emoji to put there.
    @State private var editingBar = false
    @State private var editSlot: ReactionPick?

    /// Reacting to a note: custom emoji and the quick bar included.
    init(onSelect: @escaping (ReactionPick) -> Void) {
        reacting = true
        self.onSelect = onSelect
    }

    /// Choosing an emoji (the default reaction): Unicode only.
    init(onSelectEmoji: @escaping (String) -> Void) {
        reacting = false
        onSelect = { onSelectEmoji($0.content) }
    }
    
    // Standard quick reactions
    private let quickReactions = ["❤️", "👍", "🔥", "😂", "😮", "😢", "🎉", "🚀"]
    
    // Curated emoji lists categorized beautifully
    private let categories = [
        EmojiCategory(name: "Smileys", icon: "face.smiling.fill", emojis: [
            "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇", "🙂", "🙃", "😉", "😌", "😍", "🥰", 
            "😘", "😗", "😙", "😚", "😋", "😛", "😝", "😜", "🤪", "🤨", "🧐", "🤓", "😎", "🥸", "🤩", "🥳", 
            "😏", "😒", "😞", "😔", "😟", "😕", "🙁", "☹️", "😣", "😖", "😫", "😩", "🥺", "😢", "😭", "😤", 
            "😠", "😡", "🤬", "🤯", "😳", "🥵", "🥶", "😱", "😨", "😰", "😥", "😓", "🤔", "🫣", "🤭", "🫢", 
            "🤫", "🫠", "🤥", "😶", "😐", "😑", "😬", "🙄", "😯", "😦", "😧", "😮", "😲", "🥱", "😴", "🤤", 
            "😪", "😵", "😵‍💫", "🤐", "🥴", "🤢", "🤮", "🤧", "😷", "🤒", "🤕", "🤑", "🤠", "😈", "👿", "💀"
        ]),
        EmojiCategory(name: "Hearts & Hands", icon: "heart.fill", emojis: [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❤️‍🔥", "❤️‍🩹", "❣️", "💕", "💞", "💓", 
            "💗", "💖", "💘", "💝", "💟", "👍", "👎", "👌", "🤌", "✊", "👊", "🤛", "🤜", "🤞", "✌️", "🤟", 
            "🤘", "🫵", "👈", "👉", "👆", "👇", "🖐️", "✋", "🖖", "👋", "✍️", "👏", "🙌", "👐", "🤲", "🙏", "🤝"
        ]),
        EmojiCategory(name: "Fun & Activities", icon: "gamecontroller.fill", emojis: [
            "🎉", "🥳", "🎈", "🎁", "🎂", "🎄", "🎆", "🎇", "🧨", "✨", "🪄", "🎨", "🎬", "🎤", "🎧", "🎮", 
            "🎲", "🎸", "🎹", "🏆", "🥇", "🥈", "🥉", "⚽", "🏀", "🏈", "⚾", "🎾", "🏐", "🏓", "🏸", "🥊", 
            "🛹", "⛷️", "🚴", "🏊", "🎳", "🎭", "🎟️", "🎫", "🎪", "🎤", "🧩", "🎯"
        ]),
        EmojiCategory(name: "Animals & Nature", icon: "leaf.fill", emojis: [
            "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔", 
            "🐧", "🐦", "🦆", "🦅", "🦉", "🦇", "🐺", "🐗", "🐴", "🦄", "🐝", "🐛", "🦋", "🐌", "🐞", "🐜", 
            "🕷️", "🦂", "🐢", "🐍", "🦎", "🐙", "🦑", "🦀", "🐡", "🐠", "🐟", "🐬", "🐳", "🐋", "🦈", "🐊", 
            "🐅", "🐆", "🦓", "🦍", "🐘", "🐪", "🦒", "🦘", "🐾", "🌵", "🌲", "🌳", "🌴", 
            "🌱", "🌿", "🍀", "🍁", "🍂", "🍃", "🍄", "🐚", "🌹", "🥀", "🌺", "🌸", "🌼", "🌻", "☀️", "🌙", 
            "🪐", "💫", "⭐️", "🌟", "✨", "⚡️", "🔥", "🌈", "☁️", "🌧️", "⛈️", "❄️", "☃️", "🌊", "💧", "💦"
        ]),
        EmojiCategory(name: "Food & Drink", icon: "cup.and.saucer.fill", emojis: [
            "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍈", "🍒", "🍑", "🥭", "🍍", "🥥", 
            "🥝", "🍅", "🍆", "🥑", "🥦", "🥬", "🥒", "🌶️", "🌽", "🥕", "🫒", "🧄", "🧅", "🥔", "🍠", 
            "🥐", "🥯", "🍞", "🥖", "🥨", "🧀", "🥚", "🍳", "🥞", "🧇", "🥓", "🥩", "🍗", "🍖", "🌭", "🍔", 
            "🍟", "🍕", "🥪", "🥙", "🌮", "🌯", "🥗", "🥘", "🍲", "🥣", "🍿", "🧂", "🍱", "🍘", "🍙", "🍚", 
            "🍛", "🍜", "🍝", "🍣", "🍤", "🍦", "🍧", "🍨", "🍩", "🍪", "🎂", "🍰", "🍫", "🍬", "🍭", "🍯", 
            "🥛", "☕️", "🍵", "🍶", "🍾", "🍷", "🍸", "🍹", "🍺", "🍻", "🥂", "🥃", "🥤", "🧋", "🧊"
        ])
    ]
    
    struct EmojiCategory: Identifiable {
        var id: String { name }
        let name: String
        let icon: String
        let emojis: [String]
    }
    
    // Grid configuration
    private let columns = [
        GridItem(.adaptive(minimum: 36, maximum: 44), spacing: 8)
    ]
    
    private var tabs: [EmojiPickerTabs.Tab] {
        let unicode = categories.map {
            EmojiPickerTabs.Tab(name: $0.name, symbol: $0.icon, icon: nil, picks: $0.emojis.map { ReactionPick($0) })
        }
        return EmojiPickerTabs.build(categories: unicode, palette: palette.state, library: emojiList.library, reacting: reacting)
    }

    /// The tab shown: the one picked, or the first (Recents when there are any).
    private var currentTab: String {
        tabs.contains { $0.name == selectedCategory } ? selectedCategory : (tabs.first?.name ?? "Smileys")
    }

    // Filtered emojis based on search text
    private var filteredEmojis: [ReactionPick] {
        if searchText.isEmpty {
            return tabs.first { $0.name == currentTab }?.picks ?? []
        }
        let custom = reacting ? EmojiPickerTabs.searchCustom(tabs, query: searchText) : []
        // Simple client-side search over all categories
        return custom + categories.flatMap { $0.emojis }.filter { emoji in
            // Because standard emoji databases are hard to embed, we check if they are in the search-defined category
            // or we allow custom emoji typing. Users can search for category names, or if search is exactly an emoji, we show it.
            if emoji == searchText { return true }
            
            // Basic tag search (English words mapped to categories)
            return isEmojiMatch(emoji: emoji, query: searchText.lowercased())
        }.map { ReactionPick($0) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("React with Emoji")
                    .font(.appSystem(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.appSystem(size: 20))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            Divider()
                .background(Color.platformSeparator)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    
                    // Quick Reactions Section
                    if reacting {
                        QuickBarRow(
                            bar: EmojiPalette.orderedBar(palette.state),
                            editing: editingBar,
                            editSlot: editSlot,
                            onToggleEdit: { editingBar.toggle(); editSlot = nil },
                            onSlot: { slot in if editingBar { editSlot = slot } else { selectEmoji(slot) } }
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick Reactions")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.5)
                        
                        HStack(spacing: 12) {
                            ForEach(quickReactions, id: \.self) { emoji in
                                Button(action: {
                                    selectEmoji(ReactionPick(emoji))
                                }) {
                                    Text(emoji)
                                        .font(.appSystem(size: 26))
                                        .frame(width: 38, height: 38)
                                        .background(Color.platformTertiaryGroupedBackground)
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.platformSeparator, lineWidth: 0.8)
                                        )
                                }
                                .buttonStyle(.plain)
                                #if os(iOS)
                                .hoverEffect(.lift)
                                #endif
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    }
                    
                    // Custom Input Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("React with Custom Emoji")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.5)
                        
                        HStack(spacing: 8) {
                            TextField("Paste or type any emoji...", text: $customEmoji)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(Color.platformTertiaryGroupedBackground)
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.platformSeparator, lineWidth: 0.8)
                                )
                                .foregroundColor(.white)
                            
                            Button(action: {
                                let trimmed = customEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    selectEmoji(ReactionPick(trimmed))
                                }
                            }) {
                                Text("React")
                                    .font(.appSystem(size: 13, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(
                                        LinearGradient(
                                            colors: [Color.havenPurple, Color.havenPurple.opacity(0.8)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .cornerRadius(10)
                                    .shadow(color: Color.havenPurple.opacity(0.3), radius: 5, x: 0, y: 3)
                            }
                            .buttonStyle(.plain)
                            .disabled(customEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // Search Bar
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.appSystem(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            TextField("Search emojis...", text: $searchText)
                                .textFieldStyle(.plain)
                                .foregroundColor(.white)
                            
                            if !searchText.isEmpty {
                                Button(action: {
                                    searchText = ""
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(10)
                        .background(Color.platformTertiaryGroupedBackground)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.platformSeparator, lineWidth: 0.8)
                        )
                    }
                    .padding(.horizontal, 16)
                    
                    // Categories Selector (only visible when not searching)
                    if searchText.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(tabs, id: \.name) { category in
                                    let selected = currentTab == category.name
                                    Button(action: {
                                        withAnimation(Motion.pop) {
                                            selectedCategory = category.name
                                        }
                                    }) {
                                        HStack(spacing: 6) {
                                            if let symbol = category.symbol {
                                                Image(systemName: symbol)
                                                    .font(.appSystem(size: 11))
                                            } else if let icon = category.icon {
                                                ReactionGlyph(icon, fontSize: 11)
                                            }
                                            Text(category.name)
                                                .font(.appSystem(size: 12, weight: .semibold))
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .foregroundColor(selected ? .white : .secondary)
                                        .background(selected ? Color.havenPurple : Color.platformTertiaryGroupedBackground)
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(selected ? Color.havenPurple : Color.platformSeparator, lineWidth: 0.8)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    
                    // Emojis Grid
                    VStack(alignment: .leading, spacing: 8) {
                        Text(searchText.isEmpty ? currentTab : "Search Results (\(filteredEmojis.count))")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.5)
                            .padding(.horizontal, 16)
                        
                        if filteredEmojis.isEmpty {
                            VStack(spacing: 8) {
                                Text("😕")
                                    .font(.appSystem(size: 32))
                                Text("No matching emojis found")
                                    .font(.appSystem(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .padding()
                        } else {
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(Array(filteredEmojis.enumerated()), id: \.offset) { _, pick in
                                    Button(action: {
                                        selectEmoji(pick)
                                    }) {
                                        ReactionGlyph(pick, fontSize: 24)
                                            .frame(width: 40, height: 40)
                                            // A clear background is not a hit
                                            // area; the corners were dead on the Mac.
                                            .contentShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                    #if os(iOS)
                                    .hoverEffect(.highlight)
                                    #endif
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 20)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity)
        .frame(height: 520)
        .background(Color.platformSecondaryGroupedBackground)
        .cornerRadius(16)
        .onAppear { if reacting { EmojiListService.shared.refresh() } }
    }
    
    private func selectEmoji(_ pick: ReactionPick) {
        // Haptic feedback
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        #endif

        // Editing the quick bar: the pick goes in the chosen slot, the sheet stays.
        if editingBar, let slot = editSlot {
            palette.replaceSlot(slot, with: pick)
            editSlot = nil
            return
        }
        onSelect(pick)
        presentationMode.wrappedValue.dismiss()
    }
    
    // Helper to perform simple search mappings for common emojis
    private func isEmojiMatch(emoji: String, query: String) -> Bool {
        // Broad search tags map
        let searchTags: [String: [String]] = [
            "laugh": ["😂", "🤣", "😀", "😃", "😄", "😁", "😆", "😅"],
            "smile": ["😀", "😃", "😄", "😊", "🙂", "😉", "😍", "🥰", "😋"],
            "wink": ["😉", "😜", "🤪", "🙃"],
            "love": ["😍", "🥰", "😘", "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💖", "💘", "💝", "🌹"],
            "heart": ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❤️‍🔥", "❤️‍🩹", "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💟"],
            "sad": ["😢", "😭", "😞", "😔", "😟", "😕", "🙁", "☹️", "🥺"],
            "angry": ["😤", "😠", "😡", "🤬", "👿", "😈"],
            "fear": ["😱", "😨", "😰", "😥", "😓"],
            "thumbs": ["👍", "👎"],
            "like": ["👍", "❤️", "👌"],
            "yes": ["👍", "👌", "👏", "🙌", "🙏"],
            "no": ["👎", "❌"],
            "ok": ["👌", "👍"],
            "cool": ["😎", "🥸", "🔥", "🎸", "🛹"],
            "fire": ["🔥", "❤️‍🔥"],
            "party": ["🎉", "🥳", "🎈", "🎁", "🎂", "🍻", "🥂"],
            "congrat": ["🎉", "👏", "🙌", "🏆", "🥇", "🍻", "🥂"],
            "rocket": ["🚀", "🛸", "☄️", "🌟", "✨"],
            "star": ["⭐️", "🌟", "✨", "💫"],
            "lightning": ["⚡️"],
            "sun": ["☀️", "🌞", "🌈"],
            "moon": ["🌙", "🌝", "🌛", "🌜"],
            "water": ["💧", "💦", "🌊", "🌧️", "☔️"],
            "dog": ["🐶", "🐕", "🐾"],
            "cat": ["🐱", "🐈", "🐾"],
            "beer": ["🍺", "🍻", "🥂"],
            "coffee": ["☕️", "🍵"],
            "pizza": ["🍕"],
            "game": ["🎮", "🎲"],
            "music": ["🎸", "🎹", "🎤", "🎧"]
        ]
        
        for (tag, emojis) in searchTags {
            if tag.contains(query) && emojis.contains(emoji) {
                return true
            }
        }
        
        return false
    }
}
