package box

import "net/http"

// routeFunc answers one owner-checked box API route. body is the request
// body the NIP-98 check already read.
type routeFunc func(a *API, w http.ResponseWriter, r *http.Request, body []byte)

// boxRoutes maps "METHOD /api/box/path" to its handler. Each routes_*.go
// file registers its own area's routes from init, so a new area is a new
// file and never an edit to a shared switch.
var boxRoutes = map[string]routeFunc{}

func handle(route string, f routeFunc) {
	if _, dup := boxRoutes[route]; dup {
		panic("box: route registered twice: " + route)
	}
	boxRoutes[route] = f
}
