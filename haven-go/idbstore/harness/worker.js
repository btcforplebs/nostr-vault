// Dedicated-worker host for the Go test binary (context "worker" in index.html).
// Go's stdout/stderr go through console.log in wasm_exec.js; forward them to
// the page so chrome_exec.mjs sees them on the page's CDP session.
console.log = (...a) => postMessage({ log: a.join(" ") });
console.error = (...a) => postMessage({ log: a.join(" "), err: true });
console.warn = console.error;
importScripts("wasm_exec.js");

onmessage = async ({ data: { args, env } }) => {
  const go = new Go();
  go.argv = ["test.wasm", ...args];
  go.env = env;
  go.exit = (code) => postMessage({ exit: code });
  const t0 = performance.now();
  const { instance } = await WebAssembly.instantiateStreaming(fetch("test.wasm"), go.importObject);
  postMessage({ instantiateMs: performance.now() - t0 });
  await go.run(instance);
};
