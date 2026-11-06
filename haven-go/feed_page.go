package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"html/template"
	"log/slog"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// NoteDisplay holds template-ready data for rendering a single note on the relay page.
type NoteDisplay struct {
	ID               string
	Pubkey           string
	DisplayName      string
	AvatarURL        string
	FormattedContent template.HTML
	ImageURLs        []string
	VideoURLs        []string
	RelativeTime     string
	CreatedAt        time.Time
}

// FeedPageData holds all data passed to the feed.html template.
type FeedPageData struct {
	RelayName        string
	RelayPubkey      string
	RelayDescription string
	RelayURL         string
	Notes            []NoteDisplay
}

// Compiled regex patterns for content parsing.
var (
	imageURLRegex = regexp.MustCompile(
		`(?i)https?://\S+?\.(?:jpg|jpeg|png|gif|webp|avif)(?:\?\S+)?`,
	)
	videoURLRegex = regexp.MustCompile(
		`(?i)https?://\S+?\.(?:mp4|mov|webm|m4v)(?:\?\S+)?`,
	)
	httpURLRegex = regexp.MustCompile(
		`https?://[^\s<>")\]]*[^\s<>")\].,;:!?'"]`,
	)
)

// Profile cache for resolved kind-0 metadata.
var (
	profileCache     = map[string][2]string{} // pubkey -> [displayName, avatarURL]
	profileCacheLock sync.RWMutex
)

// fetchRecentNotes queries the outbox DB for the latest kind-1 text notes.
func fetchRecentNotes(ctx context.Context, limit int) []NoteDisplay {
	if outboxDB == nil {
		return nil
	}

	queryCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	filter := nostr.Filter{
		Kinds: []int{1},
		Limit: limit,
	}

	ch, err := outboxDB.QueryEvents(queryCtx, filter)
	if err != nil {
		slog.Error("failed to query outbox events for feed page", "error", err)
		return nil
	}

	var notes []NoteDisplay
	brought := broughtAccounts()
	for ev := range ch {
		// The public page never shows a brought-over account (brought_reads.go).
		if _, b := brought[ev.PubKey]; b {
			continue
		}
		notes = append(notes, eventToNoteDisplay(ctx, ev))
	}

	// Sort by created_at descending
	sort.Slice(notes, func(i, j int) bool {
		return notes[i].CreatedAt.After(notes[j].CreatedAt)
	})

	if len(notes) > limit {
		notes = notes[:limit]
	}

	return notes
}

// eventToNoteDisplay converts a nostr.Event to template-ready display data.
func eventToNoteDisplay(ctx context.Context, ev *nostr.Event) NoteDisplay {
	nd := NoteDisplay{
		ID:        ev.ID,
		Pubkey:    ev.PubKey,
		CreatedAt: ev.CreatedAt.Time(),
	}

	// Extract media URLs
	nd.ImageURLs = dedup(imageURLRegex.FindAllString(ev.Content, -1))
	nd.VideoURLs = dedup(videoURLRegex.FindAllString(ev.Content, -1))

	// Format content for HTML display
	nd.FormattedContent = formatNoteContent(ev.Content, nd.ImageURLs, nd.VideoURLs)

	// Relative time
	nd.RelativeTime = relativeTime(ev.CreatedAt.Time())

	// Resolve profile
	nd.DisplayName, nd.AvatarURL = resolveProfile(ctx, ev.PubKey)

	return nd
}

// formatNoteContent strips media URLs, HTML-escapes, linkifies remaining URLs, and converts newlines.
func formatNoteContent(content string, imageURLs, videoURLs []string) template.HTML {
	text := content

	// Strip image and video URLs from text (they render inline below)
	for _, u := range imageURLs {
		text = strings.ReplaceAll(text, u, "")
	}
	for _, u := range videoURLs {
		text = strings.ReplaceAll(text, u, "")
	}

	// Strip nostr: references (not useful on the web page)
	text = regexp.MustCompile(`nostr:[a-z0-9]+`).ReplaceAllString(text, "")

	// Trim excess whitespace
	text = strings.TrimSpace(text)

	// HTML-escape the content
	text = html.EscapeString(text)

	// Linkify remaining HTTP URLs
	text = httpURLRegex.ReplaceAllStringFunc(text, func(u string) string {
		// Display a short label
		display := u
		if len(display) > 60 {
			display = display[:57] + "..."
		}
		return `<a href="` + html.EscapeString(u) + `" target="_blank" rel="noopener noreferrer" class="text-purple-300 hover:text-purple-200 underline decoration-purple-400/30 hover:decoration-purple-300/50 transition-colors break-all">` + html.EscapeString(display) + `</a>`
	})

	// Convert newlines to <br>
	text = strings.ReplaceAll(text, "\n", "<br>")

	return template.HTML(text)
}

// relativeTime returns a human-readable relative time string.
func relativeTime(t time.Time) string {
	diff := time.Since(t)
	switch {
	case diff < time.Minute:
		return "now"
	case diff < time.Hour:
		return fmt.Sprintf("%dm", int(diff.Minutes()))
	case diff < 24*time.Hour:
		return fmt.Sprintf("%dh", int(diff.Hours()))
	case diff < 7*24*time.Hour:
		return fmt.Sprintf("%dd", int(diff.Hours()/24))
	default:
		return t.Format("Jan 2")
	}
}

// resolveProfile looks up a kind-0 profile from the outbox DB for display name and avatar.
func resolveProfile(ctx context.Context, pubkey string) (string, string) {
	profileCacheLock.RLock()
	if cached, ok := profileCache[pubkey]; ok {
		profileCacheLock.RUnlock()
		return cached[0], cached[1]
	}
	profileCacheLock.RUnlock()

	if outboxDB == nil {
		return shortPubkey(pubkey), ""
	}

	queryCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	filter := nostr.Filter{
		Kinds:   []int{0},
		Authors: []string{pubkey},
		Limit:   1,
	}

	ch, err := outboxDB.QueryEvents(queryCtx, filter)
	if err != nil {
		return shortPubkey(pubkey), ""
	}

	for ev := range ch {
		var profile struct {
			Name        string `json:"name"`
			DisplayName string `json:"display_name"`
			Picture     string `json:"picture"`
		}
		if err := json.Unmarshal([]byte(ev.Content), &profile); err == nil {
			name := profile.DisplayName
			if name == "" {
				name = profile.Name
			}
			if name == "" {
				name = shortPubkey(pubkey)
			}

			profileCacheLock.Lock()
			profileCache[pubkey] = [2]string{name, profile.Picture}
			profileCacheLock.Unlock()

			return name, profile.Picture
		}
	}

	// Cache the miss too
	profileCacheLock.Lock()
	profileCache[pubkey] = [2]string{shortPubkey(pubkey), ""}
	profileCacheLock.Unlock()

	return shortPubkey(pubkey), ""
}

func shortPubkey(pk string) string {
	if len(pk) > 12 {
		return pk[:8] + "..."
	}
	return pk
}

func dedup(items []string) []string {
	if len(items) == 0 {
		return nil
	}
	seen := map[string]bool{}
	var result []string
	for _, item := range items {
		if !seen[item] {
			seen[item] = true
			result = append(result, item)
		}
	}
	return result
}
