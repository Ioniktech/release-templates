# hello-world (Python / PyPI)

A hello-world package whose only job is to be released to PyPI, so the release
pipeline around it can be copied into a real project.

```sh
pip install -e '.[dev]'
pytest
hello-world            # Hello, world!
hello-world Ioniktech  # Hello, Ioniktech!
hello-world --version
```

The version lives in `src/hello_world/version.py` and is the single source of
truth: `pyproject.toml` reads it through `[tool.setuptools.dynamic]`, and the
release workflow checks the git tag against that same attribute.

Publishing uses [PyPI Trusted Publishing][tp] — PyPI authenticates the workflow
over OIDC and no API token is stored anywhere. See the repository README for the
one-time PyPI-side setup.

[tp]: https://docs.pypi.org/trusted-publishers/
