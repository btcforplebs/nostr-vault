package com.nostrvault.util

/**
 * [Regex.findAll] without its native-memory cost on Android. Use this for
 * every scan of note content, HTML or any other text from the network.
 *
 * Kotlin's findAll makes a new java.util.regex.Matcher for every match, and
 * on Android each Matcher copies the whole input into ICU native memory that
 * is freed only when that Matcher is collected. ART does not count the copy,
 * so nothing prompts a GC: one long note full of links costs note size times
 * link count. On Logen's Moto (4 GB) that took the app from 400 MB to 2.4 GB
 * in about ten seconds of feed loading, and Android killed it in the
 * foreground (2026-10-21). This walks a single Matcher, so the input is
 * copied once per scan. Matches are the same as findAll's.
 */
fun Regex.findAllOnce(input: CharSequence): Sequence<MatchResult> = sequence {
    val matcher = toPattern().matcher(input)
    while (matcher.find()) yield(MatchSnapshot(matcher.toMatchResult(), this@findAllOnce, input))
}

private class MatchSnapshot(
    private val result: java.util.regex.MatchResult,
    private val regex: Regex,
    private val input: CharSequence,
) : MatchResult {
    override val range: IntRange get() = result.start() until result.end()
    override val value: String get() = result.group()

    override val groupValues: List<String> = object : AbstractList<String>() {
        override val size: Int get() = result.groupCount() + 1
        override fun get(index: Int): String = result.group(index) ?: ""
    }

    override val groups: MatchGroupCollection = object : MatchGroupCollection, AbstractCollection<MatchGroup?>() {
        override val size: Int get() = result.groupCount() + 1
        override fun iterator(): Iterator<MatchGroup?> = (0 until size).asSequence().map { get(it) }.iterator()
        override fun get(index: Int): MatchGroup? =
            result.group(index)?.let { MatchGroup(it, result.start(index) until result.end(index)) }
    }

    /** As findAll's: the next match after this one (a fresh scan, so avoid it in loops). */
    override fun next(): MatchResult? {
        val from = result.end() + if (result.end() == result.start()) 1 else 0
        return if (from <= input.length) regex.find(input, from) else null
    }
}
