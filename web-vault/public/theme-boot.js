// Light or dark, and a custom accent colour, before the first paint (Settings › Appearance; src/net/appearance.js
// and src/net/accent.js own the settings and keep them in step after this). A classic script in <head>, so the page
// never flashes the other mode or the orange while the app loads.
(function () {
  try {
    var m = localStorage.getItem("display.appearance")
    var light = m === "light" || (m === "auto" && matchMedia("(prefers-color-scheme: light)").matches)
    if (light) document.documentElement.dataset.theme = "light"
    var css = localStorage.getItem("display.accentCss")
    if (css) {
      var el = document.createElement("style")
      el.id = "nv-accent"
      el.textContent = css
      document.head.appendChild(el)
    }
  } catch (e) {}
})()
