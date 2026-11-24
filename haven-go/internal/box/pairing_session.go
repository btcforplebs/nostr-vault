package box

// PairingSession is side A of docs/MESH_PAIRING_CONTRACT.md §4: the device
// that showed its code first. On the box that is always havend: the box
// web UI shows the code, a phone scans it and sends the hello, and the box,
// which has no camera, finishes with the check words (§5, Tron N4). Pure:
// the caller has already checked the kind-21195 event's signature and
// decrypted it (pairing_dial.go). Outcomes are the contract's strings:
// "camera", "ignoreDuplicate", "abort", "expired", "ignore:<why>",
// "refuse:<why>", "confirm", "reject:<why>".
type PairingSession struct {
	Secret    string
	CreatedAt int64  // when the code was shown (unix s)
	OwnMesh   string // this device's mesh pubkey, hex
	Active    string // the active account, npub
	Accounts  []string

	state   string // waiting, camera, done, expired, aborted
	sender  string // hex, after the first good hello
	hello   *PairHello
	helloAt int64
	bSecret string // s_B from B's scanned code; "" after Accept
	Device  *PairDevice
}

// PairDevice is the device to confirm and store after "confirm".
type PairDevice struct {
	Npub string `json:"npub"`
	Name string `json:"name"`
	Role string `json:"role"`
}

// NewPairingSession starts A's session for a freshly shown code.
func NewPairingSession(secret string, createdAt int64, ownMeshHex, active string, accounts []string) *PairingSession {
	return &PairingSession{Secret: secret, CreatedAt: createdAt, OwnMesh: ownMeshHex, Active: active, Accounts: accounts, state: "waiting"}
}

// State is the session's state word.
func (s *PairingSession) State() string { return s.state }

// Sender is the hello's sender (hex), "" before one.
func (s *PairingSession) Sender() string { return s.sender }

// Ack is the content to send B once confirmed: the scan digest (s_B) when
// B's code was read, else the words digest with `w`. "" before "confirm".
func (s *PairingSession) Ack() string {
	if s.state != "done" {
		return ""
	}
	if s.bSecret != "" {
		return PairAckJSON(PairAckDigest(s.Secret, s.OwnMesh, s.sender, s.bSecret), false)
	}
	return PairAckJSON(PairAckDigest(s.Secret, s.OwnMesh, s.sender, ""), true)
}

// ReceiveHello handles one decrypted hello from sender (hex) at now.
func (s *PairingSession) ReceiveHello(sender, content string, now int64) string {
	switch s.state {
	case "done", "expired":
		return "expired"
	case "aborted":
		return "abort"
	}
	h := ParsePairHello(content)
	if h == nil {
		return "ignore:notHello"
	}
	if sender == s.OwnMesh {
		return "ignore:ownAddress"
	}
	if h.S != s.Secret {
		return "ignore:wrongSecret"
	}
	if d := now - h.T; d > pairHelloSkew || d < -pairHelloSkew {
		return "ignore:stale"
	}
	if oc := PairOwnerCheck(h.O, s.Active, s.Accounts); oc != "ok" {
		why, _, _ := cutColon(oc)
		return "refuse:" + why
	}
	if s.state == "waiting" {
		if now-s.CreatedAt > pairCodeLifetime {
			s.state = "expired"
			return "expired"
		}
		s.state, s.sender, s.hello, s.helloAt = "camera", sender, h, now
		return "camera"
	}
	if sender == s.sender && *h == *s.hello {
		return "ignoreDuplicate"
	}
	s.state = "aborted"
	return "abort"
}

// AcceptSecondQR is B's code read by A's camera. The box has no camera, so
// this exists to prove the port on the shared fixtures; the Mac and the
// phones use it.
func (s *PairingSession) AcceptSecondQR(uri string, now int64) string {
	if stop := s.guard(now); stop != "" {
		return stop
	}
	p, refusal := ParsePairCode(uri, mustNpub(s.OwnMesh))
	if refusal != "" {
		return "refuse:" + refusal
	}
	if p.Secret != "" {
		return "reject:notTheirCode"
	}
	if p.Echo != s.Secret {
		return "reject:echoMismatch"
	}
	if p.MeshHex != s.sender || p.Role != s.hello.R {
		return "reject:notTheDevice"
	}
	s.bSecret = p.BSecret
	return s.finish()
}

// AcceptWithoutScan is Accept with the check words (§5), the box's only path.
func (s *PairingSession) AcceptWithoutScan(now int64) string {
	if stop := s.guard(now); stop != "" {
		return stop
	}
	return s.finish()
}

func (s *PairingSession) guard(now int64) string {
	switch s.state {
	case "aborted":
		return "abort"
	case "done", "expired":
		return "expired"
	case "waiting":
		return "reject:notReady"
	}
	if now-s.helloAt > pairScanWindow {
		s.state = "expired"
		return "expired"
	}
	return ""
}

func (s *PairingSession) finish() string {
	s.state = "done"
	s.Device = &PairDevice{Npub: mustNpub(s.sender), Name: s.hello.N, Role: s.hello.R}
	return "confirm"
}

func cutColon(s string) (string, string, bool) {
	for i := 0; i < len(s); i++ {
		if s[i] == ':' {
			return s[:i], s[i+1:], true
		}
	}
	return s, "", false
}
