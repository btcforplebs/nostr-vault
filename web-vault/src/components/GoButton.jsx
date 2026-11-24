// The arrow button inside a sign-in text box (SignInScreen.jsx bunker link, ReadOnlySignIn.jsx): submits its form.
/** The arrow at the right end of a sign-in text box: submits its form. `label` names it for screen readers and the tooltip. */
export function GoButton({ label, disabled, busy }) {
  return (
    <button type="submit" class="field-go" disabled={disabled} aria-busy={busy || undefined} aria-label={label} title={label}>
      <svg viewBox="0 0 20 20" width="18" height="18" aria-hidden="true"><path d="M4 10h11M10.5 5.5 15 10l-4.5 4.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" /></svg>
    </button>
  )
}
