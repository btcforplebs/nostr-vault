package com.nostrvault.service

/**
 * One run of a job at a time, without losing a request made during a run:
 * [tryStart] says whether to start now; a call while one runs is remembered,
 * and [finish] says whether to run once more for it. Many calls during a run
 * still mean one more run. Thread-safe.
 */
internal class RerunGate {
    private var running = false
    private var again = false

    /** True: start a run now. False: one is running; it will be asked to run again. */
    @Synchronized fun tryStart(): Boolean {
        if (running) { again = true; return false }
        running = true
        return true
    }

    /** At the end of a run. True: a call came in during it, so start another run (it is already counted as started). */
    @Synchronized fun finish(): Boolean {
        if (again) { again = false; return true }
        running = false
        return false
    }
}
