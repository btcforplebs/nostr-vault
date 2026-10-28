package main

import (
	"testing"

	"github.com/spf13/afero"
)

// Every extension a client can hand the Blossom server must come back as a
// media Content-Type, never application/octet-stream — AVFoundation and the
// gallery classify by MIME, and the iOS/Android sandboxes have no OS
// mime.types file for Go to fall back on.
func TestBlossomContentTypeByExtension(t *testing.T) {
	prev, prevFs := config, fs
	t.Cleanup(func() { config, fs = prev, prevFs })
	fs = afero.NewMemMapFs()
	config.BlossomPath = "/blossom/"

	cases := map[string]string{
		"mp4": "video/mp4", "MP4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime",
		"MOV": "video/quicktime", "webm": "video/webm",
		"mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav",
		"gif": "image/gif", "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
		"webp": "image/webp", "avif": "image/avif",
	}
	for ext, want := range cases {
		if got := blossomContentType("0000", ext); got != want {
			t.Errorf("ext %q: got %q want %q", ext, got, want)
		}
	}
}

// Extensionless blobs (the common Blossom case) are sniffed from the ISO-BMFF
// ftyp box; anything else stays empty so the caller keeps the stored MIME.
func TestBlossomContentTypeSniff(t *testing.T) {
	prev, prevFs := config, fs
	t.Cleanup(func() { config, fs = prev, prevFs })
	fs = afero.NewMemMapFs()
	config.BlossomPath = "/blossom/"

	write := func(name string, body []byte) {
		if err := afero.WriteFile(fs, config.BlossomPath+name, body, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	ftyp := func(brand string) []byte {
		b := []byte{0, 0, 0, 0x18, 'f', 't', 'y', 'p'}
		return append(append(b, []byte(brand)...), make([]byte, 12)...)
	}
	write("mp4blob", ftyp("isom"))
	write("qtblob", ftyp("qt  "))
	write("m4vblob", ftyp("M4V "))
	write("short", []byte("abc"))
	write("gifblob", []byte("GIF89a......."))

	cases := map[string]string{
		"mp4blob": "video/mp4",
		"qtblob":  "video/quicktime",
		"m4vblob": "video/mp4",
		"short":   "",
		"gifblob": "",
		"missing": "",
	}
	for name, want := range cases {
		if got := blossomContentType(name, ""); got != want {
			t.Errorf("blob %q: got %q want %q", name, got, want)
		}
	}
}

// The hash-first lookup must find a blob stored bare, stored with the
// requested extension, or stored with any other extension.
func TestOpenBlobFileResolution(t *testing.T) {
	prev, prevFs := config, fs
	t.Cleanup(func() { config, fs = prev, prevFs })
	fs = afero.NewMemMapFs()
	config.BlossomPath = "/blossom/"
	for _, name := range []string{"aaa", "bbb.mov", "ccc.webm"} {
		if err := afero.WriteFile(fs, config.BlossomPath+name, []byte(name), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cases := []struct{ hash, ext, want string }{
		{"aaa", "", "aaa"},
		{"aaa", "mp4", "aaa"},
		{"bbb", "mov", "bbb.mov"},
		{"bbb", ".mov", "bbb.mov"},
		{"ccc", "mp4", "ccc.webm"},
		{"ccc", "", "ccc.webm"},
	}
	for _, c := range cases {
		f, err := openBlobFile(c.hash, c.ext)
		if err != nil {
			t.Errorf("%s/%s: %v", c.hash, c.ext, err)
			continue
		}
		buf := make([]byte, 16)
		n, _ := f.Read(buf)
		f.Close()
		if string(buf[:n]) != c.want {
			t.Errorf("%s/%s: opened %q want %q", c.hash, c.ext, buf[:n], c.want)
		}
	}
	if _, err := openBlobFile("zzz", "mp4"); err == nil {
		t.Error("missing blob must error")
	}
}
