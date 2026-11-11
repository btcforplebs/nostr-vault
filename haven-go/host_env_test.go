package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// A host setting must land in Go's map and nowhere else: os.Setenv would
// also run libc setenv(3), the unlocked environ realloc that crashed Android
// cold launch inside getenv on an OkHttp DNS thread.
func TestSetHostEnvNeverTouchesProcessEnv(t *testing.T) {
	const key = "HAVEN_TEST_HOST_ENV_ONLY"
	os.Unsetenv(key)
	t.Cleanup(func() { forgetHostEnv(key) })

	setHostEnv(key, "from-host")

	if v, ok := os.LookupEnv(key); ok {
		t.Fatalf("process environment got %s=%q; host settings must not reach setenv(3)", key, v)
	}
	if got := hostGetenv(key); got != "from-host" {
		t.Fatalf("hostGetenv(%s) = %q, want from-host", key, got)
	}
}

func TestLookupHostEnvPrecedence(t *testing.T) {
	const key = "HAVEN_TEST_HOST_ENV_PRECEDENCE"
	t.Setenv(key, "from-process")
	t.Cleanup(func() { forgetHostEnv(key) })

	if v, ok := lookupHostEnv(key); !ok || v != "from-process" {
		t.Fatalf("unset in host: got %q,%v, want the process value", v, ok)
	}
	setHostEnv(key, "")
	if v, ok := lookupHostEnv(key); !ok || v != "" {
		t.Fatalf("host set to empty: got %q,%v, want \"\",true (empty is set, as with os.Setenv)", v, ok)
	}
	setHostEnv(key, "from-host")
	if v := hostGetenv(key); v != "from-host" {
		t.Fatalf("host value must win, got %q", v)
	}
	if v, ok := lookupHostEnv("HAVEN_TEST_HOST_ENV_NEVER_SET"); ok || v != "" {
		t.Fatalf("missing key: got %q,%v", v, ok)
	}
}

// .env lands in Go's map, not the process environment (godotenv.Load did
// os.Setenv per key), and keeps Load's order: host, then process, then file.
func TestDotEnvNeverTouchesProcessEnv(t *testing.T) {
	const fileOnly, inBoth, inHost = "HAVEN_TEST_DOTENV_ONLY", "HAVEN_TEST_DOTENV_BOTH", "HAVEN_TEST_DOTENV_HOST"
	os.Unsetenv(fileOnly)
	t.Setenv(inBoth, "from-process")
	setHostEnv(inHost, "from-host")
	path := filepath.Join(t.TempDir(), ".env")
	body := fileOnly + "=from-file\n" + inBoth + "=from-file\n" + inHost + "=from-file\n"
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { forgetHostEnv(inHost); loadDotEnv(filepath.Join(t.TempDir(), "absent")) })

	loadDotEnv(path)

	if v, ok := os.LookupEnv(fileOnly); ok {
		t.Fatalf("process environment got %s=%q; .env must not reach setenv(3)", fileOnly, v)
	}
	for key, want := range map[string]string{fileOnly: "from-file", inBoth: "from-process", inHost: "from-host"} {
		if got := hostGetenv(key); got != want {
			t.Errorf("hostGetenv(%s) = %q, want %q", key, got, want)
		}
	}
	loadDotEnv(filepath.Join(t.TempDir(), "absent"))
	if v, ok := lookupHostEnv(fileOnly); ok {
		t.Fatalf("missing .env must clear old file values, got %q", v)
	}
}

// The app writes ~90 keys from one thread while relay goroutines read them.
// Run with -race.
func TestHostEnvConcurrentWritesAndReads(t *testing.T) {
	keys := make([]string, 32)
	for i := range keys {
		keys[i] = "HAVEN_TEST_HOST_ENV_RACE_" + strconv.Itoa(i)
	}
	t.Cleanup(func() { forgetHostEnv(keys...) })

	var wg sync.WaitGroup
	for w := 0; w < 4; w++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			for n := 0; n < 500; n++ {
				setHostEnv(keys[n%len(keys)], strconv.Itoa(n))
			}
		}()
		go func() {
			defer wg.Done()
			for n := 0; n < 500; n++ {
				_, _ = lookupHostEnv(keys[n%len(keys)])
			}
		}()
	}
	wg.Wait()
	for _, k := range keys {
		if _, ok := lookupHostEnv(k); !ok {
			t.Fatalf("%s lost", k)
		}
	}
}

// Guards the call site, not just the helper: SetHavenEnvC (cshared.go, which
// tests cannot call — it takes *C.char) must store through setHostEnv, and no
// relay file may write or read the process environment directly. Allowed:
// host_env.go itself and wasm_entry.go's os.Setenv (no libc, no threads).
func TestNoDirectProcessEnvInRelay(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	sawSetHavenEnvC := false
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") || name == "host_env.go" {
			continue
		}
		f, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(f, func(n ast.Node) bool {
			if fn, ok := n.(*ast.FuncDecl); ok && fn.Name.Name == "SetHavenEnvC" {
				sawSetHavenEnvC = true
				if !callsIdent(fn.Body, "setHostEnv") {
					t.Errorf("%s: SetHavenEnvC must store through setHostEnv", fset.Position(fn.Pos()))
				}
			}
			sel, ok := n.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			pkg, ok := sel.X.(*ast.Ident)
			if ok && pkg.Name == "godotenv" && (sel.Sel.Name == "Load" || sel.Sel.Name == "Overload") {
				t.Errorf("%s: godotenv.%s calls os.Setenv for every key (libc setenv(3)); use loadDotEnv", fset.Position(sel.Pos()), sel.Sel.Name)
				return true
			}
			if !ok || (pkg.Name != "os" && pkg.Name != "syscall") {
				return true
			}
			switch sel.Sel.Name {
			case "Setenv":
				if name != "wasm_entry.go" || pkg.Name != "os" {
					t.Errorf("%s: %s.Setenv reaches libc setenv(3); use setHostEnv", fset.Position(sel.Pos()), pkg.Name)
				}
			case "Getenv", "LookupEnv", "Unsetenv", "Clearenv":
				t.Errorf("%s: %s.%s skips host settings; use hostGetenv/lookupHostEnv", fset.Position(sel.Pos()), pkg.Name, sel.Sel.Name)
			}
			return true
		})
	}
	if !sawSetHavenEnvC {
		t.Fatal("SetHavenEnvC not found; the guard would pass vacuously")
	}
}

// The relay package is not the only Go linked into the app: internal/, pkg/,
// idbstore/ and the vendored third_party/ (go-nostr, khatru, ristretto) run on
// the same threads. None of them may write the process environment either.
// Reads stay allowed there: os.Getenv reads Go's own copy, never libc.
func TestNoProcessEnvWritesInLinkedPackages(t *testing.T) {
	fset := token.NewFileSet()
	scanned := 0
	err := filepath.WalkDir(".", func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if path == "cmd" || path == "templates" || path == "docs" {
				return filepath.SkipDir // standalone binaries, no Go
			}
			return nil
		}
		if filepath.Dir(path) == "." || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return err
		}
		scanned++
		ast.Inspect(f, func(n ast.Node) bool {
			sel, ok := n.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			if pkg, ok := sel.X.(*ast.Ident); ok && (pkg.Name == "os" || pkg.Name == "syscall") {
				switch sel.Sel.Name {
				case "Setenv", "Unsetenv", "Clearenv":
					t.Errorf("%s: %s.%s reaches libc setenv(3) while other threads read environ", fset.Position(sel.Pos()), pkg.Name, sel.Sel.Name)
				}
			}
			return true
		})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if scanned < 100 {
		t.Fatalf("scanned only %d files outside the relay package; the guard would pass vacuously", scanned)
	}
}

func callsIdent(body *ast.BlockStmt, name string) bool {
	found := false
	ast.Inspect(body, func(n ast.Node) bool {
		if c, ok := n.(*ast.CallExpr); ok {
			if id, ok := c.Fun.(*ast.Ident); ok && id.Name == name {
				found = true
			}
		}
		return !found
	})
	return found
}

func forgetHostEnv(keys ...string) {
	hostEnv.Lock()
	for _, k := range keys {
		delete(hostEnv.m, k)
	}
	hostEnv.Unlock()
}
