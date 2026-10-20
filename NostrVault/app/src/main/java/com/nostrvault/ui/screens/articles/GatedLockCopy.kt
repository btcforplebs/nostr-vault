package com.nostrvault.ui.screens

/**
 * What a Fanfares lock card says: status line, button and confirm labels.
 * Pure, so the rules are testable without Compose. iOS GatedLockCopy and
 * GatedArticleBody (before #812), where the app pays.
 */
internal object GatedLockCopy {
    /** [dueSats]: what the button charges (every unpaid share, each rounded up), not the listed price. */
    fun status(author: String, dueSats: Int, paid: Boolean, fullyPaid: Boolean, failure: String?, waiting: Boolean): String {
        if (failure != null) return failure
        if (waiting) return "Paid. Waiting for the author's server to see your zap. This can take a minute or two."
        if (fullyPaid) return "You've zapped for this article. If it hasn't opened, the receipt is still on its way."
        if (paid) return "Part of the price went through. Zap the rest to unlock."
        return "Zap $author $dueSats sats to read the full article here."
    }

    /** Always names what tapping charges: the unpaid shares' total, never the listed price. */
    fun buttonLabel(paid: Boolean, unpaidEmpty: Boolean, dueSats: Int): String = when {
        !paid -> "Zap $dueSats sats to unlock"
        unpaidEmpty -> "Check again"
        else -> "Zap the remaining $dueSats sats"
    }

    fun confirmTitle(shareCount: Int, dueSats: Int, author: String): String =
        if (shareCount == 1) "Zap $dueSats sats to $author?" else "Zap $dueSats sats to unlock?"

    /** After a failed pay: once money may have moved, warn before paying again. */
    fun payFailure(paid: Boolean, message: String): String =
        if (paid) "The zap may not have gone through ($message). Check your wallet: if it paid, tap Check again; if not, tap Pay again."
        else message

    const val PAY_AGAIN_TITLE = "Pay again?"
    const val PAY_AGAIN_TEXT =
        "Only if your wallet shows no zap for this article. If it did pay, paying again charges you twice."

    const val RECEIPT_NOT_SEEN =
        "Your zap went through, but the key server hasn't seen the receipt yet. Tap Check again in a minute. It won't charge you again."
}
