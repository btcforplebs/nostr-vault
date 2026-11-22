//go:build !(js && wasm)

package main

// "Copy all my files to my servers" as an engine job (One Vault spec E6). The
// Mac and the phones do it in app code (MediaServersModel.copyToServers,
// BlossomServiceMirroring.kt); a box has no app, so the engine does it.
//
// It runs in two steps, as on the Mac:
//
//  1. check: ask each server in the account's kind 10063 whether it has each
//     of the account's files here (HEAD /<sha256>, no auth needed).
//  2. copy: send the missing ones. A box holds no account key, so it cannot
//     sign the upload auth (kind 24242) the servers want. The account signs
//     it in the browser, one auth per batch of up to 25 files, each naming
//     its files in x tags, as the Mac does (filesPerSignature); the box only
//     carries it. An auth can therefore only ever put the files it names on
//     the servers this account lists, and only until it expires.
//
// The box (internal/box/routes_media.go) writes media-copy-request.json in
// the vault folder; the engine takes it, runs it and writes
// media-copy-state.json. One job at a time; a new request replaces a waiting
// one.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

const (
	mediaCopyRequestFile = "media-copy-request.json"
	mediaCopyStateFile   = "media-copy-state.json"

	// mediaCopyFilesPerAuth: the most files one auth may name (the Mac signs 25).
	mediaCopyFilesPerAuth = 25
	// mediaCopyMaxAuths: auths one request may carry.
	mediaCopyMaxAuths = 400
	// mediaCopyAuthAhead: an auth may not live longer than this from now.
	mediaCopyAuthAhead = 2 * time.Hour
	// mediaCopyParallel: files sent at once (the Mac sends two).
	mediaCopyParallel = 2
	// mediaCheckParallel: presence questions at once.
	mediaCheckParallel = 8
)

// mediaCopyRequest is what the box writes. Pubkey is who asked (hex): the box
// sets it from the caller, never from the request body.
type mediaCopyRequest struct {
	ID     string   `json:"id"`
	Action string   `json:"action"` // "check" or "copy"
	Pubkey string   `json:"pubkey"`
	Auths  []string `json:"auths,omitempty"` // signed kind 24242, JSON or base64 of it
}

// mediaCopyFile is one file some server lacks, and what happened to it.
type mediaCopyFile struct {
	SHA256  string            `json:"sha256"`
	Absent  []string          `json:"absent"`            // servers that said they do not have it
	Status  string            `json:"status"`            // waiting, copied, failed
	Reasons map[string]string `json:"reasons,omitempty"` // server -> why it failed
}

// mediaCopyState is what the engine writes.
type mediaCopyState struct {
	ID        string          `json:"id"`
	Pubkey    string          `json:"pubkey"`
	Action    string          `json:"action"`
	Running   bool            `json:"running"`
	Started   int64           `json:"started"`
	Finished  int64           `json:"finished,omitempty"`
	Servers   []string        `json:"servers"`
	Checked   int             `json:"checked"` // own files asked about
	Files     []mediaCopyFile `json:"files"`   // only files some server lacks
	Copied    int             `json:"copied"`
	Failed    int             `json:"failed"`
	Error     string          `json:"error,omitempty"`
	CheckedAt int64           `json:"checked_at,omitempty"`
}

// mediaCopyDeps is what a job reaches outside itself; tests fake it.
type mediaCopyDeps struct {
	client   *http.Client
	accounts func() []string
	servers  func(ctx context.Context, pubkey string) []string
	ownFiles func(ctx context.Context, pubkey string) (map[string]string, error) // sha -> content type, stored here
	upload   func(ctx context.Context, f *blobForward) (done bool, err error)
	now      func() time.Time
	save     func(mediaCopyState)
}

// ── Auth check (pure) ──────────────────────────────────────────────────

// parseUploadAuth reads one auth the browser signed: a kind 24242 upload
// auth by pubkey, still valid, not longer than mediaCopyAuthAhead, naming
// 1..25 files. Returns the event, the hashes it names and the base64 the
// servers expect.
func parseUploadAuth(raw, pubkey string, now time.Time) (*nostr.Event, []string, string, error) {
	raw = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(raw), "Nostr "))
	js := []byte(raw)
	if !strings.HasPrefix(raw, "{") {
		dec, err := base64.StdEncoding.DecodeString(raw)
		if err != nil {
			if dec, err = base64.RawURLEncoding.DecodeString(raw); err != nil {
				return nil, nil, "", errors.New("auth is neither JSON nor base64")
			}
		}
		js = dec
	}
	var ev nostr.Event
	if err := json.Unmarshal(js, &ev); err != nil {
		return nil, nil, "", errors.New("auth is not an event")
	}
	if ev.Kind != 24242 {
		return nil, nil, "", errors.New("auth is not kind 24242")
	}
	if ev.PubKey != pubkey {
		return nil, nil, "", errors.New("auth is signed by another account")
	}
	if ok, err := ev.CheckSignature(); err != nil || !ok {
		return nil, nil, "", errors.New("auth signature is not valid")
	}
	if t := ev.Tags.GetFirst([]string{"t", ""}); t == nil || (*t)[1] != "upload" {
		return nil, nil, "", errors.New("auth is not for upload")
	}
	exp := ev.Tags.GetFirst([]string{"expiration", ""})
	if exp == nil {
		return nil, nil, "", errors.New("auth has no expiration")
	}
	secs, err := strconv.ParseInt((*exp)[1], 10, 64)
	if err != nil || secs <= now.Unix() {
		return nil, nil, "", errors.New("auth has expired")
	}
	if time.Unix(secs, 0).After(now.Add(mediaCopyAuthAhead)) {
		return nil, nil, "", errors.New("auth lasts too long")
	}
	var xs []string
	for _, tag := range ev.Tags {
		if len(tag) >= 2 && tag[0] == "x" {
			if !isBlobHash(tag[1]) {
				return nil, nil, "", errors.New("auth names a bad hash")
			}
			if !slices.Contains(xs, tag[1]) {
				xs = append(xs, tag[1])
			}
		}
	}
	if len(xs) == 0 || len(xs) > mediaCopyFilesPerAuth {
		return nil, nil, "", fmt.Errorf("auth must name 1 to %d files", mediaCopyFilesPerAuth)
	}
	b, _ := json.Marshal(ev)
	return &ev, xs, base64.StdEncoding.EncodeToString(b), nil
}

// ── The job ────────────────────────────────────────────────────────────

// headPresence asks one server about one file: true/false, or an error when
// the answer says neither.
func headPresence(ctx context.Context, c *http.Client, server, sha string) (bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, server+"/"+sha, nil)
	if err != nil {
		return false, err
	}
	resp, err := c.Do(req)
	if err != nil {
		return false, err
	}
	resp.Body.Close()
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return true, nil
	case resp.StatusCode == http.StatusNotFound:
		return false, nil
	default:
		return false, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
}

// runMediaCopy runs one request. prev is the last state (a copy uses the
// check it holds for the same account).
func runMediaCopy(ctx context.Context, d mediaCopyDeps, req mediaCopyRequest, prev mediaCopyState) mediaCopyState {
	st := mediaCopyState{ID: req.ID, Pubkey: req.Pubkey, Action: req.Action, Running: true, Started: d.now().Unix()}
	finish := func(errMsg string) mediaCopyState {
		st.Running = false
		st.Finished = d.now().Unix()
		st.Error = errMsg
		d.save(st)
		return st
	}
	if !slices.Contains(d.accounts(), req.Pubkey) {
		return finish("this account is not signed in to this vault")
	}
	st.Servers = d.servers(ctx, req.Pubkey)
	if len(st.Servers) == 0 {
		return finish("no media servers in this account's server list")
	}
	own, err := d.ownFiles(ctx, req.Pubkey)
	if err != nil {
		return finish("could not read this vault's files")
	}
	d.save(st)

	switch req.Action {
	case "check":
		st.Files = checkPresence(ctx, d, st.Servers, own)
		st.Checked = len(own)
		st.CheckedAt = d.now().Unix()
		return finish("")
	case "copy":
		// The last check for this account, kept to what is still true: a
		// server dropped from the list or a file no longer here is left out.
		absent := map[string][]string{}
		if prev.Pubkey == req.Pubkey {
			for _, f := range prev.Files {
				if _, ok := own[f.SHA256]; !ok || f.Status == "copied" {
					continue
				}
				for _, s := range f.Absent {
					if slices.Contains(st.Servers, s) {
						absent[f.SHA256] = append(absent[f.SHA256], s)
					}
				}
			}
			st.Checked, st.CheckedAt = prev.Checked, prev.CheckedAt
		}
		st.Files = copyWithAuths(ctx, d, req, st.Servers, own, absent, &st)
		for _, f := range st.Files {
			switch f.Status {
			case "copied":
				st.Copied++
			case "failed":
				st.Failed++
			}
		}
		return finish(st.Error)
	default:
		return finish("unknown action")
	}
}

// checkPresence: the own files some server lacks, sorted by hash.
func checkPresence(ctx context.Context, d mediaCopyDeps, servers []string, own map[string]string) []mediaCopyFile {
	var mu sync.Mutex
	absent := map[string][]string{}
	sem := make(chan struct{}, mediaCheckParallel)
	var wg sync.WaitGroup
	for sha := range own {
		for _, s := range servers {
			if ctx.Err() != nil {
				break
			}
			sem <- struct{}{}
			wg.Add(1)
			go func(sha, s string) {
				defer func() { <-sem; wg.Done() }()
				has, err := headPresence(ctx, d.client, s, sha)
				if err == nil && !has {
					mu.Lock()
					absent[sha] = append(absent[sha], s)
					mu.Unlock()
				}
			}(sha, s)
		}
	}
	wg.Wait()
	out := make([]mediaCopyFile, 0, len(absent))
	for sha, ss := range absent {
		slices.Sort(ss)
		out = append(out, mediaCopyFile{SHA256: sha, Absent: ss, Status: "waiting"})
	}
	slices.SortFunc(out, func(a, b mediaCopyFile) int { return strings.Compare(a.SHA256, b.SHA256) })
	return out
}

// copyWithAuths sends each file an auth names to the servers that lack it.
// A file with no check yet is asked about first. Files not named by any
// valid auth stay waiting.
func copyWithAuths(ctx context.Context, d mediaCopyDeps, req mediaCopyRequest, servers []string, own map[string]string,
	absent map[string][]string, st *mediaCopyState) []mediaCopyFile {
	type work struct {
		sha     string
		authB64 string
		expires time.Time
	}
	var jobs []work
	named := map[string]bool{}
	var authErr string
	for _, raw := range req.Auths {
		ev, xs, b64, err := parseUploadAuth(raw, req.Pubkey, d.now())
		if err != nil {
			authErr = err.Error()
			continue
		}
		secs, _ := strconv.ParseInt((*ev.Tags.GetFirst([]string{"expiration", ""}))[1], 10, 64)
		for _, x := range xs {
			if _, ok := own[x]; !ok || named[x] {
				continue
			}
			named[x] = true
			jobs = append(jobs, work{sha: x, authB64: b64, expires: time.Unix(secs, 0)})
		}
	}
	files := map[string]*mediaCopyFile{}
	for sha, ss := range absent {
		files[sha] = &mediaCopyFile{SHA256: sha, Absent: ss, Status: "waiting"}
	}
	// Files an auth names that the last check did not cover: ask now.
	for _, j := range jobs {
		if _, ok := files[j.sha]; ok {
			continue
		}
		var ss []string
		for _, s := range servers {
			if has, err := headPresence(ctx, d.client, s, j.sha); err == nil && !has {
				ss = append(ss, s)
			}
		}
		if len(ss) > 0 {
			files[j.sha] = &mediaCopyFile{SHA256: j.sha, Absent: ss, Status: "waiting"}
		}
	}

	var mu sync.Mutex
	sem := make(chan struct{}, mediaCopyParallel)
	var wg sync.WaitGroup
	for _, j := range jobs {
		f := files[j.sha]
		if f == nil || ctx.Err() != nil {
			continue
		}
		sem <- struct{}{}
		wg.Add(1)
		go func(j work, f *mediaCopyFile) {
			defer func() { <-sem; wg.Done() }()
			reasons := map[string]string{}
			for _, s := range f.Absent {
				if d.now().After(j.expires) {
					reasons[s] = "the signature expired before this file was sent"
					continue
				}
				done, err := d.upload(ctx, &blobForward{target: s, sha256: j.sha, authB64: j.authB64,
					contentType: own[j.sha], expiresAt: j.expires})
				if err != nil || !done {
					if err == nil {
						err = errors.New("no answer")
					}
					reasons[s] = err.Error()
				}
			}
			mu.Lock()
			if len(reasons) == 0 {
				f.Status = "copied"
			} else {
				f.Status, f.Reasons = "failed", reasons
			}
			mu.Unlock()
		}(j, f)
	}
	wg.Wait()

	out := make([]mediaCopyFile, 0, len(files))
	for _, f := range files {
		out = append(out, *f)
	}
	slices.SortFunc(out, func(a, b mediaCopyFile) int { return strings.Compare(a.SHA256, b.SHA256) })
	if authErr != "" && len(jobs) == 0 {
		st.Error = "no usable signature: " + authErr
	}
	return out
}

// ── Wiring to the live engine ──────────────────────────────────────────

// accountOwnFiles: the files stored here that pubkey uploaded, with their type.
func accountOwnFiles(ctx context.Context, pubkey string) (map[string]string, error) {
	uploader, records, err := copyOwnBlobRecords(ctx, map[string]bool{pubkey: true})
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for sha := range uploader {
		if !blobStoredHere(sha) {
			continue
		}
		ct := ""
		if t := records[sha].Tags.GetFirst([]string{"type", ""}); t != nil {
			ct = (*t)[1]
		}
		out[sha] = ct
	}
	return out, nil
}

func liveMediaCopyDeps() mediaCopyDeps {
	return mediaCopyDeps{
		client:   mediaJobsClient,
		accounts: ownSigningAccounts,
		servers:  accountServers,
		ownFiles: accountOwnFiles,
		upload:   forwardOnce,
		now:      time.Now,
		save:     func(st mediaCopyState) { writeJSONFile(mediaCopyStateFile, st) },
	}
}

// takeMediaCopyRequest moves the waiting request aside and reads it.
func takeMediaCopyRequest() (mediaCopyRequest, bool) {
	var req mediaCopyRequest
	taken := mediaCopyRequestFile + ".taken"
	if err := os.Rename(mediaCopyRequestFile, taken); err != nil {
		return req, false
	}
	defer os.Remove(taken)
	if !readJSONFile(taken, &req) || !isLowerHex64(req.Pubkey) || len(req.Auths) > mediaCopyMaxAuths {
		slog.Warn("media copy: unreadable request dropped")
		return req, false
	}
	return req, true
}

// mediaCopyPollEvery: how often a waiting request is looked for.
var mediaCopyPollEvery = 2 * time.Second

func runMediaCopyLoop(ctx context.Context) {
	// A job cut short by a restart: say so instead of "running" forever.
	var prev mediaCopyState
	if readJSONFile(mediaCopyStateFile, &prev) && prev.Running {
		prev.Running = false
		prev.Error = "stopped: the vault restarted"
		writeJSONFile(mediaCopyStateFile, prev)
	}
	t := time.NewTicker(mediaCopyPollEvery)
	defer t.Stop()
	for {
		if req, ok := takeMediaCopyRequest(); ok {
			var last mediaCopyState
			readJSONFile(mediaCopyStateFile, &last)
			st := runMediaCopy(ctx, liveMediaCopyDeps(), req, last)
			slog.Info("media copy: done", "action", st.Action, "missing", len(st.Files), "copied", st.Copied, "failed", st.Failed, "err", st.Error)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// startMediaJobs starts Auto-Mirror and Copy to servers. They only do
// anything on a box, which is the only thing that writes their request files.
func startMediaJobs(ctx context.Context, goFn func(string, func())) {
	goFn("autoMirror", func() { runAutoMirrorLoop(ctx) })
	goFn("mediaCopy", func() { runMediaCopyLoop(ctx) })
}
