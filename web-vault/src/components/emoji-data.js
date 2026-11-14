// The emoji the pickers offer, by category, and the words each answers to in Search: ReactionButton.jsx's sheet and
// the Emoji napplet (napplets/emoji/index.html carries a copy; test/napplet-emoji.test.mjs keeps them the same).
export const CATEGORIES = [
  ["Smileys", "😀 😃 😄 😁 😆 😅 🤣 😂 🙂 😉 😊 😇 🥰 😍 🤩 😘 😋 😛 😜 🤪 🤔 🤨 😐 😑 😶 🙄 😏 😬 😌 😔 😴 😷 🤒 🤯 🥳 😎 🤓 🧐 😕 😟 🙁 😮 😲 😳 🥺 😢 😭 😱 😤 😡 🤬 💀 🤡 👻 👽 🤖 💩"],
  ["Hearts & Hands", "❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 💯 💕 💖 💗 👍 👎 👌 🤌 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👋 🤚 ✋ 🖖 👏 🙌 🫶 👐 🤲 🤝 🙏 💪 🫡"],
  ["Fun & Activities", "🎉 🎊 🎁 🎈 ✨ 🔥 ⚡ 🌟 ⭐ 💫 🚀 🏆 🥇 🎯 🎮 🎲 🎵 🎶 🎸 🎤 🍕 🍔 🍟 🌮 🍣 🍩 🍪 🎂 🍺 🍻 🥂 🍷 ☕ 🧡 🫂 👀 🧠 💡 💰 ₿"],
  ["Animals & Nature", "🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐔 🐧 🐦 🦅 🦉 🐺 🐴 🦄 🐝 🦋 🐢 🐍 🐙 🦀 🐬 🐳 🌸 🌻 🌹 🌲 🌵 🍀 🍁 🌈 ☀️ 🌙 ❄️ 🌊"],
]

// Words each emoji answers to in Search, as well as its category's name.
export const KEYWORDS = {
  "😀": "smile happy grin", "😂": "laugh lol joy tears", "🤣": "laugh rofl lol", "😊": "smile blush happy", "😍": "love heart eyes",
  "🥰": "love hearts", "😘": "kiss", "😎": "cool sunglasses", "🤔": "think hmm", "🙄": "eyeroll", "😴": "sleep tired",
  "🤯": "mind blown wow", "🥳": "party celebrate", "😮": "wow surprised oh", "😲": "shocked wow", "😳": "flushed embarrassed",
  "🥺": "please pleading", "😢": "sad cry tear", "😭": "cry sob sad", "😱": "scream scared", "😡": "angry mad", "🤬": "angry swear",
  "💀": "dead skull dying", "🤡": "clown", "👻": "ghost", "💩": "poop", "❤️": "heart love red", "🧡": "heart orange bitcoin",
  "💔": "broken heart", "💯": "hundred perfect", "👍": "thumbs up yes like ok", "👎": "thumbs down no dislike", "👌": "ok perfect",
  "🤙": "shaka call hang loose", "👋": "wave hello hi bye", "👏": "clap applause", "🙌": "hands raise praise", "🫶": "heart hands love",
  "🤝": "handshake deal", "🙏": "pray please thanks", "💪": "strong muscle flex", "🫡": "salute", "🎉": "party tada celebrate",
  "✨": "sparkles magic", "🔥": "fire hot lit", "⚡": "lightning zap bolt", "🌟": "star", "⭐": "star", "🚀": "rocket moon launch",
  "🏆": "trophy win", "🎯": "target bullseye", "🎵": "music note", "🍕": "pizza", "🍺": "beer", "☕": "coffee", "👀": "eyes look",
  "🧠": "brain smart", "💡": "idea bulb", "💰": "money bag", "₿": "bitcoin btc", "🐶": "dog puppy", "🐱": "cat kitty",
  "🦄": "unicorn", "🐝": "bee", "🌈": "rainbow", "☀️": "sun", "🌙": "moon night", "🌊": "wave ocean sea",
}
