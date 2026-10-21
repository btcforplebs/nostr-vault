// tabOf(route, otherProfile) picks the tab the bar lights: the phone's five tabs, with every other screen under
// the tab whose floating button opens it.
import test from "node:test"
import assert from "node:assert/strict"
import { tabOf } from "../src/components/tabs.js"

test("the five tabs light themselves", () => {
  for (const t of ["feed", "search", "profile", "wot", "vault"]) assert.equal(tabOf(t), t)
})

test("Messages, a conversation, Notifications and the Vault Dashboard sit under Vault", () => {
  for (const r of ["messages", "dm", "notifications", "relay"]) assert.equal(tabOf(r), "vault")
})

test("Settings, Accounts and the Wallet sit under Profile", () => {
  for (const r of ["settings", "accounts", "wallet"]) assert.equal(tabOf(r), "profile")
})

test("someone else's profile sits under Search", () => assert.equal(tabOf("profile", true), "search"))

test("a thread or Compose lights no tab", () => {
  for (const r of ["thread", "compose"]) assert.ok(!["feed", "search", "profile", "wot", "vault"].includes(tabOf(r)))
})
