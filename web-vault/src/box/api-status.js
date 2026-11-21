// Box API, Status area: what the box is running and on. Shapes in api.js.
/** `call`: api.js's signed caller, (method, name, payload) -> data. */
export const statusApi = call => ({
  status: () => call("GET", "status"),
})
