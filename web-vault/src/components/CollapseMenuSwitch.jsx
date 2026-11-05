// Settings › Appearance › Tab Bar › Collapse Menu on Scroll (iPhone AppearanceSettingsView, parity N6): whether the
// phone layout's bars fold as you scroll (components/chrome-fold.js). On by default.
import { useState } from "preact/hooks"
import { foldOn, setFoldOn } from "./chrome-fold.js"
import { SettingInfo } from "./SettingInfo.jsx"

export function CollapseMenuSwitch() {
  const [on, setOn] = useState(() => foldOn())
  return (
    <label class="settings-row static notify-switch">
      <span class="settings-title">Collapse Menu on Scroll<SettingInfo topic="display.tabBarAnimation" /></span>
      <input type="checkbox" role="switch" checked={on} onChange={e => { setFoldOn(e.currentTarget.checked); setOn(foldOn()) }} />
    </label>
  )
}
