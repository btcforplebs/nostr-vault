// A QR code drawn as one SVG path from the encoded modules; no HTML is built from the text.
import { encode } from "uqr"

export function QrCode({ text, label, size = 200 }) {
  const { data, size: n } = encode(text, { ecc: "M", border: 2 })
  let d = ""
  data.forEach((row, y) => row.forEach((on, x) => { if (on) d += `M${x} ${y}h1v1h-1z` }))
  return (
    <svg role="img" aria-label={label} viewBox={`0 0 ${n} ${n}`} width={size} height={size} shape-rendering="crispEdges" style="background: #fff; border-radius: 8px">
      <path d={d} fill="#000" />
    </svg>
  )
}
