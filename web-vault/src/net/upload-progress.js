// A media server PUT that reports how much has gone up (the composer's progress ring) and can be stopped (a photo
// removed mid-upload). fetch can't report upload progress, so this is XMLHttpRequest, answering like a fetch Response
// as far as uploadPhoto reads one: ok, status, headers.get, json().

/** -> Promise<{ ok, status, headers: { get }, json }>; rejects with an AbortError when `signal` aborts. */
export function xhrPut(url, { headers = {}, body, signal, onProgress } = {}, XHR = globalThis.XMLHttpRequest) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(abortError())
    const x = new XHR()
    x.open("PUT", url)
    for (const [k, v] of Object.entries(headers)) x.setRequestHeader(k, v)
    if (onProgress && x.upload) x.upload.onprogress = e => { if (e.lengthComputable && e.total > 0) onProgress(e.loaded / e.total) }
    const stop = () => x.abort()
    signal?.addEventListener?.("abort", stop, { once: true })
    const done = () => signal?.removeEventListener?.("abort", stop)
    x.onload = () => {
      done()
      resolve({ ok: x.status >= 200 && x.status < 300, status: x.status, headers: { get: k => x.getResponseHeader(k) },
        json: async () => JSON.parse(x.responseText) })
    }
    x.onerror = () => { done(); reject(new Error("network error")) }
    x.onabort = () => { done(); reject(abortError()) }
    x.send(body)
  })
}

export const abortError = () => Object.assign(new Error("Upload stopped"), { name: "AbortError" })
