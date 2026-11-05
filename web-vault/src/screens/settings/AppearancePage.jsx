// Settings › Appearance (iPhone AppearanceSettingsView): Feed Text, Posts, Post buttons and Reactions, with the phone's
// headers and footers. Text size is the browser's own zoom on the web; the iPhone's Tab Bar, Translation, New Posts
// Pill and Zaps Only aren't settings here (the web refreshes on its own and has no on-device translator).
import { LineLimitSteppers } from "../../components/LineLimitSteppers.jsx"
import { NostrVaultLogoSwitch } from "../../components/NostrVaultLogoSwitch.jsx"
import { PostButtonsSwitch } from "../../components/PostButtonsSwitch.jsx"
import { DefaultReactionRow } from "../../components/DefaultReactionRow.jsx"
import { Section } from "./Section.jsx"

export function AppearancePage() {
  return (
    <>
      <Section label="Feed Text"><LineLimitSteppers /></Section>
      <Section label="Posts"><NostrVaultLogoSwitch /></Section>
      <Section label="Post buttons"><PostButtonsSwitch /></Section>
      <Section label="Reactions"><DefaultReactionRow /></Section>
      <p class="settings-note muted small">Text size follows your browser's zoom (⌘ + and ⌘ − on a Mac, Ctrl + and Ctrl − elsewhere).</p>
    </>
  )
}
