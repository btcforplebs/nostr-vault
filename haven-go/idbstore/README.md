# idbstore

An `eventstore.Store` on the browser's IndexedDB, for Haven built with
`GOOS=js GOARCH=wasm`. See `doc.go` for the record layout and query plan.

## Tests

```sh
# browser: Haven cases + eventstore's own suite, in headless Chrome
GOOS=js GOARCH=wasm go test -exec "$PWD/idbstore/harness/chrome_exec" ./idbstore/...

# native reference: the same Haven cases on eventstore/badger
go test ./idbstore/
```

`harness/chrome_exec` runs each test binary twice in one fresh Chrome profile,
with a real page reload in between, so `TestPersist` checks that events
survive a reload. Needs Node 22+ and Google Chrome (`CHROME=` to override).

`suite/` is eventstore v0.17.5's `test/` package copied unchanged (public
domain, `LICENSE.eventstore`); only `suite/db_test.go` and `suite/shared_test.go` are ours.
