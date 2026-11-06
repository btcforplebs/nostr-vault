package main

import (
	"bytes"
	"context"
	"io"
	"mime"
	"net/http"
	"strings"

	"github.com/fiatjaf/khatru/blossom"
)

// blossomContentType resolves a Content-Type for a blob that Go's sniffer
// can't: MOV/MP4 aren't in http.DetectContentType's table, so without this
// every video blob whose stored MIME is missing/octet-stream gets served as
// application/octet-stream — which confuses clients that classify by MIME.
//
// Never a type a browser runs as a page or script (activeBlobTypes): the
// extension in the URL is the requester's choice, not the uploader's, so
// /<sha>.html of any stored file would otherwise be served as a page on the
// vault's origin. Those come back as application/octet-stream, and so does a
// file with no known extension that Go's sniffer would call HTML or XML.
func blossomContentType(hash string, ext string) string {
	if ext != "" {
		lower := strings.ToLower(ext)
		if ct, ok := blossomExtTypes[lower]; ok {
			return ct
		}
		if ct := mime.TypeByExtension("." + lower); ct != "" {
			return inertBlobType(ct)
		}
	}
	file, err := openBlobFile(hash, ext)
	if err != nil {
		return "" // not here: a 404, nothing is served
	}
	defer file.Close()
	head := make([]byte, 512)
	n, _ := io.ReadFull(file, head)
	head = head[:n]
	// ISO-BMFF container: [size][ftyp][major brand]
	if n >= 12 && bytes.Equal(head[4:8], []byte("ftyp")) {
		if bytes.Equal(head[8:12], []byte("qt  ")) {
			return "video/quicktime"
		}
		return "video/mp4"
	}
	// Never empty from here: left empty, http.ServeContent takes the type
	// from the name khatru builds out of the STORED type, so a record typed
	// text/html (the signed upload keeps the uploader's Content-Type) would
	// be served as a page (Tron, PR #1799 review). The bytes decide when they
	// can; else the stored type, made inert; else what the sniffer said.
	sniffed := http.DetectContentType(head)
	if mt, _, _ := mime.ParseMediaType(sniffed); mt != "text/plain" && mt != blobInertType {
		return inertBlobType(sniffed)
	}
	if stored := storedBlobType(hash); stored != "" {
		return inertBlobType(stored)
	}
	return inertBlobType(sniffed)
}

// storedBlobType: the type in the blob's record, "" when it has none.
func storedBlobType(hash string) string {
	if blossomDB == nil {
		return ""
	}
	idx := blossom.EventStoreBlobIndexWrapper{Store: blossomDB}
	bd, err := idx.Get(context.Background(), hash)
	if err != nil || bd == nil {
		return ""
	}
	return bd.Type
}

const blobInertType = "application/octet-stream"

// inertBlobType returns ct, or application/octet-stream when ct is a type a
// browser would run (html, xhtml, svg, js, xml).
func inertBlobType(ct string) string {
	mediaType, _, err := mime.ParseMediaType(ct)
	if err != nil || activeBlobTypes[strings.ToLower(mediaType)] || strings.HasSuffix(strings.ToLower(mediaType), "+xml") ||
		strings.Contains(strings.ToLower(mediaType), "javascript") || strings.Contains(strings.ToLower(mediaType), "ecmascript") {
		return blobInertType
	}
	return ct
}
