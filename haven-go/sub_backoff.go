package main

import "time"

// healthySubscription is how long a live subscription must stay open before
// its close counts as an ordinary drop rather than a flap.
const healthySubscription = 2 * time.Minute

// maxResubscribeBackoff caps the wait between reopening a live subscription.
const maxResubscribeBackoff = 60 * time.Second

// nextResubscribeBackoff returns how long to wait before reopening a live
// subscription that just closed after staying open for `lived`, and the
// backoff to carry into the next close.
//
// Receiving events is not a sign of health: a relay that accepts the REQ,
// replays the `since` second and then drops the socket delivers an event on
// every attempt, and resetting on that kept the retry at one second forever.
// Only a subscription that stayed up resets the wait.
func nextResubscribeBackoff(cur, lived time.Duration) (wait, next time.Duration) {
	if cur <= 0 || lived >= healthySubscription {
		cur = time.Second
	}
	next = cur * 2
	if next > maxResubscribeBackoff {
		next = maxResubscribeBackoff
	}
	return cur, next
}
