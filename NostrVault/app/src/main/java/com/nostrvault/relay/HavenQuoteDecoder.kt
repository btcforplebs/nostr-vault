package com.nostrvault.relay

import com.nostrvault.data.model.QuoteRef

/**
 * The real [QuoteRef.Decoder]: HavenBridge's bech32 decoders behind the
 * interface, so the parsing in [QuoteRef] stays free of the native library and
 * unit tests can substitute their own.
 */
object HavenQuoteDecoder : QuoteRef.Decoder {
    override fun noteToHex(note1: String): String? = HavenBridge.decodeNote(note1)
    override fun neventToHex(nevent1: String): String? = HavenBridge.decodeNevent(nevent1)
    override fun naddrToCoordinate(naddr1: String): QuoteRef.Coordinate? =
        HavenBridge.decodeNaddr(naddr1)

    override fun relayHints(identifier: String): List<String> =
        HavenBridge.relayHints(identifier)
}
