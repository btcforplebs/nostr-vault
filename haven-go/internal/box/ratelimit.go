package box

import "time"

// failLimiter caps wrong guesses (setup codes, join codes) per client and
// for the whole box within a window, so a LAN visitor can't guess a code,
// and one sending wrong codes can't lock the owner out on another address.
// Past a cap, guesses wait out the window. At most maxClients addresses are
// tracked; past that only the box-wide cap counts for new ones. The caller
// holds its own lock around every call.
type failLimiter struct {
	window     time.Duration
	maxFails   int // per client
	maxAll     int // whole box
	maxClients int

	fails    map[string][]time.Time // per client address
	failsAll []time.Time
}

// blocked: client (or the whole box) is past its cap at now. Drops old
// failures first.
func (l *failLimiter) blocked(client string, now time.Time) bool {
	l.dropOld(now)
	return len(l.fails[client]) >= l.maxFails || len(l.failsAll) >= l.maxAll
}

// fail records a wrong guess from client at now.
func (l *failLimiter) fail(client string, now time.Time) {
	l.failsAll = append(l.failsAll, now)
	if l.fails == nil {
		l.fails = map[string][]time.Time{}
	}
	if _, known := l.fails[client]; known || len(l.fails) < l.maxClients {
		l.fails[client] = append(l.fails[client], now)
	}
}

func (l *failLimiter) dropOld(now time.Time) {
	recent := func(ts []time.Time) []time.Time {
		keep := ts[:0]
		for _, t := range ts {
			if now.Sub(t) < l.window {
				keep = append(keep, t)
			}
		}
		return keep
	}
	l.failsAll = recent(l.failsAll)
	for k, ts := range l.fails {
		if ts = recent(ts); len(ts) == 0 {
			delete(l.fails, k)
		} else {
			l.fails[k] = ts
		}
	}
}
