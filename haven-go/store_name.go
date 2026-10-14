package main

import (
	"regexp"
	"strings"
)

// storePrefix is havenStart's cfg.storePrefix: a page that may hold more than
// one account names its stores per account ("haven:<prefix>:feed"), so a
// second account never opens the first one's data. Empty keeps "haven:feed".
var storePrefix string

var storePrefixRe = regexp.MustCompile(`^[0-9A-Za-z_-]{1,64}$`)

func storeName(prefix, path string) string {
	route := strings.TrimPrefix(path, "db/")
	if prefix == "" {
		return "haven:" + route
	}
	return "haven:" + prefix + ":" + route
}
