// "Still to bring in" (plan item 3, as the apps' Vault tab): the long import jobs (net/import-jobs.js), each with what
// it is, its last run, what it couldn't read, and Run / Run again / Cancel. Nothing here starts on its own (Logen,
// answer 1). One job at a time: while one runs, the others wait. Redrawn on every change, in this tab or another.
import { useEffect, useState } from "preact/hooks"
import { Row, Section } from "./parts.jsx"
import { LONG_JOBS, RUN, cancelImportJob, loadJobs, onImportJobs, runImportJob, runningJob } from "../../net/import-jobs.js"
import { JOB_ABOUT, JOB_TITLE, jobButton, jobLine, unreadLines } from "../../net/import-jobs-words.js"

export function StillToBringIn({ ctx }) {
  const me = ctx.session.pubkey
  const [file, setFile] = useState(() => loadJobs(me))
  const [note, setNote] = useState("")
  useEffect(() => { setFile(loadJobs(me)); return onImportJobs(() => setFile(loadJobs(me))) }, [me])
  const here = runningJob()
  const busy = file.jobs.some(j => j.status === "running")
  const press = async j => {
    setNote("")
    if (here === j.name) return cancelImportJob(j.name)
    const code = await runImportJob(ctx, j.name)
    if (code === RUN.busy) setNote("Another import is running, here or in another tab. Run this when it's done.")
    setFile(loadJobs(me))
  }
  return (
    <Section title="Still to bring in">
      {file.jobs.filter(j => LONG_JOBS.includes(j.name)).map(j => {
        const lines = unreadLines(j)
        const mine = here === j.name
        return (
          <Row key={j.name} icon="down" title={JOB_TITLE[j.name]} detail={[jobLine(j), JOB_ABOUT[j.name], ...lines].join(" ")}
            state={j.status === "done" ? "done" : j.status === "partial" || j.status === "failed" ? "todo" : "info"}>
            <button type="button" class="dash-button small" disabled={!mine && busy} aria-busy={mine || undefined} onClick={() => press(j)}>{jobButton(j, mine)}</button>
          </Row>
        )
      })}
      {note && <div class="dash-row dash-note" role="status">{note}</div>}
    </Section>
  )
}
