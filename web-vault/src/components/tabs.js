// Which of the five tabs a screen belongs to, so the bar lights the tab you reached it from, as on the phone.
// Someone else's profile is reached from Search. Screens not listed here (a thread, Compose) light no tab.
const PARENT = { messages: "vault", dm: "vault", notifications: "vault", relay: "vault", settings: "profile", accounts: "profile", wallet: "profile" }
export const tabOf = (route, otherProfile = false) => otherProfile ? "search" : PARENT[route] ?? route
