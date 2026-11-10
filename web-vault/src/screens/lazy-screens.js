// Every screen but the Feed, split out of the boot bundle (lazy.jsx). FeedScreen stays in it: it is the screen nearly
// every visit opens on, and so does the Guest app: the sign-in screen is what a visitor who isn't signed in lands on.
// SettingsScreen stays too: resetBrowser (sign-out's question) is a plain call on the click, not a screen, and
// main.jsx and the Sidebar need it loaded.
import { h } from "preact"
import { lazyScreen } from "./lazy.jsx"
import { Splash } from "../components/Loading.jsx"

export const ComposeScreen = lazyScreen("ComposeScreen", () => import("./ComposeScreen.jsx"))
export const ProfileScreen = lazyScreen("ProfileScreen", () => import("./ProfileScreen.jsx"))
export const PersonScreen = lazyScreen("PersonScreen", () => import("./PersonScreen.jsx"))
export const RelayScreen = lazyScreen("RelayScreen", () => import("./RelayScreen.jsx"))
export const SearchScreen = lazyScreen("SearchScreen", () => import("./SearchScreen.jsx"))
export const NotificationsScreen = lazyScreen("NotificationsScreen", () => import("./NotificationsScreen.jsx"))
export const ThreadScreen = lazyScreen("ThreadScreen", () => import("./ThreadScreen.jsx"))
export const MessagesScreen = lazyScreen("MessagesScreen", () => import("./MessagesScreen.jsx"))
export const ConversationScreen = lazyScreen("ConversationScreen", () => import("./ConversationScreen.jsx"))
export const VaultScreen = lazyScreen("VaultScreen", () => import("./VaultScreen.jsx"))
export const AccountsScreen = lazyScreen("AccountsScreen", () => import("./AccountsScreen.jsx"))
export const WalletScreen = lazyScreen("WalletScreen", () => import("./WalletScreen.jsx"))
export const WotScreen = lazyScreen("WotScreen", () => import("./WotScreen.jsx"))
export const BookmarksScreen = lazyScreen("BookmarksScreen", () => import("./BookmarksScreen.jsx"))
// A sheet over the screen, not a screen: nothing in its place while it loads, as before.
export const VaultDashboard = lazyScreen("VaultDashboard", () => import("./VaultDashboard.jsx"), { fallback: () => null, failed: () => null })
// The desktop layout too: it drags the desktop space's own screens (LiveVault, MessagesPeek) with it, which a phone
// never shows. Its chunk lands while the boot splash (main.jsx, until Haven starts) still covers the page, and on a
// slow link after it: the splash again then, not an empty page.
export const DesktopShell = lazyScreen("DesktopShell", () => import("../desktop/DesktopShell.jsx"), { fallback: () => h(Splash, null, "Opening Nostr Vault…") })
