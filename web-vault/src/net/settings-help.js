// The words behind a setting's (i) button, word for word the iPhone's (HavenApp Models/SettingsHelp.swift, keyed as
// Android's SettingsHelp.kt): change one and change the others. Only the topics the web shows are here. Where the
// web differs, it says so in the page's own note, never by changing these words.

export const HELP = {
  "account.blocked": ["Blocked", "Hides blocked accounts from your feed. For your main account, also blocks them from posting to your relay."],
  "feed.relays": ["Feed Relays", "Relays your feed pulls posts from. Separate from your own relay."],
  "post.sendDelay": ["Send Delay", "How long posts, replies, reposts and deletes wait before going out, so you can undo or edit them. Off sends right away with no undo."],
  "display.compactLines": ["Compact View Lines", "How many lines of a post's text show in Compact View before it is cut off."],
  "display.threadedLines": ["Threaded View Lines", "How many lines of text show in Threaded View. Replies show one line fewer than the post that starts the thread."],
  "display.defaultReaction": ["Default Reaction", "Sets which emoji is used for one-tap reactions."],
  "media.autoplay": ["Autoplay Videos", "Plays videos automatically as you scroll."],
  "privacy.vertex": ["Follower Counts from Vertex", "When you open someone's profile, asks Vertex (vertexlab.io) how many followers they have. The request is signed by your key, so Vertex learns whose profiles you open."],
  "privacy.fanfares": ["Check Fanfares Articles", "When a Fanfares article shows, asks Fanfares whether you have bought it. The request is signed by your key and names the article. Off, you check with a tap."],
  "notify.enable": ["Notifications", "Turns on notifications, made on this device by your relay — no outside push server involved."],
  "notify.perAccount": ["Alerts per Account", "Choose which alerts (mentions, replies, DMs, zaps, reactions, reposts, new followers) each account gets."],
}

/** { title, text } for a topic, or null when the web has no words for it (then no (i) is drawn). */
export const helpTopic = key => (HELP[key] ? { title: HELP[key][0], text: HELP[key][1] } : null)
