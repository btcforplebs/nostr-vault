// Runs a dev server.mjs in `cwd` on a free port and resolves its base URL once it's listening; stopped after the test.
import { spawn } from "node:child_process"
import net from "node:net"
import { fileURLToPath } from "node:url"

const freePort = () => new Promise(resolve => {
  const s = net.createServer().listen(0, () => { const { port } = s.address(); s.close(() => resolve(port)) })
})

export async function startServer(t, script, cwd) {
  const port = await freePort()
  const child = spawn(process.execPath, [fileURLToPath(script)], { cwd, env: { ...process.env, PORT: String(port) }, stdio: ["ignore", "pipe", "inherit"] })
  t.after(() => child.kill())
  await new Promise((resolve, reject) => {
    child.stdout.once("data", resolve)
    child.once("exit", code => reject(new Error(`server exited ${code}`)))
  })
  return `http://127.0.0.1:${port}`
}
