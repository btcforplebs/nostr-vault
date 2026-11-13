// The stylesheets the boot bundle's own components ask for as they run (`if (import.meta.env) import("x.css")`, so
// the node tests can import those components without a CSS loader). Asked that way, each one was its own file, added
// to the page after the Feed had already drawn: the first paint had 2 sheets and the other 17 landed over the next
// ~600 ms while it was on screen. Imported here, from main.jsx, they are in the boot stylesheet index.html links,
// which the browser has before it draws anything, in this order (the order they used to be added in, so the cascade
// once they are all in is the one it was). test/boot-sheets.test.mjs fails when a component the boot bundle imports
// asks for a sheet that isn't here.
import "./moderation.css"
import "./sno.css"
import "./media.css"
import "./toast.css"
import "./wallet.css"
import "../readers/readers.css"
import "../readers/live.css"
import "./badges.css"
import "./feed-kinds.css"
import "./note-actions.css"
import "./note-card.css"
import "../box/box.css"
import "./edit-feeds.css"
import "./feed-dashboard.css"
import "./reels.css"
import "./feeds.css"
import "./compose.css"
import "./everyone-banner.css"
import "./outside-fold.css"
