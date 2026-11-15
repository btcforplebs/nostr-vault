// Light or dark before the first paint (Settings › Appearance; src/net/appearance.js owns the setting and keeps it
// in step after this). A classic script in <head>, so the page never flashes the other mode while the app loads.
(function () {
  try {
    var m = localStorage.getItem("display.appearance")
    var light = m === "light" || (m === "auto" && matchMedia("(prefers-color-scheme: light)").matches)
    if (light) document.documentElement.dataset.theme = "light"
  } catch (e) {}
})()
