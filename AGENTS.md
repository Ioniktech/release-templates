## What this repository is

A catalogue of worked release/deploy pipelines: **one directory per technology**,
each holding a hello-world artifact that exists only so the pipeline around it
can be built, tested and published for real. Today: `python/` → PyPI, `docker/`
→ Docker Hub. The artifacts are deliberately trivial; the workflows are the
product.

So two things follow. First, the hello-world code is a fixture — keep it small
and resist adding features to it. Second, when something would make a pipeline
more copy-pasteable into a real project, that is the change worth making.

## Repository layout

```
python/   pyproject.toml, src/hello_world/, tests/   -> ioniktech-hello-world on PyPI
docker/   Dockerfile, hello.sh, VERSION              -> <namespace>/hello-world on Docker Hub
scripts/  release-helper.sh                          cuts a release end to end
.github/workflows/
  python-ci.yml   build + test, paths-filtered to python/
  docker-ci.yml   build + smoke test, paths-filtered to docker/
  release.yml     the only workflow that publishes anything
  analysis.yml    CodeQL
```

## Release architecture

Two classes of workflow, split by trigger:

- **CI (never publishes)** — `python-ci.yml`, `docker-ci.yml`, `analysis.yml` on
  push and PRs to `main`. `docker-ci.yml` builds to a throwaway `hello-world:ci`
  tag deliberately, and each CI workflow carries a `paths:` filter so touching
  one technology does not run the other's pipeline.
- **Release (publishes)** — `release.yml` triggers only on `v*` tags and is the
  single place artifacts leave the repo.

`release.yml` is **one tag for every technology**, shaped as gate → test →
publish:

```
check ──┬── test-python ── publish-pypi       (environment: pypi)
        └── test-docker ── publish-dockerhub  (environment: dockerhub)
```

Three invariants hold it together:

1. **Tag/version agreement, checked up front.** `check` compares
   `${GITHUB_REF_NAME#v}` against *every* declared version — `cut -d "'" -f 2
   python/src/hello_world/version.py` and `tr -d '[:space:]' < docker/VERSION` —
   accumulating failures so one run reports all drift, and nothing publishes if
   any disagree. The python `cut` assumes a single-quoted literal in
   `version.py`; that file is also the version source for `pyproject.toml` via
   `[tool.setuptools.dynamic]`, so there is exactly one place to bump per
   technology.
2. **PyPI Trusted Publishing.** `publish-pypi` carries `environment: pypi` plus
   `permissions: id-token: write` and uses `pypa/gh-action-pypi-publish` with no
   token — auth is OIDC. Removing the environment or the `id-token` permission
   silently breaks publishing. Docker Hub auth is unrelated: `DOCKERHUB_USERNAME`
   / `DOCKERHUB_TOKEN` secrets plus a `DOCKERHUB_NAMESPACE` variable, all on the
   `dockerhub` environment.
3. **Both environments are the approval gate.** Publishing is real, and the
   `pypi` / `dockerhub` environments are what make it pause for a reviewer.
   Do not move the publish steps out of them.

Each job declares the narrowest permissions it needs, with a workflow-level
`contents: read` as the floor. Do not hoist `id-token: write` to the top level
of `release.yml`.

`scripts/release-helper.sh` is the intended way to bump: it writes every
version file, commits, tags and pushes, and it reads those files with the same
one-liners `release.yml` uses so the script and the gate cannot disagree about
what a version file says. It is also the reason the version-file formats are
load-bearing — `write_python` emits single quotes because `cut -d "'"` parses
them back. Keep `TECHNOLOGIES` and the `read_`/`write_`/`file_of` trio in sync
with the `check` job.

Both publish jobs end with a verify step that installs or pulls the artifact
back from the real registry and asserts the version — a release that cannot be
consumed is a failed release. The PyPI one sleeps 60s for the CDN.

## Conventions

- Action versions are pinned at the major: `actions/checkout@v5`,
  `actions/setup-python@v6`, `actions/upload-artifact@v5`,
  `github/codeql-action/*@v4`, `docker/*-action@v3`,
  `docker/build-push-action@v6`. Keep them consistent across all workflows when
  bumping. The `actions/*` and `github/*` majors are the Node 24 ones — older
  majors run on the deprecated Node 20 and warn on every run.
- Nothing about the owner is hardcoded: the Docker Hub namespace comes from
  `vars.DOCKERHUB_NAMESPACE`, so a fork works unchanged.
- Build args passed to `docker build` are `BUILD_DATE`, `BUILD_NUMBER`
  (`run_id-run_number-run_attempt`), `RELEASE` (the version) and `VERSION` (the
  commit SHA). `RELEASE` is also baked in as an env var so `docker run` reports
  its own release, which is what the smoke tests assert on.
- Release images are multi-arch (`linux/amd64,linux/arm64`) with `provenance`
  and `sbom` enabled; CI builds are single-arch for speed.
- Python versions: CI tests the supported floor and ceiling (3.9 / 3.13),
  release pins 3.13. `python/` must stay 3.9-compatible — annotations rely on
  `from __future__ import annotations`, and `ruff` enforces it.
- Dependabot has one entry per technology directory plus `github-actions` at the
  root.
- `LICENSE` is the verbatim Apache-2.0 text, and `python/LICENSE` and
  `docker/LICENSE` are byte-identical copies. The copies exist because neither a
  setuptools `license-files` glob nor a Docker build context can reach outside
  its own directory, and each distribution has to carry its own licence text.
  Change the licence in all three or none — `diff -q LICENSE python/LICENSE` and
  the same against `docker/LICENSE` should stay silent.

## Adding a technology

1. New directory with a hello-world artifact and a version declaration.
2. `<tech>-ci.yml` with a `paths:` filter.
3. In `release.yml`: extend the `check` job with that version file, then add a
   `test-<tech>` / `publish-<tech>` pair behind a new environment.
4. Register it in `.github/dependabot.yml`, and in the CodeQL matrix in
   `analysis.yml` if it brings a new language.
5. Add a `read_`/`write_` pair plus a `file_of` case to
   `scripts/release-helper.sh`, and its name to `TECHNOLOGIES`.
6. Add the row to the table in `README.md` and the required-configuration table.

## Working here

Everything in this repo actually runs locally; verify before committing.

```sh
# python
cd python && pip install -e '.[dev]' && ruff check . && pytest
python -m build && twine check dist/*

# docker
docker build docker --build-arg RELEASE="$(tr -d '[:space:]' < docker/VERSION)" -t hello-world:ci
docker run --rm hello-world:ci

# workflows
actionlint
```

Releases cannot be rehearsed locally — publishing is gated on real registry
credentials. To exercise `release.yml`, bump every version file in lockstep and
push a matching `v*` tag.
