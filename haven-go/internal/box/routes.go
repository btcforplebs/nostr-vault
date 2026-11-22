package box

import (
	"net/http"
	"strings"
)

// Level is who may use a box API route (One Vault addendum A.3).
type Level int

const (
	// FirstAccount: only the box's first account (box/owner, NV_OWNER), the
	// one that claimed it and runs it: update, move, restart, backup and
	// restore, adding and removing accounts.
	FirstAccount Level = iota
	// SignedIn: any account that has signed in to this box (the first
	// account, or an added one that joined with a code: accounts_auth.go).
	SignedIn
	// Anyone: any valid NIP-98 signer, even a key the box does not hold or
	// holds watch-only. Only for asking "does this box hold me" and for
	// joining with a one-time code (routes_accounts.go); nothing else.
	Anyone
)

// Caller is who asked: the account whose NIP-98 proof the request carried.
// The zero value may use only Anyone routes.
type Caller struct {
	Pubkey   string // hex
	First    bool   // the box's first account
	SignedIn bool   // an added account that has signed in to the box
}

// member: the first account or a signed-in one; the only callers that get
// past the box API's door to anything but Anyone routes.
func (c Caller) member() bool { return c.First || c.SignedIn }

// may: c may use a route of level l.
func (c Caller) may(l Level) bool {
	switch l {
	case Anyone:
		return true
	case SignedIn:
		return c.member()
	default:
		return c.First
	}
}

// routeFunc answers one checked box API route for caller c. body is the
// request body the NIP-98 check already read.
type routeFunc func(a *API, w http.ResponseWriter, r *http.Request, c Caller, body []byte)

type route struct {
	level Level
	serve routeFunc
}

// boxRoutes maps "METHOD /api/box/path" to its level and handler. Each
// routes_*.go file registers its own area's routes from init, so a new area
// is a new file and never an edit to a shared switch.
var boxRoutes = map[string]route{}

func handle(path string, level Level, f routeFunc) {
	if _, dup := boxRoutes[path]; dup {
		panic("box: route registered twice: " + path)
	}
	boxRoutes[path] = route{level: level, serve: f}
}

// callerOf: who signed a request that passed the NIP-98 check: the first
// account, a signed-in added account, or (watch-only or unknown) nobody.
func (a *API) callerOf(pubkey string) Caller {
	pubkey = strings.ToLower(pubkey)
	if pubkey == strings.ToLower(a.Auth.OwnerHex) {
		return Caller{Pubkey: pubkey, First: true}
	}
	if a.Accounts != nil && a.Accounts.StateOf(pubkey) == StateSignedIn {
		return Caller{Pubkey: pubkey, SignedIn: true}
	}
	return Caller{Pubkey: pubkey}
}
