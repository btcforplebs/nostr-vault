package com.nostrvault.ui.screens

/**
 * What a Fanfares lock card says: status line, button and confirm labels.
 * Pure, so the rules are testable without Compose. iOS GatedLockCopy and
 * GatedArticleBody (before #812), where the app pays.
 */
internal object GatedLockCopy {
    fun status(author: String, priceSats: Int, paid: Boolean, fullyPaid: Boolean, failure: String?, waiting: Boolean): String {
        if (failure != null) return failure
        if (waiting) return "Paid. Waiting for the author's server to see your zap. This can take a minute or two."
        if (fullyPaid) return "You've zapped for this article. If it hasn't opened, the receipt is still on its way."
        if (paid) return "Part of the price went through. Zap the rest to unlock."
        return "Zap $author $priceSats sats to read the full article here."
    }

    fun buttonLabel(priceSats: Int, paid: Boolean, unpaidEmpty: Boolean, dueSats: Int): String = when {
        !paid -> "Zap $priceSats sats to unlock"
        unpaidEmpty -> "Check again"
        else -> "Zap the remaining $dueSats sats"
    }

    fun confirmTitle(shareCount: Int, dueSats: Int, author: String): String =
        if (shareCount == 1) "Zap $dueSats sats to $author?" else "Zap $dueSats sats to unlock?"

    /** After a failed pay: once money may have moved, warn before paying again. */
    fun payFailure(paid: Boolean, message: String): String =
        if (paid) "The zap may not have gone through ($message). Check your wallet before paying again — tap Check again if it did."
        else message

    const val RECEIPT_NOT_SEEN =
        "Your zap went through, but the key server hasn't seen the receipt yet. Tap Check again in a minute. It won't charge you again."
}
