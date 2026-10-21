// Feeds that draw their own list under the Feed picker (iPhone FeedMode entries like Articles or Live).
// Each is { id, label, Screen }: id is the FeedMode name lowercased (net/feeds.js FEED_ORDER), Screen takes { ctx }.
import { ArticlesScreen } from "./ArticlesScreen.jsx"
import { RecipesScreen } from "./RecipesScreen.jsx"
import { LiveScreen } from "./LiveScreen.jsx"
import { MusicScreen } from "./MusicScreen.jsx"
import { MarketplaceScreen } from "./MarketplaceScreen.jsx"

export const READERS = [
  { id: "articles", label: "Articles", Screen: ArticlesScreen },
  { id: "recipes", label: "Recipes", Screen: RecipesScreen },
  { id: "marketplace", label: "Marketplace", Screen: MarketplaceScreen },
  { id: "live", label: "Live", Screen: LiveScreen },
  { id: "music", label: "Music", Screen: MusicScreen },
]
