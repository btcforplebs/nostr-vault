package com.nostrvault.setup

import com.nostrvault.service.FirstRunImport

/** The import tour's status line from the `setup` job (FirstRunImport), in the words [ImportTourStage] reads. */
object FirstRunTour {
    fun statusLine(state: FirstRunImport.State): String = when (state) {
        FirstRunImport.State.Idle, FirstRunImport.State.Starting -> "Connecting to your relays…"
        is FirstRunImport.State.Bringing ->
            if (state.stored > 0) "Found notes: ${"%,d".format(state.stored)} so far" else "Found notes"
        is FirstRunImport.State.In -> "Done"
        is FirstRunImport.State.Failed -> ""
    }
}
