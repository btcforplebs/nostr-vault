// Settings' first row in box mode: the box's own screens (#/box), where the browser relay's status card would be.
export { BOX } from "./mode.js"

export function BoxLink() {
  return (
    <section class="settings-group">
      <div class="section-label">This Box</div>
      <div class="settings-rows">
        <a class="settings-row" href="#/box">
          <span class="settings-title">Status, storage, mesh, devices and updates</span>
          <span aria-hidden="true">›</span>
        </a>
      </div>
    </section>
  )
}
