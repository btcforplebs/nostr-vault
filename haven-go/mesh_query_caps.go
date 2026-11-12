package main

import (
	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/policies"
)

// wireOutboxReads adds the outbox's read rules to rl: empty and complex
// filters refused unless the limits allow them, queries and counts with
// NIP-50 search (search.go), brought-over accounts hidden from everyone but
// the vault's own (brought_reads.go). Over the mesh: no queries.
func wireOutboxReads(rl *khatru.Relay, db DBBackend, limits OutboxRelayLimits) {
	if !limits.AllowEmptyFilters {
		rl.RejectFilter = append(rl.RejectFilter, policies.NoEmptyFilters)
	}
	if !limits.AllowComplexFilters {
		rl.RejectFilter = append(rl.RejectFilter, policies.NoComplexFilters)
	}
	rl.RejectFilter = append(rl.RejectFilter, meshNoQueries)
	rl.RejectCountFilter = append(rl.RejectCountFilter, meshNoQueries)
	enableSearch(rl, db)
	hideBroughtOnOutbox(rl)
}
