/** Whether Accounts & Keys draws Reveal Key for an account: only a key made in this browser (method "local"), kept
 *  locked with its password. Extension and bunker accounts have no key here. */
export const canReveal = account => account?.method === "local" && typeof account.ncryptsec === "string" && !!account.ncryptsec
