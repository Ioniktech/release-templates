# release-templates

Worked examples of releasing and deploying to different target systems. One
directory per technology; each holds a hello-world artifact whose only purpose
is to be built, tested and published for real, so the pipeline around it can be
copied into a project that matters.

| Directory | Artifact | Published to |
|---|---|---|
| [`python/`](python/) | [`ioniktech-hello-world`](python/pyproject.toml) package | PyPI (Trusted Publishing, OIDC) |
| [`docker/`](docker/) | [`hello-world`](docker/Dockerfile) image | Docker Hub (multi-arch) |

## Releasing

A single tag releases everything. The version is declared per technology, and
`v1.2.3` must match all of them:

- `python/src/hello_world/version.py` → `__version__ = '1.2.3'`
- `docker/VERSION` → `1.2.3`

`main` only takes pull requests, so a release is two steps and
`scripts/release-helper.sh` does both.

**1. The bump.** Writes every version file on a `release/vX.Y.Z` branch,
commits and pushes it, and prints the pull request to open:

```sh
scripts/release-helper.sh --show        # what is the current version?
scripts/release-helper.sh --dry-run --add-minor
scripts/release-helper.sh --add-fix     # 1.2.3 -> 1.2.4
scripts/release-helper.sh --add-minor   # 1.2.3 -> 1.3.0
scripts/release-helper.sh --add-major   # 1.2.3 -> 2.0.0
scripts/release-helper.sh 1.2.3         # or set it outright
```

The `--add-*` options count one component up from the current version and reset
the less significant ones, so they need every technology to already agree on
that version; if they have drifted, pass an explicit `X.Y.Z` instead.

**2. The tag.** Once that pull request is merged, from an up-to-date `main`:

```sh
git switch main && git pull
scripts/release-helper.sh --tag
```

`--tag` takes no version — it tags what the merged version files already
declare, which is the same thing `release.yml` will check the tag against. This
is the step that publishes, so it refuses anything but a clean `main` in sync
with `origin/main`.

It refuses a version that is not `X.Y.Z`, or a tag or release branch that
already exists locally or on `origin`, warns when you are not branching off
`main` or have unrelated uncommitted changes, and re-reads every file after
writing it. Both pushes are confirmed interactively because a PyPI version
cannot be republished; `--yes` skips the prompt and `--dry-run` prints every
step without touching anything. Declining leaves the work local, with the
commands to push or undo.

`release.yml` checks the tag against every declared version first and fails the
whole run before publishing anything if they disagree. Then each technology is
tested and published independently, each behind a GitHub environment
(`pypi`, `dockerhub`) that requires a manual approval. Once both have published,
`notify.yml` announces the version in Slack and on Mastodon — only then, since a
release that did not ship is not worth announcing.

No workflow spells out an artifact name. Each one is read from the file that
declares it:

- the PyPI distribution and the console script, from `python/pyproject.toml`;
- the image name, from the `org.opencontainers.image.title` label in
  `docker/Dockerfile`;
- the project name, from the repository itself.

The publishing jobs hand those names to `notify.yml`, so the announcement links
to what was actually published. Rename an artifact in the file that declares it
and the pipeline follows — there is nothing else to keep in step, and nothing
to configure.

## Required configuration

| Where | Name | Purpose |
|---|---|---|
| PyPI project settings | — | Trusted Publisher for `Ioniktech/release-templates`, workflow `release.yml`, environment `pypi`. No token needed. |
| Environment `dockerhub` | `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (secrets) | Docker Hub access token, not the account password. |
| Environment `dockerhub` | `DOCKERHUB_NAMESPACE` (variable) | Docker Hub org or user that owns the image. |
| Repository | `SLACK_WEBHOOK_RELEASE` (secret) | Incoming webhook for the channel releases are announced in. Optional. |
| Repository | `SLACK_WEBHOOK_CI` (secret) | Incoming webhook for the channel green CI runs are reported in. Optional. |
| Repository | `MASTODON_ACCESS_TOKEN` (secret) | Token with the `write:statuses` scope. Releases only. Optional. |
| Repository | `MASTODON_INSTANCE` (variable) | Instance hostname to post to, no scheme — e.g. `mastodon.social`. Optional. |

Add a required reviewer to both environments if you want the approval gate to
actually stop a release.

A Slack incoming webhook is bound to one channel, so the two channels are two
secrets; `notify.yml` itself is channel-agnostic and each caller maps its own
secret onto the name the workflow reads. These settings are repository-level,
not environment-level, because `notify.yml` runs outside the publishing
environments. Leave any of them unset and that destination is skipped, so a fork
releases without them.

## CI

Push and pull requests to `main` run build-and-test only — nothing is ever
published outside of a `v*` tag. `python-ci.yml` and `docker-ci.yml` are scoped
with `paths:` filters, so touching one technology does not run the other's
pipeline. `analysis.yml` runs CodeQL across the repo.

## Licence

Apache-2.0, see [`LICENSE`](LICENSE). `python/LICENSE` and `docker/LICENSE` are
byte-identical copies, because each published artifact has to carry its own
licence text and neither build can read a file above its own directory.

## Adding a technology

1. Create the directory with a hello-world artifact and a version declaration.
2. Add `<tech>-ci.yml`, scoped with a `paths:` filter.
3. Add the version to the `check` job in `release.yml`, plus a `test-<tech>`
   and `publish-<tech>` job pair. Read the artifact name from the technology's
   own manifest, expose it as a job output, and pass it to `notify.yml` as an
   input instead of writing it into a message.
4. Add the ecosystem to `.github/dependabot.yml` and, if it is a new language,
   to the CodeQL matrix in `analysis.yml`.
5. Copy `LICENSE` into the directory if its build cannot read the root one.
