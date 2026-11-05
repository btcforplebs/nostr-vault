package com.nostrvault.ui.screens

// ── New to Nostr Vault? ──────────────────────────────────────────

/**
 * Setup's second question, asked of people who already use Nostr once their
 * key is in (PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md). Yes, and every way
 * out of "Copy from my other vault" (copied, not reached, or "Lost your other
 * device?"), bring the notes from relays: the relay check, then the import
 * tour.
 */
fun SetupWizardViewModel.bringNotesFromRelays() {
    _error.value = null
    _step.value = stepAfter(WizardStep.NEW_TO_VAULT)
}
