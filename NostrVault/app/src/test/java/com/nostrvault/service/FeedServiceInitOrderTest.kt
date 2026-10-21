package com.nostrvault.service

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * FeedService starts its collectors from `init`, and one of them can run to
 * the end inside the constructor: `withContext(Dispatchers.IO)` returns
 * without suspending when its block finishes first (a new install has no
 * interaction-state file). Any field declared below that `init` is still null
 * then, and the app crashed at launch reading `_myReactions`. The race can't
 * be forced from a test, so this pins the order instead.
 */
class FeedServiceInitOrderTest {
    @Test
    fun `the observers start after every field of FeedService exists`() {
        val lines = File("src/main/java/com/nostrvault/service/FeedService.kt").readLines()
        val init = lines.indexOfFirst { it.trim() == "init { startObservers() }" }
        assertTrue("init { startObservers() } not found", init >= 0)
        // Class-level properties are indented one level (4 spaces).
        val property = Regex("""^    (?:@\w+(?:\([^)]*\))? )*(?:(?:private|internal|protected|public|override|lateinit|const) )*(?:val|var) \w+""")
        val after = lines.withIndex().drop(init + 1).filter { property.containsMatchIn(it.value) }
        assertTrue(
            "fields declared after init { startObservers() } (line ${init + 1}): " +
                after.take(5).joinToString { "${it.index + 1}: ${it.value.trim().take(60)}" },
            after.isEmpty(),
        )
    }
}
