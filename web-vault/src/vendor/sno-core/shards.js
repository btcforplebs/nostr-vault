// Vendored from arkin0x/sno-core ea2c9fdd06b3 (v0.1.24, MIT per its package.json), file dist/shards.js: built with its own
// `npm run build` (tsc). Not edited here; to update, rebuild sno-core and copy again. Credit: README.md.
/**
 * shards.ts — the shape of a shard, and nothing about where it goes.
 *
 * A shard is a small 3D object: vertices with colors, optional triangles,
 * and a render mode. The mesh is only one way to draw it. Vertices alone can
 * be lights, and a polyline through them blends their colors along the line
 * the way a mesh blends across a face, so the same vertex list carries all
 * three and the mode is a property of the shard, not of the viewer.
 *
 * Vertices sit on an integer grid in model units, and a shard carries the
 * exponent that says what one unit is in gibsons, so a gibson-sized trinket
 * and a sector-sized monument are the same data at different `unit`. Integers
 * because precision is the whole point of this client: a vertex is at a
 * coordinate, not near one.
 *
 * Pure. The builder store mutates copies of these; the world draws them.
 */
import { applyPose, wrapSpin } from './pose.js';
import { BUILT_IN, colorAt, indexOf, resolvePalette, toBytes } from './snoPalette.js';
/**
 * A vertex copied whole, ticks included.
 *
 * The two halves of a position, whole units in `p` and the remainder in `t`,
 * have to travel together. A copy that takes `p` and `c` and forgets `t`
 * silently moves every sub-unit vertex onto the corner of its cell, and
 * vertices that shared a cell land on each other, which turns their faces
 * into triangles with no area that draw nothing at all.
 */
export function cloneVertex(v) {
    return { p: [...v.p], ...(v.t ? { t: [...v.t] } : {}), c: [...v.c] };
}
/**
 * Ticks to a grid unit. A position is stored as whole ticks, so a third, a
 * quarter or a fifth of a unit is exact and they mix freely in one shard:
 * 120 is divisible by every division the workshop offers and by eighths.
 */
export const TICKS_PER_UNIT = 120;
/**
 * The grid divisions offered, all of them exact.
 *
 * A vertex is stored in 120ths of a unit (TICKS_PER_UNIT), so a division is
 * only offered when it divides 120 without a remainder: sevenths and ninths
 * would land vertices between ticks and could not be written to the wire.
 * Past 10 the finer steps are 12, 20, 24, 30, 40, 60 and 120, the last being
 * a single tick (arkinox, 2026-10-15). Fiftieths are deliberately absent:
 * 120 / 50 is not whole. 15 is exact too but adds little between 12 and 20.
 */
export const DIVISIONS = [1, 2, 3, 4, 5, 6, 8, 10, 12, 20, 24, 30, 40, 60, 120];
export const MODES = ['solid', 'points', 'lines'];
/**
 * What a writer calls an object whose author has not named it, or has
 * cleared the name. DECK-0003 §1.1 requires a name that is not blank, and
 * advises a writer to supply a placeholder so that nobody publishes an
 * object every reader refuses by leaving a text box empty.
 */
export const PLACEHOLDER_NAME = 'Untitled';
/**
 * Whether a name is blank under DECK-0003 §1.9 rule 1a: empty, or nothing but
 * whitespace, which the deck defines as Unicode's White_Space characters.
 * Spelled out rather than left to `trim()`, which also strips U+FEFF, a
 * character the deck does not count and the reference keeps.
 */
export function blankName(name) {
    return /^[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]*$/.test(name);
}
/**
 * The optional payload fields that are refused when written as null
 * (DECK-0003 §1.1): null is not absence. `extent` and `opacity` are not among
 * them, because each is repaired rather than validated and null is one more
 * malformed value (8 for `extent`, fully opaque for `opacity`, §1.11); `type`
 * is not among them because it is ignored whatever it is.
 */
const NULL_REFUSED = ['ticks', 'palette', 'facecolors', 'up', 'spin', 'refs', 'parts'];
/**
 * Every payload field this library reads (DECK-0003 §1.1), and `type`, the
 * legacy field it ignores (§1.1a). Anything else is carried in `extra`.
 * `type` is known so that it is dropped rather than carried: a publisher
 * SHOULD NOT write it, and carrying it would write it again on every edit.
 */
export const PAYLOAD_FIELDS = [
    'v', 'type', 'name', 'unit', 'extent', 'mode', 'vertices', 'ticks', 'colors', 'faces', 'facecolors', 'palette', 'up', 'spin', 'refs', 'parts', 'opacity', 'objects',
];
const everyFieldListed = true;
void everyFieldListed;
const KNOWN = new Set(PAYLOAD_FIELDS);
/**
 * How each field that this library learned to read after it began carrying
 * unknown fields (0.1.17) is lifted out of `extra`. A model saved by an older
 * version holds such a field in `extra`; once the field is known, `toPayload`
 * no longer writes it from there, so without a lift it would be dropped at the
 * next publish. The lift runs when a stored model is loaded (normalizeStored),
 * never at write time, where a value the author has since cleared would come
 * back. Each lift reads the value as that field's own reader does, and leaves
 * a model that already has the field as it is.
 */
const LIFTS = {
    // 0.1.18: `opacity` (DECK-0003 §1.11). Read as the field's reader reads it,
    // so a malformed carried value lifts to nothing, which is opaque.
    opacity: (s, value) => {
        // A valid value of the model's own wins; a malformed one gives way.
        if (readOpacity(s.opacity) !== undefined)
            return s;
        const o = readOpacity(value);
        return o === undefined ? s : { ...s, opacity: o };
    },
    // 0.1.20: `objects` (DECK-0003 §1.10), read as fromPayload reads it. A table
    // the model already holds wins, as a known field always does.
    objects: (s, value) => {
        if (s.objects)
            return s;
        const o = readObjects(value);
        return o ? { ...s, objects: o } : s;
    },
};
/**
 * `s` with every field in `extra` that this version knows taken out of it:
 * lifted onto the model where there is a lift for it, dropped otherwise
 * (a known field is always the one this library computes). The same model
 * when there is nothing to do.
 */
export function liftKnown(s) {
    const extra = s.extra;
    if (!extra || !Object.keys(extra).some((k) => KNOWN.has(k)))
        return s;
    const { extra: _carried, ...bare } = s;
    let out = bare;
    for (const [k, v] of Object.entries(extra))
        if (KNOWN.has(k) && LIFTS[k])
            out = LIFTS[k](out, v);
    const rest = Object.entries(extra).filter(([k]) => !KNOWN.has(k));
    return rest.length ? { ...out, extra: Object.fromEntries(rest) } : out;
}
/**
 * The fields of `p` this library does not know, as a fresh object, or
 * undefined when there are none. Built with Object.fromEntries, which defines
 * each key as a plain property of its own, so a payload carrying a key named
 * `__proto__` (JSON.parse makes it an ordinary own key) is carried as data and
 * can never reach an object's prototype. The values are deep copies: the
 * model never shares structure with the event it was read from. A value that
 * cannot be copied (a function or a symbol, which no JSON payload can hold)
 * is left behind rather than thrown on.
 */
export function unknownFields(p) {
    const entries = [];
    for (const [k, v] of Object.entries(p)) {
        if (KNOWN.has(k) || v === undefined)
            continue;
        try {
            entries.push([k, structuredClone(v)]);
        }
        catch { /* not data: not carried */ }
    }
    return entries.length ? Object.fromEntries(entries) : undefined;
}
/** The carried fields to write: `extra` without anything this library computes. Not copied again. */
function carried(extra) {
    return Object.fromEntries(Object.entries(extra).filter(([k, v]) => !KNOWN.has(k) && v !== undefined));
}
/** Default half-width of the build grid, in units; each shard keeps its own (`extent`). */
export const GRID_HALF = 8;
export const MIN_EXTENT = 1;
export const MAX_EXTENT = 64;
// There is no ceiling on vertices or faces (DECK-0003 §1.8, 2026-09-24): the
// event's size is the relay's concern, as it is for every other kind. The
// constants that stood here, 512 and 1024, are gone rather than kept as
// advice, so nothing downstream can enforce them by habit.
/**
 * The largest `unit` a shard can be built or deployed at.
 *
 * One unit is 2^unit gibsons and there are 2^33 gibsons to a meter, so 2^84 is
 * about 2.4e15 meters, a quarter of a light year: past a sector and well past
 * anything a shard should span. 0 is the floor, one gibson, about 116 pm.
 */
export const MAX_UNIT = 84;
/**
 * A unit brought inside the bounds, as a whole number.
 *
 * The workshop's DEPLOY SCALE MULTIPLIER and the deploy bar's SCALE MULTIPLIER
 * are the same quantity set in two places, so they clamp through one function
 * rather than repeating the same two literals and drifting apart.
 */
export function clampUnit(unit) {
    return Math.max(0, Math.min(MAX_UNIT, Math.round(unit)));
}
/**
 * A new shard draws LINES: the first tap glows and the second draws a line,
 * so the very first thing you do is visible. Faces switch it to SOLID when
 * the first stamp with faces lands (see the workshop store).
 */
export function newShard(name = 'Untitled shard') {
    return { id: uuid(), name, unit: 0, extent: GRID_HALF, mode: 'lines', vertices: [], faces: [], up: false, spin: 0, updatedAt: Date.now() };
}
/** A grid point as a map key, so "the same point" is one string compare. */
/** A point's key, from its position in total ticks. */
export function pointKey(p) {
    return `${p[0]},${p[1]},${p[2]}`;
}
/** A vertex's position as total ticks, the form arithmetic and keys use. */
export function ticksOf(v) {
    const t = v.t ?? [0, 0, 0];
    return [v.p[0] * TICKS_PER_UNIT + t[0], v.p[1] * TICKS_PER_UNIT + t[1], v.p[2] * TICKS_PER_UNIT + t[2]];
}
/** A vertex from a position in total ticks: whole units, and the rest as ticks only when there is any. */
export function vertexAt(total, c) {
    const p = total.map((x) => Math.floor(x / TICKS_PER_UNIT));
    const t = total.map((x, a) => x - p[a] * TICKS_PER_UNIT);
    return t[0] === 0 && t[1] === 0 && t[2] === 0 ? { p, c } : { p, t, c };
}
export function uuid() {
    if (typeof crypto !== 'undefined' && 'randomUUID' in crypto)
        return crypto.randomUUID();
    return Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join('');
}
/** Integers inside the grid; anything else is not a vertex. */
export function validPoint(p, extent = GRID_HALF) {
    return p.every((v) => Number.isInteger(v) && Math.abs(v) <= extent * TICKS_PER_UNIT);
}
/**
 * A stored model made whole again. Models have always kept `p` in units; for
 * a short while after ticks arrived they kept total ticks there instead, and
 * such a model shows itself by a coordinate no grid could hold (above
 * MAX_EXTENT units). Those are split back into units and ticks.
 */
export function normalizeStored(saved) {
    // A field an older version carried in `extra` and this one knows (liftKnown),
    // then an opacity a stored model holds read as the field's reader reads it
    // (§1.11): 100 or a malformed value (a bug, or null after storage) is absent.
    const lifted = liftKnown(saved);
    const { opacity: _held, ...bare } = lifted;
    const opacity = readOpacity(lifted.opacity);
    const s = lifted.opacity === opacity ? lifted : opacity === undefined ? bare : { ...bare, opacity };
    // Models from before the pose have no `up` or `spin`: they lie as built.
    const stored = s;
    const posed = stored.up === undefined || stored.spin === undefined ? { ...s, up: stored.up ?? false, spin: stored.spin ?? 0 } : s;
    const inTicks = posed.vertices.some((v) => v.t === undefined && v.p.some((c) => Math.abs(c) > MAX_EXTENT));
    if (!inTicks)
        return posed;
    return { ...posed, vertices: posed.vertices.map((v) => vertexAt(v.p, v.c)) };
}
/** The grid half-width a shard needs to hold every vertex it has. */
export function neededExtent(s) {
    let m = MIN_EXTENT;
    for (const v of s.vertices)
        for (const c of ticksOf(v))
            m = Math.max(m, Math.ceil(Math.abs(c) / TICKS_PER_UNIT));
    // Where each placed object stands, too (§1.10): its own reach is known only
    // once it is fetched, but its origin always stands on this object's grid.
    for (const p of s.parts ?? [])
        for (const c of p.at)
            m = Math.max(m, Math.ceil(Math.abs(c) / TICKS_PER_UNIT));
    return m;
}
export function clampColor(c) {
    return c.map((v) => Math.min(1, Math.max(0, Number.isFinite(v) ? v : 0)));
}
/** A face needs three distinct vertices that exist. */
export function validFace(f, count) {
    return f.every((i) => Number.isInteger(i) && i >= 0 && i < count) && new Set(f).size === 3;
}
/**
 * The wire's handedness, and why it is not this client's.
 *
 * DECK-0003 §2: an SNO payload is right-handed with Y up and +Z toward the
 * viewer, which is the glTF and three.js convention, so that any tool can read
 * one without a special case. Cyberspace's own +Z is the black sun, away from
 * the viewer, and everything in this client is built in that frame.
 *
 * The two differ by one sign, so the conversion is a negation of Z and it
 * happens here, at the payload boundary, and nowhere else. Nothing inside the
 * client changes: no stored model moves, no renderer changes, nothing already
 * on screen looks different. What changes is that what goes out on the wire is
 * readable by anyone.
 *
 * `v` says which frame a payload is in. `1` is what this client wrote while the
 * format lived only here, and its Z is already this client's, so it is read
 * unchanged. `2` is the published convention and is negated on the way in and
 * on the way out. A publisher writes 2 forever.
 */
export const WIRE_VERSION = 2;
/** A vertex with its Z negated, on total ticks so the floor and the remainder stay consistent. */
function flipZ(v) {
    const [x, y, z] = ticksOf(v);
    // `0 - z` rather than `-z`, for the reason toRender gives: negating a zero
    // gives -0, which deep equality and object keys treat as a different number.
    return vertexAt([x, y, 0 - z], v.c);
}
/** The 64-unit position bound of DECK-0003 §1.8, in ticks: how far a placement may stand. */
export const PART_REACH = 64 * TICKS_PER_UNIT;
const HEX64 = /^[0-9a-f]{64}$/;
const ADDRESS = /^33331:[0-9a-f]{64}:/;
/**
 * §1.10 and §1.9 rule 16: the `objects` a payload carries, or undefined for
 * none. Never a refusal: a value that is not a JSON object, null and arrays
 * included, reads as absent, and a key that is not an address
 * (`33331:<64 lowercase hex>:<d>`) is dropped. The values are deep copies of
 * whatever came, unchecked, because each one is checked on its own when a
 * placement draws from it. Built with Object.fromEntries, as unknownFields is,
 * so a key named `__proto__` stays data.
 */
export function readObjects(raw) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw))
        return undefined;
    const entries = [];
    for (const [k, v] of Object.entries(raw)) {
        if (!ADDRESS.test(k) || v === undefined)
            continue;
        try {
            entries.push([k, structuredClone(v)]);
        }
        catch { /* not data: not carried */ }
    }
    return entries.length ? Object.fromEntries(entries) : undefined;
}
/** A table entry as written: its own `objects` taken off, since a table is flat (§1.10). The same value when it has none. */
function flatEntry(entry) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry) || !('objects' in entry))
        return entry;
    const { objects: _nested, ...rest } = entry;
    return rest;
}
/**
 * The table `toPayload` writes (§1.10): every entry the model holds under an
 * address, each with its own `objects` taken off, because a reader ignores a
 * table inside the table and a writer flattens; its keys in order of their
 * Unicode code points, so a table has one spelling; and nothing at all when it
 * holds none (the canonical form, §1.2).
 *
 * Taking a nested table off rather than merging it up is deliberate: a reader
 * already ignores it, so merging it would change what the object draws.
 * `carryObject` (parts.ts) is where a writer flattens on purpose.
 *
 * It does not drop entries no placement reaches. The root's table answers
 * beneath a fetched object too, so an entry may be reached only through an
 * object this library cannot see from here; `carryAll` prunes, with the
 * writer's own lookup, and `removeParts` drops what it alone stops reaching.
 */
function writtenObjects(s) {
    const table = s.objects;
    if (!table || typeof table !== 'object' || Array.isArray(table))
        return undefined;
    const out = Object.entries(table).filter(([k, v]) => ADDRESS.test(k) && v !== undefined).map(([k, v]) => [k, flatEntry(v)]);
    out.sort(([a], [b]) => byCodePoint(a, b));
    return out.length ? Object.fromEntries(out) : undefined;
}
/** Two strings in order of their Unicode code points (not UTF-16 units, which order astral characters differently). */
function byCodePoint(a, b) {
    const x = [...a], y = [...b];
    for (let i = 0; i < Math.min(x.length, y.length); i++) {
        const d = x[i].codePointAt(0) - y[i].codePointAt(0);
        if (d)
            return d;
    }
    return x.length - y.length;
}
/** The `a` targets a raw payload's `refs` names, read leniently: what an entry of a table may reach. */
export function addressesIn(raw) {
    const refs = raw && typeof raw === 'object' ? raw.refs : undefined;
    if (!Array.isArray(refs))
        return [];
    return refs.filter((r) => Array.isArray(r) && r[0] === 'a' && typeof r[1] === 'string').map((r) => r[1]);
}
/** §1.9 rule 11: one `refs` entry as the wire writes it, or null. */
function readRef(r) {
    if (!Array.isArray(r) || r.length < 2 || r.length > 3)
        return null;
    const [kind, target, relay] = r;
    if (relay !== undefined && typeof relay !== 'string')
        return null;
    if (typeof target !== 'string')
        return null;
    if (!(kind === 'e' && HEX64.test(target)) && !(kind === 'a' && ADDRESS.test(target)))
        return null;
    return relay ? [kind, target, relay] : [kind, target];
}
/**
 * A turn seen through the Z mirror between the wire and the model: turns
 * about X and Y change sign, a turn about Z does not. Its own inverse.
 */
export function mirrorTurn(t) {
    return [(360 - t[0]) % 360, (360 - t[1]) % 360, t[2]];
}
/** §1.9 rule 12: one placement, eight integers, or null; `mirror` brings a v2 one into the model frame. */
function readPart(e, refCount, mirror) {
    if (!Array.isArray(e) || e.length !== 8 || !e.every((n) => Number.isInteger(n)))
        return null;
    const [ref, x, y, z, a, b, c, step] = e;
    if (ref < 0 || ref >= refCount)
        return null;
    if ([x, y, z].some((n) => n < -PART_REACH || n > PART_REACH))
        return null;
    if ([a, b, c].some((n) => n < 0 || n > 359))
        return null;
    const turn = [a, b, c];
    // `0 - z`, not `-z`: see toRender.
    return { ref, at: mirror ? [x, y, 0 - z] : [x, y, z], turn: mirror ? mirrorTurn(turn) : turn, step };
}
/** The least opacity an object is drawn at, in percent: nothing is ever wholly invisible (DECK-0003 §1.11). */
export const OPACITY_FLOOR = 10;
/**
 * The `opacity` a payload carries, or undefined for fully opaque.
 *
 * A malformed value (not an integer, outside 1..100, null, a string) is
 * repaired to opaque rather than refused, as `extent` is repaired (§1.11):
 * opaque is always a correct way to draw an object, so a bad value costs the
 * author their translucency and nothing else. 100 reads as absent too, so a
 * model only ever holds 1 to 99.
 */
export function readOpacity(raw) {
    return Number.isInteger(raw) && raw >= 1 && raw < 100 ? raw : undefined;
}
/**
 * The opacity to draw `s` at, as a fraction from 0.1 to 1: its own percent
 * with the floor applied, or 1 when it has none. A placed object's comes from
 * its own model, never from the object that places it (§1.10), and a reader
 * drawing an avatar ignores it altogether (§3.3).
 */
export function drawnOpacity(s) {
    const o = readOpacity(s.opacity);
    return o === undefined ? 1 : Math.max(o, OPACITY_FLOOR) / 100;
}
export function toPayload(s) {
    const vertices = s.vertices.map(flipZ);
    const palette = s.palette ?? BUILT_IN;
    return {
        v: WIRE_VERSION,
        // §1.1: a blank name makes a payload every reader refuses, so the writer
        // puts the placeholder back rather than publish one.
        // A stored model from before names were required may have none at all.
        name: typeof s.name !== 'string' || blankName(s.name) ? PLACEHOLDER_NAME : s.name,
        unit: s.unit,
        extent: s.extent,
        mode: s.mode,
        vertices: vertices.map((v) => v.p),
        ticks: packTicks(vertices.map((v) => v.t ?? [0, 0, 0])),
        ...(s.palette ? { palette: s.palette } : {}),
        colors: vertices.map((v) => indexOf(palette, toBytes(v.c))),
        ...(s.facecolors && s.facecolors.length === s.faces.length
            ? { facecolors: packFaceColors(s.facecolors.map((c) => indexOf(palette, toBytes(c)))) }
            : {}),
        // §1.10, through the same mirror as the vertices.
        ...(s.refs && s.refs.length && s.parts && s.parts.length
            ? { refs: s.refs.map((r) => [...r]), parts: s.parts.map((q) => [q.ref, q.at[0], q.at[1], 0 - q.at[2], ...mirrorTurn(q.turn), q.step]) }
            : {}),
        faces: s.faces,
        // `up` and `spin` are carried as data. They say the object stands on the
        // Earth where it is hidden, which is a Cyberspace idea; here an object has
        // no place, so they travel untouched and nothing applies them.
        ...(s.up ? { up: true, spin: wrapSpin(s.spin) } : {}),
        // §1.11: written only below 100, the canonical form, and only when valid.
        ...(readOpacity(s.opacity) !== undefined ? { opacity: s.opacity } : {}),
        // §1.10: what this object carries for its placements, flat, in key order.
        ...(() => { const o = writtenObjects(s); return o ? { objects: o } : {}; })(),
        // Fields this library does not know, written back as they were read
        // (ShardModel.extra). Last, and filtered again, so a known field is always
        // the one this library computed and can never be replaced by a stray copy.
        ...(s.extra ? carried(s.extra) : {}),
    };
}
/**
 * Strict on shape, forgiving on nothing: a payload is what the wire gives
 * back, and a shard with a face pointing at a vertex it does not have would
 * throw inside three.js at draw time, far from anything that could explain it.
 */
/** The ticks column for the wire: runs of whole positions become one negative count. */
export function packTicks(rest) {
    const out = [];
    let zeros = 0;
    for (const t of rest) {
        if (t[0] === 0 && t[1] === 0 && t[2] === 0) {
            zeros++;
            continue;
        }
        if (zeros) {
            out.push(-zeros);
            zeros = 0;
        }
        out.push(t);
    }
    if (zeros)
        out.push(-zeros);
    return out;
}
/**
 * Face colours packed for the wire (DECK-0003 §1.4a).
 *
 * The same run-length shape as `ticks`, for the same reason: the common case
 * is a run. A stamped block is twelve triangles of one colour, so a solid cube
 * is `[[1, 0, 0], -11]` rather than twelve copies of the same triple. The
 * first entry is always a triple, because a run has nothing to repeat before
 * one.
 */
export function packFaceColors(indices) {
    const out = [];
    let run = 0;
    for (let i = 0; i < indices.length; i++) {
        if (i > 0 && indices[i] === indices[i - 1]) {
            run++;
            continue;
        }
        if (run) {
            out.push(-run);
            run = 0;
        }
        out.push(indices[i]);
    }
    if (run)
        out.push(-run);
    return out;
}
/**
 * Face colours read back, one index per face, or null when they do not fit
 * `count` faces or name a colour the palette does not have.
 *
 * The sign separates an index from a run, which works because an index is
 * never negative. It is the same trick `ticks` uses, and it is why a colour
 * had to become one number before face colours were affordable: a list of
 * triples interleaved with run markers cost more than it saved.
 */
export function unpackFaceColors(packed, count, palette) {
    if (packed === undefined)
        return null;
    // An empty list is one colour for each of no faces: valid on an object with
    // no faces, and too short for any other (§1.4a, as the reference reads it).
    if (!Array.isArray(packed))
        return null;
    const out = [];
    for (const e of packed) {
        if (!Number.isInteger(e))
            return null;
        if (e < 0) {
            // A run repeats the index before it, so the first entry cannot be one.
            if (out.length === 0)
                return null;
            const prev = out[out.length - 1];
            for (let i = 0; i < -e; i++)
                out.push(prev);
        }
        else {
            if (e >= palette.length)
                return null;
            out.push(e);
        }
        if (out.length > count)
            return null;
    }
    return out.length === count ? out : null;
}
/**
 * A shard with its face colours turned into vertex colours, for drawing.
 *
 * A face colour is a hard seam: the three corners of a triangle must all be
 * that colour and nothing may interpolate across the edge into the next one.
 * Shared vertices cannot express that, since a vertex belongs to every face
 * that touches it, so each face gets three corners of its own.
 *
 * Done here, once, before anything else looks at the geometry, so the winding
 * pass, the clipper and the face picker all work on ordinary vertex colours
 * and none of them has to know this feature exists. Face order is preserved,
 * which is what keeps a tap on a face resolving to the same face.
 *
 * This is a render-time expansion and never goes back on the wire, so it is
 * not subject to the format's vertex ceiling.
 */
export function expandFaceColors(s) {
    if (!s.facecolors || s.facecolors.length !== s.faces.length || s.faces.length === 0)
        return s;
    const vertices = [];
    const faces = [];
    s.faces.forEach((f, i) => {
        const c = clampColor(s.facecolors[i]);
        const base = vertices.length;
        for (const vi of f)
            vertices.push({ ...s.vertices[vi], c });
        faces.push([base, base + 1, base + 2]);
    });
    return { ...s, vertices, faces, facecolors: undefined };
}
/** The ticks column read back, one triple per vertex, or null when it does not fit `count` vertices. */
export function unpackTicks(packed, count) {
    if (packed === undefined)
        return Array.from({ length: count }, () => [0, 0, 0]);
    if (!Array.isArray(packed))
        return null;
    const out = [];
    for (const e of packed) {
        if (typeof e === 'number') {
            if (!Number.isInteger(e) || e >= 0)
                return null;
            for (let i = 0; i < -e; i++)
                out.push([0, 0, 0]);
        }
        else if (Array.isArray(e) && e.length === 3 && e.every((t) => Number.isInteger(t) && t >= 0 && t < TICKS_PER_UNIT)) {
            out.push([e[0], e[1], e[2]]);
        }
        else
            return null;
        if (out.length > count)
            return null;
    }
    return out.length === count ? out : null;
}
export function fromPayload(raw, id, fetchedPalette) {
    if (!raw || typeof raw !== 'object')
        return null;
    const p = raw;
    // DECK-0003 §1.1a: there is no `type` field. Payloads written before that
    // deck carry `type: "shard"`; it is ignored here and never rejected on,
    // because the field is noise and rejecting on noise would refuse every
    // object anyone else writes correctly.
    if (p.v !== 1 && p.v !== WIRE_VERSION)
        return null;
    // §1.9 rule 1a: a name is required and must not be blank. Its length is not
    // checked; it is truncated below.
    if (typeof p.name !== 'string' || blankName(p.name))
        return null;
    // §1.1: an optional field written as null is refused, not read as absent.
    if (NULL_REFUSED.some((k) => p[k] === null))
        return null;
    if (!Array.isArray(p.vertices) || !Array.isArray(p.colors) || !Array.isArray(p.faces))
        return null;
    if (p.vertices.length !== p.colors.length)
        return null;
    if (!MODES.includes(p.mode))
        return null;
    if (!Number.isInteger(p.unit) || p.unit < 0 || p.unit > MAX_UNIT)
        return null;
    const rest = unpackTicks(p.ticks, p.vertices.length);
    if (!rest)
        return null;
    if (p.up !== undefined && typeof p.up !== 'boolean')
        return null;
    if (p.spin !== undefined && (!Number.isInteger(p.spin) || p.spin < 0 || p.spin > 359))
        return null;
    // §1.3a: which colours the indices name. A reference that has not resolved
    // is the built-in rather than a failure, so an object is never undrawable
    // because a second event is missing.
    const palette = resolvePalette(p.palette, fetchedPalette);
    if (!palette)
        return null;
    const up = p.up === true;
    const vertices = [];
    for (let i = 0; i < p.vertices.length; i++) {
        const pt = p.vertices[i], c = p.colors[i];
        // Integers as JSON writes them (§1.9 rule 6): "1", true and null are not
        // coordinates, so nothing is coerced through Number() on the way in.
        if (!Array.isArray(pt) || pt.length !== 3 || !pt.every((n) => Number.isInteger(n)))
            return null;
        const whole = [pt[0], pt[1], pt[2]];
        const r = rest[i];
        // A literal triple stays exactly as written: every shard made before the
        // palette existed is one, and snapping them on read would change objects
        // nobody asked to change. They snap when they are next published.
        //
        // Accepted in version 2 as well as version 1, and that is not laxity about
        // the spec. Version 2 is two changes that did not ship together: the wire
        // turned right-handed first (ONOSENDAI #165), and colour became an index
        // two releases later (#167). Objects written in between declare v2, carry
        // triples, and are correct in every other respect including their frame.
        // Refusing them orphans real work, and the two forms cannot be confused,
        // because one is an array and the other an integer. §1.3 says an index is
        // what a writer produces; this is only what a reader tolerates, the same
        // way §1.1a has it ignore a stray `type` rather than reject on it.
        //
        // The frame still follows the declared version: one of these is in the v2
        // frame and flipping it as though it were v1 would mirror the object.
        let colour;
        const triple = c;
        if (Array.isArray(triple)) {
            if (triple.length !== 3 || !triple.every((n) => typeof n === 'number'))
                return null;
            colour = clampColor(triple);
        }
        else {
            // An index is version 2's form, and version 1 never had one.
            if (p.v === 1)
                return null;
            if (!Number.isInteger(c) || c < 0 || c >= palette.length)
                return null;
            colour = colorAt(palette, c);
        }
        const read = r[0] === 0 && r[1] === 0 && r[2] === 0 ? { p: whole, c: colour } : { p: whole, t: r, c: colour };
        // A v1 payload is already in this client's frame; a v2 one is the wire's.
        vertices.push(p.v === WIRE_VERSION ? flipZ(read) : read);
    }
    const faces = [];
    for (const f of p.faces) {
        // As for vertices: validFace refuses anything that is not an integer.
        if (!Array.isArray(f) || f.length !== 3)
            return null;
        const face = [f[0], f[1], f[2]];
        if (!validFace(face, vertices.length))
            return null;
        faces.push(face);
    }
    // §1.4a: present means exactly one colour per face. A list that expands to
    // any other length is a defect in the payload, not something to pad.
    let facecolors;
    // Face colours arrived with the palette, so there is no v1 form of them.
    if (p.facecolors !== undefined) {
        const expanded = unpackFaceColors(p.facecolors, faces.length, palette);
        if (!expanded)
            return null;
        facecolors = expanded.map((i) => colorAt(palette, i));
    }
    // §1.9 rules 11 and 12. A `parts` whose index has no `refs` entry is a
    // rejection, which the range check gives for free when `refs` is absent.
    let refs;
    if (p.refs !== undefined) {
        if (!Array.isArray(p.refs))
            return null;
        refs = [];
        for (const r of p.refs) {
            const ref = readRef(r);
            if (!ref)
                return null;
            refs.push(ref);
        }
    }
    let parts;
    if (p.parts !== undefined) {
        if (!Array.isArray(p.parts))
            return null;
        parts = [];
        for (const e of p.parts) {
            const part = readPart(e, refs?.length ?? 0, p.v === WIRE_VERSION);
            if (!part)
                return null;
            parts.push(part);
        }
    }
    const extra = unknownFields(p);
    const opacity = readOpacity(p.opacity);
    // §1.10: read, never a reason to refuse (rule 16); the entries are checked one
    // at a time when a placement draws from them (parts.ts).
    const objects = readObjects(p.objects);
    const extent = Number.isInteger(p.extent) && p.extent >= MIN_EXTENT && p.extent <= MAX_EXTENT ? p.extent : GRID_HALF;
    return {
        id,
        name: p.name.slice(0, 64),
        unit: p.unit,
        extent: Math.max(extent, neededExtent({ vertices, parts })),
        mode: p.mode,
        vertices,
        faces,
        ...(facecolors ? { facecolors } : {}),
        // Carried through so the object keeps its own colours when it is edited
        // and republished. An absent one means the built-in, as on the wire.
        ...(Array.isArray(p.palette) ? { palette } : {}),
        // Only a payload that says so stands up; `spin` without `up` is ignored,
        // the way the field is documented.
        up,
        spin: up ? wrapSpin(Number(p.spin ?? 0)) : 0,
        ...(refs && refs.length ? { refs } : {}),
        ...(parts && parts.length ? { parts } : {}),
        // Carried, never read: what a newer version of the format added (§5).
        ...(opacity !== undefined ? { opacity } : {}),
        ...(objects ? { objects } : {}),
        ...(extra ? { extra } : {}),
        updatedAt: Date.now(),
    };
}
/** The flat arrays three.js wants, in one place so every drawer agrees. */
/**
 * A model position as the scene draws it. Model axes are cyberspace axes,
 * and the world draws cyberspace with Z negated (lib/space.ts
 * flipHandedness), so model +Z is render -Z here too: the bench and the
 * world show the same object, and the bench's blue arrow points where the
 * world's compass does.
 */
export function toRender(p) {
    // `p` is a position in total ticks (ticksOf).
    // 0 - z rather than -z: negating a zero gives -0, which equality tests and keys treat as different.
    return [p[0] / TICKS_PER_UNIT, p[1] / TICKS_PER_UNIT, (0 - p[2]) / TICKS_PER_UNIT];
}
/**
 * A vertex through a pose, if there is one: the shard standing where it was
 * placed rather than lying on the axes it was built on (pose.ts). Applied in
 * ticks, before `toRender`, so a pose is a turn of the shape and says nothing
 * about the screen. A client with nowhere to place an object passes none and
 * this is the identity.
 */
export function posed(t, pose) {
    return pose ? applyPose(pose, t) : t;
}
export function flatten(s, pose) {
    const positions = new Float32Array(s.vertices.length * 3);
    const colors = new Float32Array(s.vertices.length * 3);
    s.vertices.forEach((v, i) => {
        positions.set(toRender(posed(ticksOf(v), pose)), i * 3);
        colors.set(v.c, i * 3);
    });
    return { positions, colors, index: s.faces.flat() };
}
/** Where the shard's vertices sit on average: what the workshop orbits. */
export function centroid(s) {
    if (s.vertices.length === 0)
        return [0, 0, 0];
    const sum = [0, 0, 0];
    for (const v of s.vertices) {
        const t = ticksOf(v);
        for (let i = 0; i < 3; i++)
            sum[i] += t[i];
    }
    return sum.map((x) => x / s.vertices.length);
}
/** Hex <-> 0..1 triple, for the color input. */
export function hexToRgb(hex) {
    const n = parseInt(hex.replace('#', ''), 16);
    return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
}
export function rgbToHex(c) {
    return '#' + c.map((v) => Math.round(Math.min(1, Math.max(0, v)) * 255).toString(16).padStart(2, '0')).join('');
}
/** A tick count as units for reading: "2", "1/3", "-2 3/4". */
export function unitsLabel(ticks) {
    const sign = ticks < 0 ? '-' : '';
    const a = Math.abs(ticks);
    const whole = Math.floor(a / TICKS_PER_UNIT);
    let num = a - whole * TICKS_PER_UNIT;
    if (num === 0)
        return `${sign}${whole}`;
    let den = TICKS_PER_UNIT;
    const gcd = (x, y) => (y ? gcd(y, x % y) : x);
    const g = gcd(num, den);
    num /= g;
    den /= g;
    return whole ? `${sign}${whole} ${num}/${den}` : `${sign}${num}/${den}`;
}
