# Releasing stackd

Releasing is: bump the version, merge, push a tag. The **Release** workflow
(`.github/workflows/release.yml`) does the rest:

1. Checks that the tag matches `CFBundleShortVersionString` in `Resources/Info.plist` and points to a
   commit on `main`, then builds (warnings as errors), tests and bundles the app.
2. Creates the GitHub Release for the tag with auto-generated notes (skipped if it already exists).
3. Downloads the tag's source tarball, checks that it contains exactly the commit step 1 verified
   (so a moved tag cannot slip in), computes its sha256 and updates `url` and `sha256` in
   `stackd.rb` in [`lord-helicon/homebrew-tap`](https://github.com/lord-helicon/homebrew-tap),
   committed as `stackd X.Y.Z` on `main`. It never touches `lazyssh.rb`, and it does nothing if the
   formula is already up to date.

No binary is attached: the formula builds from source.

## One-time setup

The workflow needs permission to push to the tap, which the default `GITHUB_TOKEN` cannot do. The
token lives in a GitHub environment that only release tags can use, so a workflow on any other
branch or tag cannot read it.

1. Create a fine-grained personal access token (GitHub → Settings → Developer settings →
   Personal access tokens → Fine-grained tokens):
   - Resource owner: `lord-helicon`
   - Repository access: only `lord-helicon/homebrew-tap`
   - Permissions: **Contents: Read and write**
   - Set an expiry and a reminder to renew it.
2. In `lord-helicon/stackd` → Settings → Environments, create an environment named
   `homebrew-tap`:
   - Deployment branches and tags: **Selected branches and tags**, add the tag rule `v*.*.*`.
   - Environment secrets: add the token as `TAP_GITHUB_TOKEN`.
3. Delete any repository-level `TAP_GITHUB_TOKEN` (Settings → Secrets and variables → Actions),
   since a repository secret is readable by every workflow in the repo.
4. Recommended: Settings → Rules → Rulesets → new tag ruleset for `v*` that restricts creation,
   updates and deletion to you and blocks force pushes.

If the secret is missing, the tap job fails with a message saying so. Add the secret and re-run
that job; the GitHub Release is already created by then. If the tag was moved after the verify job
ran, the tap job refuses to publish: delete the tag and tag the intended commit again.

## Each release

```bash
Tools/bump-version.sh 0.2.0          # sets the version, increments the build number
# commit, open a PR, merge it into main
git switch main && git pull
git tag -a v0.2.0 -m "stackd 0.2.0" && git push origin v0.2.0
```

Watch the Release workflow in the Actions tab, then verify:

```bash
brew update && brew upgrade stackd
```

If the tag does not match the version in `Info.plist`, the workflow fails at the first step. Delete
the tag (`git push --delete origin v0.2.0 && git tag -d v0.2.0`), fix the version and tag again.

## Manual fallback

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`.
2. Tag `vX.Y.Z` on `main` and create a GitHub Release with notes.
3. Download `https://github.com/lord-helicon/stackd/archive/refs/tags/vX.Y.Z.tar.gz` and compute its
   sha256 (`shasum -a 256`).
4. In `lord-helicon/homebrew-tap`, edit `stackd.rb` at the repo root: update the `url` and `sha256`
   lines. Leave `lazyssh.rb` alone, it is managed by GoReleaser.
