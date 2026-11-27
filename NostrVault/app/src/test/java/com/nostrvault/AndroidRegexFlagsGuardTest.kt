package com.nostrvault

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Android's regex engine is ICU, not the JVM's: it throws on the `(?U)` flag
 * and on `UNICODE_CHARACTER_CLASS`, while JVM unit tests accept both. A
 * `(?U)` in VaultSearchLogic crashed the app on the first Vault search.
 * ICU's `\w` and `\s` are already Unicode; spell classes out with `\p{…}`.
 */
class AndroidRegexFlagsGuardTest {
    @Test
    fun noJvmOnlyRegexFlagsInAppSources() {
        val root = File("src/main/java")
        assertTrue("source root not found from ${File(".").absolutePath}", root.isDirectory)
        val hits = root.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { f ->
                f.readLines().withIndex()
                    .filter { (_, line) -> "\"(?U)" in line || "UNICODE_CHARACTER_CLASS" in line }
                    .map { (i, _) -> "${f.path}:${i + 1}" }
            }
            .toList()
        assertTrue("JVM-only regex flags, which Android rejects at run time:\n" + hits.joinToString("\n"), hits.isEmpty())
    }
}
