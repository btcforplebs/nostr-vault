package blossom

import (
	"context"
	"mime"
	"net/http"
)

func blossomError(w http.ResponseWriter, msg string, code int) {
	w.Header().Add("X-Reason", msg)
	w.WriteHeader(code)
}

func getExtension(mimetype string) string {
	if mimetype == "" {
		return ""
	}

	switch mimetype {
	case "image/jpeg":
		return ".jpg"
	case "image/gif":
		return ".gif"
	case "image/png":
		return ".png"
	case "image/webp":
		return ".webp"
	case "video/mp4":
		return ".mp4"
	case "application/vnd.android.package-archive":
		return ".apk"
	}

	exts, _ := mime.ExtensionsByType(mimetype)
	if len(exts) > 0 {
		return exts[0]
	}

	return ""
}

type requestHostKey struct{}

// RequestHost is the Host header of the request a RejectDelete hook is
// judging (the name the client used to reach this server), or "".
func RequestHost(ctx context.Context) string {
	h, _ := ctx.Value(requestHostKey{}).(string)
	return h
}
