package com.nostrvault.data.model

import java.io.Reader

/**
 * The web of the account you're on, not of every account on this device.
 *
 * The relay builds one web for all of this device's accounts together: their
 * follow lists merged, and anyone 3+ of the merged follows follow (Min
 * Followers). So someone only your other accounts' follows vouch for reached
 * this account's Vault, Global and notifications, and unfollowing on one
 * account never dropped them (Logen 2026-11-13, "hop 3 spam").
 *
 * This narrows the saved web to: you, this device's accounts, the open
 * account's follows, and anyone at least Min Followers of the open account's
 * follows follow. The counts come from the relay's `wot_links.json` (for each
 * person in the web, which of the merged follows follow them), so no relay
 * change and no network. Twin of the iPhone/Mac per-account web.
 */
object AccountWeb {
    const val LINKS_FILE = "wot_links.json"

    /**
     * The saved web narrowed to the open account, by the iPhone/Mac rules
     * (`AccountWeb.web`, PR 2011).
     *
     * [depth] is the Follow Distance the relay built the graph at
     * (`wot_cache.json` "depth"). At 2 the web is you, this device's accounts
     * ([keep]) and the open account's follows. At 3 it adds anyone at least
     * Min Followers of those follows follow, counted from [links]. Anything
     * else keeps [saved] as it is: no links file (an older relay) or one that
     * can't be read, an account following fewer people than the bar (the
     * relay widens a new account's web on purpose, newAccountWeb), any other
     * depth, or empty [follows] (the list hasn't loaded yet, e.g. a switch,
     * rather than emptying Global for a second).
     */
    fun narrow(
        saved: Set<String>,
        links: Reader?,
        depth: Int?,
        follows: Set<String>,
        keep: Set<String>,
        minFollowers: Int,
    ): Set<String> {
        if (saved.isEmpty() || follows.isEmpty()) return saved
        val mine = HashSet<String>(follows).apply { addAll(keep) }
        return when (depth) {
            2 -> mine
            3 -> {
                if (links == null || follows.size < bar(minFollowers)) return saved
                val vouched = vouched(links, follows, minFollowers) ?: return saved
                mine.apply { addAll(vouched) }
            }
            else -> saved
        }
    }

    /** How many of the account's follows must follow someone: Min Followers, 0 and 1 both meaning one, as the relay counts. */
    fun bar(minFollowers: Int): Int = maxOf(minFollowers, 1)

    /**
     * Everyone in the links file at least [bar] of [follows] follow. Reads the
     * file as a stream (several MB for a big web) and keeps only the answer.
     * Null when it isn't the relay's `{"follows":[…],"links":{…}}` shape.
     */
    fun vouched(reader: Reader, follows: Set<String>, minFollowers: Int): Set<String>? = runCatching {
        Scanner(reader).run {
            expect('{')
            var mine: BooleanArray? = null
            val out = HashSet<String>()
            var done = false
            while (!done) {
                when (val key = string()) {
                    "follows" -> {
                        expect(':')
                        mine = strings().map { it in follows }.toBooleanArray()
                    }
                    "links" -> {
                        expect(':')
                        val m = mine ?: return@runCatching null // links before follows: can't count
                        val need = bar(minFollowers)
                        expect('{')
                        if (peek() == '}') next() else do {
                            val person = string()
                            expect(':')
                            // Each voucher once, even if an entry repeats one.
                            val counted = HashSet<Int>()
                            ints { if (it in m.indices && m[it]) counted += it }
                            val count = counted.size
                            if (count >= need) out += person
                        } while (comma('}'))
                    }
                    else -> { expect(':'); skipValue(); key }
                }
                done = !comma('}')
            }
            if (mine == null) null else out
        }
    }.getOrNull()

    /** Just enough JSON for the links file: objects, string arrays, int arrays, numbers. */
    private class Scanner(reader: Reader) {
        private val r = if (reader is java.io.BufferedReader) reader else reader.buffered(64 * 1024)
        private var ahead = -1

        fun peek(): Char {
            while (true) {
                if (ahead < 0) ahead = r.read()
                if (ahead < 0) error("end of file")
                if (!ahead.toChar().isWhitespace()) return ahead.toChar()
                ahead = -1
            }
        }

        fun next(): Char = peek().also { ahead = -1 }

        fun expect(c: Char) { if (next() != c) error("expected $c") }

        /** After a member: true on a comma, false on [close]. */
        fun comma(close: Char): Boolean = when (next()) {
            ',' -> true
            close -> false
            else -> error("expected , or $close")
        }

        fun string(): String {
            expect('"')
            val sb = StringBuilder(64)
            while (true) {
                val c = r.read().takeIf { it >= 0 }?.toChar() ?: error("end of file")
                when (c) {
                    '"' -> return sb.toString()
                    '\\' -> sb.append(r.read().toChar())
                    else -> sb.append(c)
                }
            }
        }

        fun strings(): List<String> {
            expect('[')
            val out = ArrayList<String>()
            if (peek() == ']') { next(); return out }
            do out += string() while (comma(']'))
            return out
        }

        fun ints(each: (Int) -> Unit) {
            expect('[')
            if (peek() == ']') { next(); return }
            do each(number().toInt()) while (comma(']'))
        }

        fun number(): Long {
            var c = peek()
            val sb = StringBuilder()
            while (c == '-' || c.isDigit() || c == '.' || c == 'e' || c == 'E' || c == '+') {
                sb.append(next())
                c = peekOrEnd() ?: break
            }
            return sb.toString().toDouble().toLong()
        }

        private fun peekOrEnd(): Char? = runCatching { peek() }.getOrNull()

        fun skipValue() {
            when (peek()) {
                '"' -> string()
                '[' -> { next(); if (peek() == ']') next() else do skipValue() while (comma(']')) }
                '{' -> { next(); if (peek() == '}') next() else do { string(); expect(':'); skipValue() } while (comma('}')) }
                't', 'f', 'n' -> { while (peekOrEnd()?.isLetter() == true) next() }
                else -> number()
            }
        }
    }
}
