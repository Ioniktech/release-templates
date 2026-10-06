# hello-world (Docker / Docker Hub)

A hello-world image whose only job is to be released to Docker Hub, so the
release pipeline around it can be copied into a real project.

```sh
docker build . --build-arg RELEASE="$(cat VERSION)" -t hello-world:dev
docker run --rm hello-world:dev            # Hello, world!
docker run --rm hello-world:dev Ioniktech  # Hello, Ioniktech!
```

The version lives in `VERSION` and the release workflow checks the git tag
against it. It is passed in as the `RELEASE` build arg, baked into the image as
an env var so `docker run` can report which release it came from, and set as the
`org.opencontainers.image.version` label.

Build args the workflows supply: `BUILD_DATE`, `BUILD_NUMBER`
(`run_id-run_number-run_attempt`), `RELEASE`, and `VERSION` (the commit SHA).
Releases are built for `linux/amd64` and `linux/arm64` with provenance and an
SBOM attached, and tagged `:<version>` and `:latest`.
