// Box API, Devices area: the box and the owner's devices. Shapes in api.js.
/** `call`: api.js's signed caller, (method, name, payload) -> data. */
export const devicesApi = call => ({
  devices: () => call("GET", "devices"),
})
