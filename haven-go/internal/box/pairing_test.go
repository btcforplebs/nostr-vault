package box

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The box's pairing against the fixtures iOS, Android and the web read too
// (HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MeshPairing, made
// by reference.py). The box is only ever side A (it shows the code and has
// no camera), so the joiner cases are the apps' alone; every shower case,
// parse, build, owner, role, builder and check-words case runs here.

const pairingFixtures = "../../../HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MeshPairing"

func readFixture(t *testing.T, name string, into any) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(pairingFixtures, name))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, into); err != nil {
		t.Fatal(err)
	}
}

type payloadFixture struct {
	Rule struct {
		NameMax int      `json:"name_max"`
		Roles   []string `json:"roles"`
	} `json:"rule"`
	Parse []struct {
		Name   string `json:"name"`
		URI    string `json:"uri"`
		Own    string `json:"own"`
		Expect struct {
			Refusal string `json:"refusal"`
			Payload *struct {
				Mesh, MeshHex, Name, Role, Owner, OwnerHex string
				Secret, Echo, BSecret                      string
			} `json:"-"`
			Raw json.RawMessage `json:"payload"`
		} `json:"expect"`
	} `json:"parse"`
	Build []struct {
		Name   string `json:"name"`
		Args   struct{ M, N, R, O, S, E, B string }
		Expect string `json:"expect"`
	} `json:"build"`
	Owner []struct {
		Name, Owner, Active, Expect string
		Accounts                    []string
	} `json:"owner"`
	Role []struct {
		Name, Npub, Role, Expect string
		Existing                 []struct{ Npub, Role string }
	} `json:"role"`
	Texts []struct {
		Kind, Role, Name, Npub, Code, Expect string
		Setup                                bool
	} `json:"texts"`
}

func TestPairCodeFixtures(t *testing.T) {
	var fx payloadFixture
	readFixture(t, "payload-cases.json", &fx)
	if fx.Rule.NameMax != PairNameMax || strings.Join(fx.Rule.Roles, ",") != strings.Join(pairRoles, ",") {
		t.Fatalf("rule constants differ from the fixtures: %+v", fx.Rule)
	}
	if len(fx.Parse) < 30 {
		t.Fatalf("only %d parse cases", len(fx.Parse))
	}
	for _, c := range fx.Parse {
		got, refusal := ParsePairCode(c.URI, c.Own)
		if c.Expect.Refusal != "" {
			if refusal != c.Expect.Refusal {
				t.Errorf("parse %q: refusal %q, want %q", c.Name, refusal, c.Expect.Refusal)
			}
			continue
		}
		var e struct {
			Mesh, Name, Role, Owner, Secret, Echo string
			MeshHex                               string `json:"mesh_hex"`
			OwnerHex                              string `json:"owner_hex"`
			BSecret                               string `json:"b_secret"`
		}
		if err := json.Unmarshal(c.Expect.Raw, &e); err != nil {
			t.Fatal(err)
		}
		want := PairCode{Mesh: e.Mesh, MeshHex: e.MeshHex, Name: e.Name, Role: e.Role, Owner: e.Owner, OwnerHex: e.OwnerHex, Secret: e.Secret, Echo: e.Echo, BSecret: e.BSecret}
		if refusal != "" || got != want {
			t.Errorf("parse %q: got %+v (%q), want %+v", c.Name, got, refusal, want)
		}
	}
	for _, c := range fx.Build {
		uri := BuildPairCode(PairCodeArgs{M: c.Args.M, N: c.Args.N, R: c.Args.R, O: c.Args.O, S: c.Args.S, E: c.Args.E, B: c.Args.B})
		if uri != c.Expect {
			t.Errorf("build %q:\n got %s\nwant %s", c.Name, uri, c.Expect)
		}
		if _, refusal := ParsePairCode(uri, ""); refusal != "" {
			t.Errorf("build %q does not read back: %s", c.Name, refusal)
		}
	}
	for _, c := range fx.Owner {
		if got := PairOwnerCheck(c.Owner, c.Active, c.Accounts); got != c.Expect {
			t.Errorf("owner %q: %s, want %s", c.Name, got, c.Expect)
		}
	}
	for _, c := range fx.Role {
		var known []PairKnownDevice
		for _, d := range c.Existing {
			known = append(known, PairKnownDevice{Npub: d.Npub, Role: d.Role})
		}
		if got := PairRoleCheck(c.Npub, c.Role, known); got != c.Expect {
			t.Errorf("role %q: %s, want %s", c.Name, got, c.Expect)
		}
	}
	confirms := 0
	for _, c := range fx.Texts {
		switch c.Kind {
		case "confirm":
			if c.Setup {
				continue // the first-run path is the apps' alone
			}
			confirms++
			if got := PairRoleConfirmText(c.Role, c.Name); got != c.Expect {
				t.Errorf("confirm text %s %q: %q, want %q", c.Role, c.Name, got, c.Expect)
			}
		case "short":
			if got := PairShortAddress(c.Npub); got != c.Expect {
				t.Errorf("short %q: %q, want %q", c.Npub, got, c.Expect)
			}
		}
		// Refusal lines are the UI's words: the box web UI reads them from
		// web mesh-pairing.js, which the web test pins.
	}
	if confirms == 0 {
		t.Fatal("no confirm texts in the fixture")
	}
}

type helloFixture struct {
	Rule struct {
		HelloKind    int `json:"hello_kind"`
		CodeLifetime int `json:"code_lifetime"`
		ScanWindow   int `json:"scan_window"`
		AckWindow    int `json:"ack_window"`
		HelloSkew    int `json:"hello_skew"`
	} `json:"rule"`
	Builders []struct {
		Kind string `json:"kind"`
		Args struct {
			S, N, R, O, D string
			T             int64
			W             bool
		} `json:"args"`
		Expect string `json:"expect"`
	} `json:"builders"`
	Cases []struct {
		Name      string   `json:"name"`
		Side      string   `json:"side"`
		Secret    string   `json:"secret"`
		CreatedAt int64    `json:"created_at"`
		OwnMesh   string   `json:"own_mesh"`
		Active    string   `json:"active"`
		Accounts  []string `json:"accounts"`
		Steps     []struct {
			Op      string `json:"op"`
			Sender  string `json:"sender"`
			Content string `json:"content"`
			URI     string `json:"uri"`
			Now     int64  `json:"now"`
			Expect  string `json:"expect"`
			Ack     string `json:"ack"`
		} `json:"steps"`
	} `json:"cases"`
}

func TestPairingSessionFixtures(t *testing.T) {
	var fx helloFixture
	readFixture(t, "hello-cases.json", &fx)
	if fx.Rule.HelloKind != PairHelloKind || fx.Rule.CodeLifetime != pairCodeLifetime || fx.Rule.ScanWindow != pairScanWindow || fx.Rule.AckWindow != pairAckWindow || fx.Rule.HelloSkew != pairHelloSkew {
		t.Fatalf("timings differ from the fixtures: %+v", fx.Rule)
	}
	for _, b := range fx.Builders {
		var got string
		if b.Kind == "ack" {
			got = PairAckJSON(b.Args.D, b.Args.W)
		} else {
			got = PairHelloJSON(b.Args.S, b.Args.N, b.Args.R, b.Args.O, b.Args.T)
		}
		if got != b.Expect {
			t.Errorf("%s builder:\n got %s\nwant %s", b.Kind, got, b.Expect)
		}
		if b.Kind == "ack" {
			if a := ParsePairAck(got); a == nil || a.D != b.Args.D || a.W != b.Args.W {
				t.Errorf("ack does not read back: %s", got)
			}
		} else if h := ParsePairHello(got); h == nil || h.S != b.Args.S {
			t.Errorf("hello does not read back: %s", got)
		}
	}
	showers := 0
	for _, c := range fx.Cases {
		if c.Side != "shower" {
			continue // the box never scans: B's side is the apps' alone
		}
		showers++
		s := NewPairingSession(c.Secret, c.CreatedAt, c.OwnMesh, c.Active, c.Accounts)
		for i, st := range c.Steps {
			var got string
			switch st.Op {
			case "hello":
				got = s.ReceiveHello(st.Sender, st.Content, st.Now)
			case "qr":
				got = s.AcceptSecondQR(st.URI, st.Now)
			case "accept":
				got = s.AcceptWithoutScan(st.Now)
			default:
				t.Fatalf("%q step %d: unknown op %q", c.Name, i, st.Op)
			}
			if got != st.Expect {
				t.Errorf("%q step %d (%s): %s, want %s", c.Name, i, st.Op, got, st.Expect)
			}
			if st.Ack != "" && s.Ack() != st.Ack {
				t.Errorf("%q step %d ack:\n got %s\nwant %s", c.Name, i, s.Ack(), st.Ack)
			}
		}
	}
	if showers < 25 {
		t.Fatalf("only %d shower cases ran", showers)
	}
}

func TestPairingConfirmCarriesTheDevice(t *testing.T) {
	var fx helloFixture
	readFixture(t, "hello-cases.json", &fx)
	for _, c := range fx.Cases {
		if !strings.HasPrefix(c.Name, "happy path") {
			continue
		}
		s := NewPairingSession(c.Secret, c.CreatedAt, c.OwnMesh, c.Active, c.Accounts)
		s.ReceiveHello(c.Steps[0].Sender, c.Steps[0].Content, c.Steps[0].Now)
		if got := s.AcceptSecondQR(c.Steps[1].URI, c.Steps[1].Now); got != "confirm" {
			t.Fatal(got)
		}
		if npubHex(s.Device.Npub) != c.Steps[0].Sender || s.Device.Name != "Logen's iPhone" || s.Device.Role != "phone" {
			t.Fatalf("device = %+v", s.Device)
		}
		return
	}
	t.Fatal("no happy path case")
}

func TestPairCheckWordsFixtures(t *testing.T) {
	var fx struct {
		Rule struct {
			ListSHA256 string `json:"list_sha256"`
		} `json:"rule"`
		Cases []struct {
			A, B, Secret  string
			Words         []string
			AckDigest     string `json:"ack_digest"`
			BSecret       string `json:"b_secret"`
			AckDigestScan string `json:"ack_digest_scan"`
		} `json:"cases"`
	}
	readFixture(t, "checkwords-cases.json", &fx)
	raw, err := os.ReadFile(filepath.Join(pairingFixtures, "words.txt"))
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(raw)
	if hex.EncodeToString(sum[:]) != fx.Rule.ListSHA256 {
		t.Fatal("words.txt is not the fixture's list")
	}
	words := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	if len(words) != 2048 {
		t.Fatalf("%d words", len(words))
	}
	if len(fx.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range fx.Cases {
		idx := PairCheckWordIndexes(c.A, c.B, c.Secret)
		got := make([]string, 0, 4)
		for _, i := range idx {
			got = append(got, words[i])
		}
		if strings.Join(got, " ") != strings.Join(c.Words, " ") {
			t.Errorf("words for %s: %v, want %v", c.Secret, got, c.Words)
		}
		if d := PairAckDigest(c.Secret, c.A, c.B, ""); d != c.AckDigest {
			t.Errorf("words digest %s, want %s", d, c.AckDigest)
		}
		if d := PairAckDigest(c.Secret, c.A, c.B, c.BSecret); d != c.AckDigestScan {
			t.Errorf("scan digest %s, want %s", d, c.AckDigestScan)
		}
	}
	// Bad input gives nothing, never a digest of nothing.
	if PairAckDigest("short", fx.Cases[0].A, fx.Cases[0].B, "") != "" || PairCheckWordIndexes("zz", fx.Cases[0].B, fx.Cases[0].Secret) != nil {
		t.Fatal("bad input was digested")
	}
}

func TestNewPairSecretIsFreshAndCanonical(t *testing.T) {
	a, b := newPairSecret(), newPairSecret()
	if a == b || len(a) != 22 || secretBytes(a) == nil {
		t.Fatalf("%q %q", a, b)
	}
	if base64url(secretBytes(a)) != a {
		t.Fatal("secret does not round-trip")
	}
}
