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

## Pushing Changes Upstream (Contributing Back)

If you want to contribute changes back to `bitvora/haven`:

```bash
git subtree push --prefix=haven-go upstream <branch-name>
```

This extracts commits that touched `haven-go/` and pushes them to the upstream repo on the specified branch. Then open a PR on the upstream repo.
