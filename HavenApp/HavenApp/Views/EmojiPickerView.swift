import SwiftUI

struct EmojiPickerView: View {
    @Environment(\.presentationMode) var presentationMode
    let onSelectEmoji: (String) -> Void
    
    @State private var searchText = ""
    @State private var customEmoji = ""
    @State private var selectedCategory = "Smileys"
    
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
    
    // Filtered emojis based on search text
    private var filteredEmojis: [String] {
        if searchText.isEmpty {
            return categories.first { $0.name == selectedCategory }?.emojis ?? []
        }
        
        // Simple client-side search over all categories
        return categories.flatMap { $0.emojis }.filter { emoji in
            // Because standard emoji databases are hard to embed, we check if they are in the search-defined category
            // or we allow custom emoji typing. Users can search for category names, or if search is exactly an emoji, we show it.
            if emoji == searchText { return true }
            
            // Basic tag search (English words mapped to categories)
            return isEmojiMatch(emoji: emoji, query: searchText.lowercased())
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("React with Emoji")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick Reactions")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.5)
                        
                        HStack(spacing: 12) {
                            ForEach(quickReactions, id: \.self) { emoji in
                                Button(action: {
                                    selectEmoji(emoji)
                                }) {
                                    Text(emoji)
                                        .font(.system(size: 26))
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
                    
                    // Custom Input Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("React with Custom Emoji")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
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
                                    selectEmoji(trimmed)
                                }
                            }) {
                                Text("React")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
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
                                .font(.system(size: 13, weight: .semibold))
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
                                ForEach(categories) { category in
                                    Button(action: {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            selectedCategory = category.name
                                        }
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: category.icon)
                                                .font(.system(size: 11))
                                            Text(category.name)
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .foregroundColor(selectedCategory == category.name ? .white : .secondary)
                                        .background(selectedCategory == category.name ? Color.havenPurple : Color.platformTertiaryGroupedBackground)
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(selectedCategory == category.name ? Color.havenPurple : Color.platformSeparator, lineWidth: 0.8)
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
                        Text(searchText.isEmpty ? selectedCategory : "Search Results (\(filteredEmojis.count))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.5)
                            .padding(.horizontal, 16)
                        
                        if filteredEmojis.isEmpty {
                            VStack(spacing: 8) {
                                Text("😕")
                                    .font(.system(size: 32))
                                Text("No matching emojis found")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .padding()
                        } else {
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(filteredEmojis, id: \.self) { emoji in
                                    Button(action: {
                                        selectEmoji(emoji)
                                    }) {
                                        Text(emoji)
                                            .font(.system(size: 24))
                                            .frame(width: 40, height: 40)
                                            .background(Color.clear)
                                            .cornerRadius(8)
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
    }
    
    private func selectEmoji(_ emoji: String) {
        // Haptic feedback
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        #endif
        
        onSelectEmoji(emoji)
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
