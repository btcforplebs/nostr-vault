import { useEffect, useState } from "preact/hooks"
import { getProfile, onProfiles } from "../net/profiles.js"

/** The cached kind 0 for pk, re-rendering when profiles arrive. */
export function useProfile(pk) {
  const [p, setP] = useState(() => getProfile(pk))
  useEffect(() => { setP(getProfile(pk)); return onProfiles(() => setP(getProfile(pk))) }, [pk])
  return p
}
