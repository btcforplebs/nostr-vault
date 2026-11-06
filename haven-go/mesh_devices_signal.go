package main

import "net/http"

// meshDevicesHeader tells the apps that this vault holds a paired device set
// and refused a Blossom request over the mesh. The app falls back to the
// owner's 24242 only on a 401/403 WITHOUT it (Tim, Tron's should-fix on
// #1803): a vault that knows device keys must never be sent the account key,
// nor make a bunker owner's signer prompt. Older engines, and a vault that
// has not been given the set yet, send no header and keep the fallback.
//
// It cannot be a reason string: withMeshDeviceAuth hands a key that is not
// paired to the owner checks, so a vault with a set that refuses this phone
// answers with the owner path's refusal, the same as a vault with no set.
const meshDevicesHeader = "X-Mesh-Devices"

// withMeshDevicesSignal wraps w so that a 401 or 403 carries
// "X-Mesh-Devices: set". Only for a Blossom request (upload, get, delete)
// that came in over the mesh, on a vault that has its set: off the mesh a
// device key is never accepted, so the owner fallback stays right there, and
// the public URL does not learn whether a set exists. Websockets and
// everything else get w unchanged (no wrapper, so Hijack keeps working).
func withMeshDevicesSignal(w http.ResponseWriter, r *http.Request) http.ResponseWriter {
	if meshDevices.selfKey() == "" || !meshDeviceOverMesh(r) {
		return w
	}
	if _, _, _, ok := meshDeviceVerb(r); !ok {
		return w
	}
	return &meshDevicesSignalWriter{ResponseWriter: w}
}

type meshDevicesSignalWriter struct {
	http.ResponseWriter
	wroteHeader bool
}

func (s *meshDevicesSignalWriter) WriteHeader(code int) {
	if !s.wroteHeader && (code == http.StatusUnauthorized || code == http.StatusForbidden) {
		s.Header().Set(meshDevicesHeader, "set")
	}
	s.wroteHeader = true
	s.ResponseWriter.WriteHeader(code)
}

func (s *meshDevicesSignalWriter) Write(b []byte) (int, error) {
	s.wroteHeader = true
	return s.ResponseWriter.Write(b)
}

// Unwrap: http.ResponseController reaches the real writer (Flush).
func (s *meshDevicesSignalWriter) Unwrap() http.ResponseWriter { return s.ResponseWriter }
