# Clean mode word list

`en.txt` is the one list of words that clean mode masks, on every platform. Clean mode is a local setting, off by default, that shows a listed word as its first letter plus asterisks, keeping its length and case (`Fuck` → `F***`). It changes only what is shown. It never changes the composer, drafts, what gets sent or signed, search, or stored events.

## Format

- One word per line: lowercase `a`–`z` only, no spaces, no comments.
- Sorted with `LC_ALL=C sort -u`, so there are no duplicates.
- Inflections are separate lines (`fuck`, `fucked`, `fucking`, …). Matching is whole-word and case-insensitive, so `ass` never matches inside `class` and the list never needs Scunthorpe exceptions.

## Copies in the apps

Each app ships a byte-identical copy:

| Platform | Copy |
|---|---|
| Web | `web-vault/src/net/clean-words-en.txt` |
| Android | `NostrVault/app/src/main/assets/clean-words-en.txt` |
| Apple | `HavenApp/HavenApp/Resources/clean-words-en.txt` (a symlink to `../../../docs/clean-words/en.txt` is fine) |

`docs/clean-words/check.sh` checks the format and that every copy that exists matches this file. Run it after you edit the list, then copy the list into each app:

```sh
cp docs/clean-words/en.txt web-vault/src/net/clean-words-en.txt
cp docs/clean-words/en.txt NostrVault/app/src/main/assets/clean-words-en.txt
docs/clean-words/check.sh
```

## What is left out on purpose

Words that are also everyday words or common names are not on the list, because clean mode masks display names too: `dick`, `cock`, `cum`, `cumming`, `hell`, `coon`, `porn`, `mf`. Their compounds that only mean the swear (`dickhead`, `cocksucker`) are on it.
