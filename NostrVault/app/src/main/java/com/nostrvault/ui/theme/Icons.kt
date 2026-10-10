package com.nostrvault.ui.theme

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.automirrored.filled.ViewList
import androidx.compose.material.icons.filled.AccountBalanceWallet
import androidx.compose.material.icons.filled.Article
import androidx.compose.material.icons.filled.Poll
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material.icons.filled.ShoppingBag
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Whatshot
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AlternateEmail
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material.icons.filled.SouthWest
import androidx.compose.material.icons.filled.Backup
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.filled.CellTower
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Construction
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.CurrencyBitcoin
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ElectricBolt
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Feed
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.LocalFlorist
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Gif
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.BorderColor
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.ManageAccounts
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.OfflineBolt
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.MoveToInbox
import androidx.compose.material.icons.filled.Outbox
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.ArrowCircleUp
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.PersonOff
import androidx.compose.material.icons.filled.PersonSearch
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Tag
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.ViewAgenda
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.OfflineBolt
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Translate
import androidx.compose.material.icons.filled.Translate
import androidx.compose.material.icons.filled.RemoveModerator
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * SF Symbol -> Material Icon mapping.
 *
 * Centralises all icon references so screen code doesn't need to know
 * about the iOS -> Android mapping. Usage:
 *   Icon(NostrVaultIcons.Feed, contentDescription = "Feed")
 */
object NostrVaultIcons {
    // Brand / navigation
    val AppIcon: ImageVector = Icons.Filled.Dns           // server.rack
    val Accounts: ImageVector = Icons.Filled.Key           // person.badge.key
    val Key: ImageVector = Icons.Filled.Key                // key.fill
    val Blocked: ImageVector = Icons.Filled.PersonOff      // person.crop.circle.badge.xmark
    val Appearance: ImageVector = Icons.Filled.Palette     // paintpalette
    @Suppress("DEPRECATION")
    val Feed: ImageVector = Icons.Filled.Feed              // newspaper
    val DMs: ImageVector = Icons.Filled.Forum              // bubble.left.and.bubble.right
    val Notifications: ImageVector = Icons.Filled.NotificationsActive // bell.badge
    val Import: ImageVector = Icons.Filled.Download        // square.and.arrow.down
    val Backup: ImageVector = Icons.Filled.Backup          // externaldrive.fill
    val Following: ImageVector = Icons.Filled.ManageAccounts // person.crop.circle.badge.clock
    @Suppress("DEPRECATION")
    val Blastr: ImageVector = Icons.Filled.Send             // paperplane
    val Domain: ImageVector = Icons.Filled.Public           // globe
    val PoW: ImageVector = Icons.Filled.Construction        // hammer.fill
    val Settings: ImageVector = Icons.Filled.Settings       // gearshape.2
    val Wallet: ImageVector = Icons.Filled.CurrencyBitcoin  // bitcoinsign.circle
    val Logs: ImageVector = Icons.Filled.Terminal           // list.bullet.rectangle
    val Profile: ImageVector = Icons.Filled.Person          // person.circle
    val Groups: ImageVector = Icons.Filled.Groups           // person.3

    // Actions
    val Zap: ImageVector = Icons.Filled.ElectricBolt       // bolt.fill
    val Like: ImageVector = Icons.Filled.Favorite          // heart.fill
    val LikeOutline: ImageVector = Icons.Outlined.FavoriteBorder // heart
    val Heart: ImageVector = Icons.Outlined.FavoriteBorder // heart (alias)
    val HeartFilled: ImageVector = Icons.Filled.Favorite   // heart.fill (alias)
    val Repost: ImageVector = Icons.Filled.Repeat          // arrow.2.squarepath
    val Reply: ImageVector = Icons.AutoMirrored.Filled.Reply // arrowshape.turn.up.left
    val Copy: ImageVector = Icons.Filled.ContentCopy       // doc.on.doc
    val Navigate: ImageVector = Icons.Filled.ChevronRight  // chevron.right
    val Back: ImageVector = Icons.AutoMirrored.Filled.ArrowBack // chevron.left
    val Dismiss: ImageVector = Icons.Filled.Close          // xmark
    val Alert: ImageVector = Icons.Filled.Warning          // exclamationmark.triangle.fill
    /** No relay answered: the feeds that need a connection. */
    val NoConnection: ImageVector = Icons.Filled.WifiOff   // wifi.slash
    val Flag: ImageVector = Icons.Filled.Flag             // flag.fill
    val Create: ImageVector = Icons.Filled.Add             // plus
    /** Write a post: the Post button, the folded bar's compose action. */
    val Compose: ImageVector by lazy { squareAndPencil() } // square.and.pencil
    /** The WoT tab's own glyph, the iOS "WoTTab" asset (a globe with linked faces). */
    val TabWoT: ImageVector by lazy { wotTabGlyph() }        // WoTTab asset
    /** The note action bar's Reply (the "replying to" line keeps [Reply]). */
    val ReplyAction: ImageVector = Icons.Outlined.ChatBubbleOutline // message
    /** The note action bar's Zap before you've zapped; [Zap] after. */
    val ZapOutline: ImageVector = Icons.Outlined.Bolt      // bolt
    val ArrowUp: ImageVector = Icons.Filled.ArrowUpward    // arrow.up
    val Incoming: ImageVector = Icons.Filled.SouthWest     // arrow.down.left
    val Outgoing: ImageVector = Icons.Filled.NorthEast     // arrow.up.right
    val Search: ImageVector = Icons.Filled.Search          // magnifyingglass
    val Sort: ImageVector = Icons.Filled.SwapVert          // arrow.up.arrow.down
    val History: ImageVector = Icons.Filled.History         // clock.arrow.circlepath
    val Media: ImageVector = Icons.Filled.Image            // photo
    val Popular: ImageVector = Icons.Filled.Whatshot       // flame
    val Discover: ImageVector = Icons.Filled.AutoAwesome   // sparkles
    val Articles: ImageVector = Icons.Filled.Article       // doc.text
    val Recipes: ImageVector = Icons.Filled.Restaurant     // fork.knife
    val Polls: ImageVector = Icons.Filled.Poll             // chart.bar.xaxis
    val Marketplace: ImageVector = Icons.Filled.ShoppingBag // bag
    val Live: ImageVector = Icons.Filled.Videocam          // video.fill
    val Reels: ImageVector = Icons.Filled.VideoLibrary     // play.rectangle.on.rectangle
    val More: ImageVector = Icons.Filled.MoreVert          // ellipsis
    val Edit: ImageVector = Icons.Filled.Edit              // pencil
    val Delete: ImageVector = Icons.Filled.Delete          // trash
    val Share: ImageVector = Icons.Filled.Share             // square.and.arrow.up
    val Quote: ImageVector = Icons.Filled.FormatQuote         // quote.closing (quotation marks)
    val Refresh: ImageVector = Icons.Filled.Refresh        // arrow.clockwise
    val Check: ImageVector = Icons.Filled.Check            // checkmark
    val CheckCircle: ImageVector = Icons.Filled.CheckCircle // checkmark.circle.fill
    val ErrorCircle: ImageVector = Icons.Filled.Error      // exclamationmark.circle.fill
    val CircleOutline: ImageVector = Icons.Outlined.Circle  // circle
    val DragHandle: ImageVector = Icons.Filled.DragHandle  // line.3.horizontal
    val EditFeeds: ImageVector = Icons.Filled.Tune         // slider.horizontal.3
    val Info: ImageVector = Icons.Filled.Info              // info.circle
    val Tutorials: ImageVector = Icons.Filled.School       // graduationcap
    @Suppress("DEPRECATION")
    val Send: ImageVector = Icons.Filled.Send              // paperplane.fill
    val PersonAdd: ImageVector = Icons.Filled.PersonAdd    // person.badge.plus
    val Verified: ImageVector = Icons.Filled.Verified      // checkmark.seal
    val AccountCircle: ImageVector = Icons.Filled.AccountCircle // person.crop.circle
    val Chat: ImageVector = Icons.AutoMirrored.Filled.Chat // bubble.left
    val Storage: ImageVector = Icons.Filled.Storage        // externaldrive
    val Lock: ImageVector = Icons.Filled.Lock              // lock.fill
    val LockOpen: ImageVector = Icons.Filled.LockOpen      // lock.open

    // View modes
    val CompactView: ImageVector = Icons.AutoMirrored.Filled.ViewList // rectangle.compress.vertical
    val ExpandedView: ImageVector = Icons.Filled.ViewAgenda           // rectangle.expand.vertical
    val ThreadedView: ImageVector = Icons.AutoMirrored.Filled.FormatListBulleted // list.bullet.indent

    // Navigation (additional)
    val Relay: ImageVector = Icons.Filled.CellTower          // antenna.radiowaves.left.and.right
    val WebOfTrust: ImageVector = Icons.Filled.Hub           // point.3.connected.trianglepath.dotted
    val Sparkles: ImageVector = Icons.Filled.AutoAwesome     // sparkles
    val PeopleList: ImageVector = Icons.AutoMirrored.Filled.FormatListBulleted // list.bullet

    // Tab bar (iOS BottomTabBar)
    val TabFeed: ImageVector = Icons.Filled.People           // person.2.wave.2
    val TabMedia: ImageVector = Icons.Filled.PhotoLibrary    // photo.on.rectangle
    /** The Vault tab and its Vault Dashboard (Media and Relay in one). */
    val TabVault: ImageVector = Icons.Filled.Inventory2      // lock.rectangle.stack
    /** The Vault tab's Highlights list (NIP-84). */
    val Highlights: ImageVector = Icons.Filled.BorderColor   // highlighter
    val ChevronDown: ImageVector = Icons.Filled.KeyboardArrowDown // chevron.down
    val MarkAllRead: ImageVector = Icons.Filled.DoneAll      // checkmark.circle
    val Browse: ImageVector = Icons.Filled.Explore           // magnifyingglass.circle
    val GridLayout: ImageVector = Icons.Filled.GridView      // square.grid.2x2
    val ListLayout: ImageVector = Icons.AutoMirrored.Filled.ViewList  // list.bullet
    val FilterMenu: ImageVector = Icons.Filled.FilterList    // line.3.horizontal.decrease

    // Feed filter toggles
    val AutoLoad: ImageVector = Icons.Filled.OfflineBolt         // bolt.circle.fill
    val AutoLoadOff: ImageVector = Icons.Outlined.OfflineBolt    // bolt.circle
    val People: ImageVector = Icons.Filled.People                // person.2.fill
    val PeopleOutline: ImageVector = Icons.Outlined.People       // person.2
    val Globe: ImageVector = Icons.Filled.Public                 // globe (alias for filter context)
    val GlobeOutline: ImageVector = Icons.Outlined.Public        // globe.americas
    val BarChart: ImageVector = Icons.Filled.BarChart            // chart.bar.fill
    val TrustShield: ImageVector = Icons.Filled.VerifiedUser     // checkmark.shield.fill (Web of Trust)
    val TrustOff: ImageVector = Icons.Filled.RemoveModerator     // shield.slash.fill (Everyone)
    val Languages: ImageVector = Icons.Filled.Translate          // character.bubble.fill
    val LanguagesOutline: ImageVector = Icons.Outlined.Translate // character.bubble

    // Search / vault filters
    val Layers: ImageVector = Icons.Filled.Layers                // square.stack
    val Document: ImageVector = Icons.Filled.Description         // doc.text
    val TagIcon: ImageVector = Icons.Filled.Tag                  // number/hashtag
    val LinkIcon: ImageVector = Icons.Filled.Link                // link
    val At: ImageVector = Icons.Filled.AlternateEmail            // at (tagged filter)
    val OutsideNetwork: ImageVector = Icons.Filled.PersonSearch  // person.crop.circle.badge.questionmark
    val Received: ImageVector = Icons.Filled.MoveToInbox         // tray.and.arrow.down.fill
    val Given: ImageVector = Icons.Filled.Outbox                 // tray.and.arrow.up.fill

    // Wallet

    // Blossom
    val Blossom: ImageVector = Icons.Filled.LocalFlorist          // camera.macro (flower)
    val Cloud: ImageVector = Icons.Filled.Cloud                   // cloud.fill
    val CloudDone: ImageVector = Icons.Filled.CloudDone           // checkmark.icloud.fill
    val Video: ImageVector = Icons.Filled.Videocam               // video.fill
    val Gif: ImageVector = Icons.Filled.Gif                       // GIF badge

    // Media actions
    val UploadIcon: ImageVector = Icons.Filled.Upload            // arrow.up.doc
    val PlayCircle: ImageVector = Icons.Filled.PlayCircle        // play.circle.fill
    val PlayArrow: ImageVector = Icons.Filled.PlayArrow          // play.fill
    val Music: ImageVector = Icons.Filled.MusicNote               // music.note
    val Waveform: ImageVector = Icons.Filled.GraphicEq            // waveform
    val ArrowUpCircle: ImageVector = Icons.Outlined.ArrowCircleUp      // arrow.up.circle
    val ArrowUpCircleFill: ImageVector = Icons.Filled.ArrowCircleUp    // arrow.up.circle.fill
    val ArrowDownCircle: ImageVector = Icons.Outlined.ArrowCircleDown  // arrow.down.circle
    val ArrowDownCircleFill: ImageVector = Icons.Filled.ArrowCircleDown // arrow.down.circle.fill
    val PauseIcon: ImageVector = Icons.Filled.Pause              // pause.fill
    val Stop: ImageVector = Icons.Filled.Stop                    // stop.fill
    val VolumeUp: ImageVector = Icons.AutoMirrored.Filled.VolumeUp   // speaker.wave.2.fill
    val VolumeOff: ImageVector = Icons.AutoMirrored.Filled.VolumeOff // speaker.slash.fill
    val PictureInPicture: ImageVector = Icons.Filled.PictureInPictureAlt // pip.enter
}

/**
 * SF Symbols' square.and.pencil, which Material lacks: a rounded square
 * open at its top-right corner, with a pencil running into it.
 */
private fun squareAndPencil(): ImageVector = ImageVector.Builder(
    name = "SquareAndPencil",
    defaultWidth = 24.dp,
    defaultHeight = 24.dp,
    viewportWidth = 24f,
    viewportHeight = 24f,
).apply {
    // The square, broken where the pencil enters.
    path(
        stroke = SolidColor(androidx.compose.ui.graphics.Color.Black),
        strokeLineWidth = 1.8f,
        strokeLineCap = StrokeCap.Round,
        strokeLineJoin = StrokeJoin.Round,
    ) {
        moveTo(12f, 4f)
        horizontalLineTo(6.5f)
        arcToRelative(2.5f, 2.5f, 0f, false, false, -2.5f, 2.5f)
        verticalLineTo(17.5f)
        arcToRelative(2.5f, 2.5f, 0f, false, false, 2.5f, 2.5f)
        horizontalLineTo(17.5f)
        arcToRelative(2.5f, 2.5f, 0f, false, false, 2.5f, -2.5f)
        verticalLineTo(12f)
    }
    // The pencil: body and point.
    path(fill = SolidColor(androidx.compose.ui.graphics.Color.Black)) {
        moveTo(18.6f, 2.6f)
        lineTo(21.4f, 5.4f)
        lineTo(12.6f, 14.2f)
        lineTo(9.2f, 14.8f)
        lineTo(9.8f, 11.4f)
        close()
    }
}.build()

/**
 * The WoT tab glyph, copied path-for-path from the iOS asset
 * HavenApp/Resources/Assets.xcassets/WoTTab.imageset/wot_tab.svg, so both
 * tab bars draw the same icon. Non-zero fill, as in the SVG.
 */
private fun wotTabGlyph(): ImageVector = ImageVector.Builder(
    name = "WoTTab",
    defaultWidth = 24.dp,
    defaultHeight = 24.dp,
    viewportWidth = 24f,
    viewportHeight = 24f,
).addPath(
    pathData = addPathNodes(WOT_TAB_PATH),
    fill = SolidColor(androidx.compose.ui.graphics.Color.Black),
).build()

private const val WOT_TAB_PATH =
    "M22.000 12.000C22.000 17.523 17.523 22.000 12.000 22.000C6.477 22.000 2.000 17.523 2.000 12.000" +
    "C2.000 6.477 6.477 2.000 12.000 2.000C17.523 2.000 22.000 6.477 22.000 12.000ZM8.824 8.811" +
    "C8.508 8.327 8.051 7.944 7.510 7.721C7.828 6.285 8.313 5.039 8.925 4.082" +
    "C6.883 4.870 5.223 6.427 4.304 8.400C3.805 8.919 3.500 9.624 3.500 10.400" +
    "C3.500 10.607 3.522 10.810 3.564 11.005C3.520 11.330 3.500 11.663 3.500 12.000" +
    "C3.500 15.609 5.749 18.692 8.925 19.918C7.906 18.324 7.239 15.931 7.096 13.212" +
    "C7.481 13.121 7.835 12.950 8.139 12.717L8.569 12.840C8.754 17.178 10.361 20.500 12.000 20.500" +
    "C12.132 20.500 12.264 20.478 12.395 20.436C12.810 20.668 13.290 20.800 13.800 20.800" +
    "C14.894 20.800 15.847 20.194 16.340 19.299C18.833 17.825 20.500 15.107 20.500 12.000" +
    "C20.500 10.688 20.203 9.446 19.666 8.342C19.817 7.991 19.900 7.605 19.900 7.200" +
    "C19.900 5.598 18.602 4.300 17.000 4.300C16.637 4.300 16.290 4.367 15.971 4.491" +
    "C15.682 4.338 15.383 4.201 15.075 4.082C15.208 4.291 15.335 4.513 15.456 4.749" +
    "C14.986 5.042 14.608 5.467 14.375 5.974C13.733 4.438 12.871 3.500 12.000 3.500" +
    "C10.673 3.500 9.368 5.676 8.824 8.811ZM18.800 7.200C18.800 8.194 17.994 9.000 17.000 9.000" +
    "C16.728 9.000 16.471 8.940 16.240 8.830L14.041 10.942C14.207 11.258 14.300 11.618 14.300 12.000" +
    "C14.300 12.803 13.889 13.509 13.265 13.920L13.932 16.107" +
    "C14.865 16.173 15.600 16.951 15.600 17.900C15.600 18.894 14.794 19.700 13.800 19.700" +
    "C12.806 19.700 12.000 18.894 12.000 17.900C12.000 17.326 12.269 16.814 12.689 16.486" +
    "L12.022 14.299C12.015 14.300 12.007 14.300 12.000 14.300C10.736 14.300 9.710 13.281 9.701 12.019" +
    "L7.833 11.486C7.506 11.920 6.986 12.200 6.400 12.200C5.406 12.200 4.600 11.394 4.600 10.400" +
    "C4.600 9.406 5.406 8.600 6.400 8.600C7.339 8.600 8.110 9.319 8.192 10.236L10.059 10.769" +
    "C10.465 10.126 11.183 9.700 12.000 9.700C12.415 9.700 12.805 9.810 13.140 10.004L15.339 7.894" +
    "C15.249 7.680 15.200 7.446 15.200 7.200C15.200 6.206 16.006 5.400 17.000 5.400" +
    "C17.994 5.400 18.800 6.206 18.800 7.200ZM16.861 10.093C16.921 10.709 16.950 11.348 16.950 12.000" +
    "C16.950 13.670 16.759 15.251 16.407 16.636C16.140 16.079 15.698 15.622 15.152 15.335" +
    "C15.343 14.317 15.450 13.189 15.450 12.000C15.450 11.707 15.443 11.417 15.431 11.132" +
    "L16.547 10.061C16.649 10.081 16.754 10.092 16.861 10.093Z"
