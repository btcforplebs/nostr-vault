package main

import (
	"context"
	"log/slog"
	"net"
	"net/url"
	"strings"

	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
)

// A delete token (kind 24242, t=delete) is sent to every server that may hold
// the file, public mirrors included. Before the apps named the server in it,
// a mirror that kept one could replay it here and delete the file from the
// home vault too. Now each token names the one server it is for (BUD-11
// "server" tag), and the vault refuses a token that names only other servers.
//
// A token with no "server" tag is still accepted: Android and other Blossom
// apps do not send one yet, and refusing them would break their deletes.
// Flip deleteNeedsServerTag once Android signs with the tag.
var deleteNeedsServerTag = false

// guardDeleteServer adds the server check to bs's deletes.
func guardDeleteServer(bs *blossom.BlossomServer) {
	bs.RejectDelete = append(bs.RejectDelete, rejectDeleteForOtherServer)
}

func rejectDeleteForOtherServer(_ context.Context, auth *nostr.Event, sha256 string, _ string) (bool, string, int) {
	if auth == nil {
		return true, "missing \"Authorization\" event", 401
	}
	named := false
	for _, tag := range auth.Tags {
		if len(tag) < 2 || tag[0] != "server" {
			continue
		}
		named = true
		if isOwnBlossomServer(tag[1]) {
			return false, "", 0
		}
	}
	if !named {
		if deleteNeedsServerTag {
			return true, "delete token must name this server (\"server\" tag)", 403
		}
		slog.Debug("blossom delete: token names no server", "sha256", sha256)
		return false, "", 0
	}
	slog.Warn("blossom delete: refused a token made for another server", "sha256", sha256, "pubkey", auth.PubKey)
	return true, "delete token is for another server", 403
}

// isOwnBlossomServer reports whether a "server" tag value names this vault:
// its public domain (config.RelayURL, e.g. the Mac relay's tunnel), a
// loopback name (the app on this device), or a FIPS mesh name. Only the
// owner's apps send a token naming a .fips address, and only to their own
// vault over the mesh, so no public mirror ever holds one.
func isOwnBlossomServer(value string) bool {
	host := serverTagHost(value)
	if host == "" {
		return false
	}
	if own := serverTagHost(config.RelayURL); own != "" && host == own {
		return true
	}
	if host == "localhost" || strings.HasSuffix(host, ".fips") {
		return true
	}
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		return true
	}
	return false
}

// serverTagHost is the lowercase host of a "server" tag value or a configured
// address, however written: "blossom.example", "blossom.example:443",
// "https://blossom.example/", "[::1]:3355".
func serverTagHost(value string) string {
	v := strings.ToLower(strings.TrimSpace(value))
	if v == "" {
		return ""
	}
	if !strings.Contains(v, "://") {
		v = "https://" + v
	}
	u, err := url.Parse(v)
	if err != nil {
		return ""
	}
	return strings.TrimSuffix(u.Hostname(), ".")
}
