// Box API, Update area. Shapes in api.js.
/** `call`: api.js's signed caller, (method, name, payload) -> data. */
export const updateApi = call => ({
  update: () => call("POST", "update", {}),
})
