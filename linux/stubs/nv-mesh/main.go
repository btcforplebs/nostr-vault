// Stand-in for the mesh process (linux/mesh/, Tim) until it lands: it only says it is running, so the supervisor has
// its second program to keep alive. It opens no socket and joins no mesh.
package main

import (
	"log"
	"time"
)

func main() {
	log.Print("nv-mesh stub: no mesh yet")
	for range time.Tick(time.Hour) {
		log.Print("nv-mesh stub: still here")
	}
}
