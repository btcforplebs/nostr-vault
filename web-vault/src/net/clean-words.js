// Loads the built-in clean mode list into clean-mode.js. Kept apart because a ?raw import only works through Vite;
// node tests call setCleanWords with the file themselves. docs/clean-words/check.sh keeps the copy identical.
import list from "./clean-words-en.txt?raw"
import { setCleanWords } from "./clean-mode.js"

setCleanWords(list)
