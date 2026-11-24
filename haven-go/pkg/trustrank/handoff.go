package trustrank

import (
	"encoding/json"
	"errors"
	"os"
)

// The hand-off: the copy of a result file that an owner's own devices get
// from their Haven. Only people the slider can show travel, so the copy is
// a fraction of the whole file. Scores are not changed here.

// HandoffFloor (shown scale): people under it stay on the Haven. Sized on
// Logen's 2026-11-22 map (78,855 rows, 6.0 MB): 28,654 rows are at or over
// 45 (about 2.2 MB), 16,513 at or over the slider's start (55). 45 is the
// bottom of the "thin but real" band (shown.go), so a phone's slider can go
// that far down and no further.
const HandoffFloor = 45.0

// maxHandoffRows bounds a copy a device will take (the 2026-11-22 map has
// 28,654 over the floor).
const maxHandoffRows = 500_000

// ErrBadResult: a result file that is not one, or not the one asked for.
var ErrBadResult = errors.New("trustrank: bad result file")

// ReadResult reads account's result file in dir. A missing file is
// os.ErrNotExist.
func ReadResult(dir, account string) (ResultFile, error) {
	var f ResultFile
	if !validAccount(account) {
		return f, ErrBadResult
	}
	b, err := os.ReadFile(ResultPath(dir, account))
	if err != nil {
		return f, err
	}
	if json.Unmarshal(b, &f) != nil || f.Account != account {
		return f, ErrBadResult
	}
	return f, nil
}

// row reads one [pubkey, shown score, hop] row as JSON hands it back.
func row(r [3]any) (pk string, shown float64, hop int, ok bool) {
	pk, okPk := r[0].(string)
	shown, okS := r[1].(float64)
	h, okH := r[2].(float64)
	if !okPk || !okS || !okH || !validAccount(pk) || h != float64(int(h)) {
		return "", 0, 0, false
	}
	return pk, shown, int(h), true
}

// Handoff is f with only the rows a device gets: the owner's own follows
// (ring 1, always shown) and everyone at or over floor. Floor says what was
// left out. The globe list travels whole. f must have been through JSON
// (ReadResult).
func (f ResultFile) Handoff(floor float64) ResultFile {
	out := f
	out.Floor = floor
	out.People = make([][3]any, 0, len(f.People)/2)
	for _, r := range f.People {
		if _, shown, hop, ok := row(r); ok && (hop == 1 || shown >= floor) {
			out.People = append(out.People, r)
		}
	}
	return out
}

// CheckHandoff: whether raw is a copy of account's result that a device
// may keep. It refuses another account's file, a version this build does
// not read, and any row that is not a hex pubkey with a 0-100 score in
// rings 1 to CeilingHop, and any globe row that is not a hex pubkey with a
// 0-100 score in rings 2 to GlobeHop and a hex via.
func CheckHandoff(raw []byte, account string) (ResultFile, error) {
	var f ResultFile
	if !validAccount(account) || json.Unmarshal(raw, &f) != nil {
		return f, ErrBadResult
	}
	if f.Account != account || f.Version != 2 || f.BuiltAt <= 0 || len(f.People) > maxHandoffRows ||
		f.MaxHop < 1 || f.MaxHop > CeilingHop {
		return f, ErrBadResult
	}
	for _, r := range f.People {
		_, shown, hop, ok := row(r)
		if !ok || shown < 0 || shown > 100 || hop < 1 || hop > f.MaxHop {
			return f, ErrBadResult
		}
	}
	if len(f.Globe) > maxGlobeRows {
		return f, ErrBadResult
	}
	for _, r := range f.Globe {
		_, shown, hop, _, ok := globeRow(r)
		if !ok || shown < 0 || shown > 100 || hop < 2 || hop > GlobeHop || hop > f.MaxHop {
			return f, ErrBadResult
		}
	}
	return f, nil
}

// WriteHandoff keeps a checked copy as account's result file in dir,
// through a temp file and a rename.
func WriteHandoff(dir string, f ResultFile) error {
	if !validAccount(f.Account) {
		return ErrBadResult
	}
	b, err := json.Marshal(f)
	if err != nil {
		return err
	}
	path := ResultPath(dir, f.Account)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
