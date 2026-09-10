package com.nostrvault.ui.theme

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.automirrored.filled.ViewList
import androidx.compose.material.icons.filled.AccountBalanceWallet
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AlternateEmail
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Backup
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.CellTower
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Construction
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.CurrencyBitcoin
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ElectricBolt
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Feed
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.LocalFlorist
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.ManageAccounts
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.OfflineBolt
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.PersonOff
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Tag
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.ViewAgenda
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.OfflineBolt
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Public
import androidx.compose.ui.graphics.vector.ImageVector

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
    val Create: ImageVector = Icons.Filled.Add             // plus
    val ArrowUp: ImageVector = Icons.Filled.ArrowUpward    // arrow.up
    val Search: ImageVector = Icons.Filled.Search          // magnifyingglass
    val History: ImageVector = Icons.Filled.History         // clock.arrow.circlepath
    val Media: ImageVector = Icons.Filled.Image            // photo
    val More: ImageVector = Icons.Filled.MoreVert          // ellipsis
    val Edit: ImageVector = Icons.Filled.Edit              // pencil
    val Delete: ImageVector = Icons.Filled.Delete          // trash
    val Share: ImageVector = Icons.Filled.Share             // square.and.arrow.up
    val Quote: ImageVector = Icons.Filled.Edit                // quote (pen icon)
    val Refresh: ImageVector = Icons.Filled.Refresh        // arrow.clockwise
    val Check: ImageVector = Icons.Filled.Check            // checkmark
    val Info: ImageVector = Icons.Filled.Info              // info.circle
    @Suppress("DEPRECATION")
    val Send: ImageVector = Icons.Filled.Send              // paperplane.fill
    val PersonAdd: ImageVector = Icons.Filled.PersonAdd    // person.badge.plus
    val Verified: ImageVector = Icons.Filled.Verified      // checkmark.seal
    val AccountCircle: ImageVector = Icons.Filled.AccountCircle // person.crop.circle
    val Chat: ImageVector = Icons.AutoMirrored.Filled.Chat // bubble.left
    val Storage: ImageVector = Icons.Filled.Storage        // externaldrive

    // View modes
    val CompactView: ImageVector = Icons.AutoMirrored.Filled.ViewList // rectangle.compress.vertical
    val ExpandedView: ImageVector = Icons.Filled.ViewAgenda           // rectangle.expand.vertical

    // Navigation (additional)
    val Relay: ImageVector = Icons.Filled.CellTower          // antenna.radiowaves.left.and.right
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

    // Search / vault filters
    val Layers: ImageVector = Icons.Filled.Layers                // square.stack
    val Document: ImageVector = Icons.Filled.Description         // doc.text
    val TagIcon: ImageVector = Icons.Filled.Tag                  // number/hashtag
    val LinkIcon: ImageVector = Icons.Filled.Link                // link
    val At: ImageVector = Icons.Filled.AlternateEmail            // at (tagged filter)

    // Wallet
    val EcashWallet: ImageVector = Icons.Filled.AccountBalanceWallet // banknote.fill

    // Blossom
    val Blossom: ImageVector = Icons.Filled.LocalFlorist          // camera.macro (flower)
    val Cloud: ImageVector = Icons.Filled.Cloud                   // cloud.fill
    val Video: ImageVector = Icons.Filled.Videocam               // video.fill

    // Media actions
    val UploadIcon: ImageVector = Icons.Filled.Upload            // arrow.up.doc
    val PlayCircle: ImageVector = Icons.Filled.PlayCircle        // play.circle.fill
    val PlayArrow: ImageVector = Icons.Filled.PlayArrow          // play.fill
    val PauseIcon: ImageVector = Icons.Filled.Pause              // pause.fill
    val VolumeUp: ImageVector = Icons.AutoMirrored.Filled.VolumeUp   // speaker.wave.2.fill
    val VolumeOff: ImageVector = Icons.AutoMirrored.Filled.VolumeOff // speaker.slash.fill
}
