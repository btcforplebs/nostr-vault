package com.nostrvault.service

/** How many of the user's Blossom servers hold one file. Port of iOS `BlossomBackupSummary`. */
data class BlossomBackupSummary(
    val present: Int,
    val unreachable: Int,
    val total: Int,
    /** Servers not known to have the file: those that said no plus those that could not be asked. */
    val missing: List<String>,
) {
    val isComplete: Boolean get() = total > 0 && present == total
    /** Worth offering an upload: some server lacks it, or could not be asked. */
    val needsMirror: Boolean get() = total > 0 && present < total

    companion object {
        /** Null while any configured server has no answer yet, rather than guessing. */
        fun of(byMirror: Map<String, BlobPresence>?, mirrors: List<String>): BlossomBackupSummary? {
            if (mirrors.isEmpty()) return BlossomBackupSummary(0, 0, 0, emptyList())
            if (byMirror == null || !mirrors.all { it in byMirror }) return null
            var present = 0
            var unreachable = 0
            val missing = mutableListOf<String>()
            for (mirror in mirrors) {
                when (byMirror[mirror]) {
                    BlobPresence.PRESENT -> present++
                    BlobPresence.UNREACHABLE -> { unreachable++; missing += mirror }
                    else -> missing += mirror
                }
            }
            return BlossomBackupSummary(present, unreachable, mirrors.size, missing)
        }
    }
}
