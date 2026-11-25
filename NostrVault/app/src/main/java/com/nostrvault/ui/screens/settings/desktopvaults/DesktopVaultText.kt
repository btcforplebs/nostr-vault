package com.nostrvault.ui.screens.settings.desktopvaults

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DesktopMac
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.ui.graphics.vector.ImageVector
import com.nostrvault.relay.DesktopVault
import com.nostrvault.relay.DesktopVaultKind

/** Words the Desktop Vaults screens share (iOS `DesktopVaultText.swift`, P4 #2511). */
internal object DesktopVaultText {
    /** "What is this? (NIP-F1)" beside the "Media over the Mesh" switch. */
    const val NIP_F1_URL = "https://nostrvault.app/docs/developers/#nips"

    fun icon(kind: DesktopVaultKind): ImageVector = when (kind) {
        DesktopVaultKind.MAC -> Icons.Filled.DesktopMac
        DesktopVaultKind.LINUX -> Icons.Filled.Dns
        DesktopVaultKind.BOX -> Icons.Filled.Inventory2
    }

    fun kindLabel(kind: DesktopVaultKind): String = when (kind) {
        DesktopVaultKind.MAC -> "Mac"
        DesktopVaultKind.LINUX -> "Linux"
        DesktopVaultKind.BOX -> "Box"
    }

    /** "Mesh and web · vault.example.com", "Mesh only", "Web only · host". */
    fun paths(vault: DesktopVault): String {
        val host = vault.hostKey
        return when {
            vault.meshNpub != null && host != null -> "Mesh and web · $host"
            host != null -> "Web only · $host"
            else -> "Mesh only"
        }
    }

    /** §2.2 rule 1: what an HTTPS-only Vault holds. */
    const val WEB_ONLY_NOTE = "Holds your public posts, photos and messages. Drafts and private files need Mesh."
    const val BOTH_NOTE = "The Mesh comes first, the web address is the fallback. Drafts and private files go over the Mesh only."
    const val MESH_ONLY_NOTE = "Everything goes over the Mesh, including drafts and private files."
    const val EMPTY = "No desktop Vaults yet. A desktop Vault is a Mac or a Linux box that keeps a copy of your vault, always on."
    const val ORDER_NOTE = "Use the arrows to set the order. The first Vault comes first in your public lists, and other apps upload your media to the first media server."
    const val ADD_NOTE = "Pair it over the Mesh, type its web address, or both. Drafts and private files go over the Mesh only."
    const val LISTED_NOTE = "These lists are public. Turning a switch on puts this Vault after your other Vaults and before your own entries."
    const val MESH_MEDIA_DETAIL = "Lists its mesh address on your media servers, after the web ones. Apps that speak the mesh can load your media from it, and Auto-Mirror copies there over the mesh."
}
