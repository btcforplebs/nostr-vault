// Box API, Storage area: the vault folder and Move vault to…. Shapes in api.js.
/** `call`: api.js's signed caller, (method, name, payload) -> data. */
export const storageApi = call => ({
  storage: () => call("GET", "storage"),
  move: path => call("POST", "move", { path }),
})
