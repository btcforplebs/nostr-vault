// A QR code drawn as one SVG path from the encoded modules; no HTML is built from the text.
import { encode } from "uqr"

/** `ecc`: error correction; "L" draws fewer, bigger modules for a long link a phone camera must read across a desk. */
export function QrCode({ text, label, size = 200, ecc = "M" }) {
  const { data, size: n } = encode(text, { ecc, border: 2 })
  let d = ""
  data.forEach((row, y) => row.forEach((on, x) => { if (on) d += `M${x} ${y}h1v1h-1z` }))
  return (
    <svg role="img" aria-label={label} viewBox={`0 0 ${n} ${n}`} width={size} height={size} shape-rendering="crispEdges" style="background: #fff; border-radius: 8px">
      <path d={d} fill="#000" />
    </svg>
  )
}
