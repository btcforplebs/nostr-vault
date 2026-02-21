# Syncing Upstream Haven (Go) Changes

This repo uses `git subtree` to manage the upstream [bitvora/haven](https://github.com/bitvora/haven) Go code under the `haven-go/` directory.

## Setup (one-time)

If you haven't added the upstream remote yet:

```bash
git remote add upstream https://github.com/bitvora/haven.git
```

## Pulling Upstream Changes

**Always use `git subtree pull`** to bring in upstream Go changes. This keeps upstream commits on a separate branch line in the git graph and avoids duplicate commits.

```bash
git subtree pull --prefix=haven-go upstream master
```

### Important: Do NOT

- **Do not** manually cherry-pick or copy changes from the upstream repo into `haven-go/` — this creates duplicate commits with different SHAs and makes the history messy.
- **Do not** use `--squash` — this collapses upstream history into a single commit and loses the individual commit trail.
- **Do not** use `git merge upstream/master` directly — the upstream repo has files at root level, not under `haven-go/`, so a direct merge won't map paths correctly.

## Making Changes to Go Code

If you need to modify files under `haven-go/`:

1. Make changes directly in `haven-go/` and commit to your `master` branch as normal.
2. These will appear on your master branch line, separate from upstream commits.
3. Future `git subtree pull` commands will merge upstream changes alongside yours.

### Downstream Sandbox & CGO Modifications (Important during Merges)

Because HavenApp embeds `haven-go` as a **C-Shared library (`libhaven.a`)** for macOS App Sandbox compliance, several upstream files are permanently modified downstream. Expect conflicts on these files during `git subtree pull`, and resolve them to favor the downstream macOS constraints:

- `haven-go/init.go`: Global database initializations (`var privateDB = newDBBackend(...)`) were moved inside `initDBs()` to prevent premature App Sandbox LMDB blockades before Swift could propagate the `"DB_ENGINE": "badger"` preference. 
- `haven-go/main.go`: Modified to detect `isCShared()` and block `http.ListenAndServe()` from running natively, deferring execution control to the CGO exports.
- `haven-go/cshared.go` & `cshared_stub.go`: New files exporting `StartRelayC()`, `StopRelayC()`, and `SetHavenEnvC()` CGO bridges to Swift.
- `haven-go/lib.go` / `config.go`: Contains modifications for runtime environment overrides across the bridge.

## Pushing Changes Upstream (Contributing Back)

If you want to contribute changes back to `bitvora/haven`:

```bash
git subtree push --prefix=haven-go upstream <branch-name>
```

This extracts commits that touched `haven-go/` and pushes them to the upstream repo on the specified branch. Then open a PR on the upstream repo.
