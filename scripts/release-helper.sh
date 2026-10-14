#!/usr/bin/env bash
#
# Cuts a release in two steps, because `main` requires a pull request:
#
#   1. the bump   -- sets the version across every technology directory on a
#                    release branch, commits and pushes it for review
#   2. --tag      -- once that branch is merged, tags the merged `main` and
#                    pushes the tag, which is what triggers release.yml
#
# One tag releases everything in this repo, and release.yml refuses to publish
# unless the tag matches the version declared by *every* technology. Bumping
# them by hand is what makes that check fail, so bump them with this instead.
#
# Adding a technology means adding a read_/write_ pair below and its name to
# TECHNOLOGIES.
set -euo pipefail

cd "$(dirname "$0")/.."   # always operate on the repository root

TECHNOLOGIES='python docker'

PYTHON_VERSION_FILE='python/src/hello_world/version.py'
DOCKER_VERSION_FILE='docker/VERSION'

# Read with the same one-liners release.yml uses, so this script and the
# release gate can never disagree about what a version file says.
read_python() { cut -d "'" -f 2 "$PYTHON_VERSION_FILE"; }
read_docker() { tr -d '[:space:]' < "$DOCKER_VERSION_FILE"; }

# The single quotes matter: release.yml parses this file with `cut -d "'"`.
write_python() { printf "__version__ = '%s'\n" "$1" > "$PYTHON_VERSION_FILE"; }
write_docker() { printf '%s\n' "$1" > "$DOCKER_VERSION_FILE"; }

file_of() {
  case "$1" in
    python) echo "$PYTHON_VERSION_FILE" ;;
    docker) echo "$DOCKER_VERSION_FILE" ;;
  esac
}

DRY_RUN=0
ASSUME_YES=0

# Rejects a second --add-* rather than letting the last one silently win.
set_bump_part() {
  if [ -n "$bump_part" ] && [ "$bump_part" != "$1" ]; then
    echo "error: --add-$bump_part and --add-$1 are mutually exclusive" >&2
    exit 1
  fi
  bump_part="$1"
}

usage() {
  cat <<'EOF'
Usage:
  scripts/release-helper.sh [--dry-run] [--yes] <version>
  scripts/release-helper.sh [--dry-run] [--yes] --add-fix|--add-minor|--add-major
  scripts/release-helper.sh [--dry-run] [--yes] --tag
  scripts/release-helper.sh --show

A release is two steps, because `main` only takes pull requests:

  1. the bump, above: writes every version file on a `release/vX.Y.Z` branch,
     commits and pushes it. Open the pull request it prints and merge it.
  2. --tag, from an up-to-date `main` after that merge: tags the merged commit
     with the version the files already declare and pushes the tag, which is
     what release.yml triggers on.

Arguments:
  <version>    X.Y.Z, set across every technology directory

Options:
      --add-fix     bump the current version's patch:  1.2.3 -> 1.2.4
      --add-minor   bump the minor, reset the patch:   1.2.3 -> 1.3.0
      --add-major   bump the major, reset the rest:    1.2.3 -> 2.0.0
  -t, --tag       step 2: tag the current main and push the tag
  -n, --dry-run   print every step without touching files, git or the remote
  -y, --yes       do not ask for confirmation before pushing
  -s, --show      print the current version of each technology and exit
  -h, --help      this message

The --add-* options read the current version from the technology directories,
which must already agree; pass an explicit <version> to resolve a disagreement.

Pushing the tag triggers release.yml, which publishes to PyPI and Docker Hub
once their environments are approved. A PyPI version cannot be republished, so
the push is confirmed unless --yes is given. Use --dry-run first.
EOF
}

# Echoes every command; runs it only when this is not a dry run.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] $*"
  else
    echo "  \$ $*"
    "$@"
  fi
}

show() {
  for tech in $TECHNOLOGIES; do
    printf '  %-8s %-36s %s\n' "$tech" "$(file_of "$tech")" "$("read_$tech")"
  done
}

repo_url() {
  git remote get-url origin | sed -e 's|git@github.com:|https://github.com/|' -e 's|\.git$||'
}

confirm() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ "$ASSUME_YES" -eq 1 ] && return 0
  printf '%s [y/N] ' "$1"
  read -r reply
  case "$reply" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

# The version every technology currently agrees on. A disagreement means the
# tree is mid-bump and there is no single version to count up from, so say so
# instead of guessing which file is right.
current_version() {
  current=''
  for tech in $TECHNOLOGIES; do
    this="$("read_$tech")"
    if [ -z "$current" ]; then
      current="$this"
    elif [ "$this" != "$current" ]; then
      echo 'error: the technology directories disagree on the current version:' >&2
      show >&2
      echo 'pass an explicit X.Y.Z version to set them all.' >&2
      exit 1
    fi
  done

  if ! printf '%s' "$current" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "error: current version '$current' is not X.Y.Z; cannot bump it" >&2
    exit 1
  fi

  echo "$current"
}

# Counts one component up, resetting the less significant ones as semver says.
bump() {
  from="$1"
  part="$2"
  major="${from%%.*}"
  rest="${from#*.}"
  minor="${rest%%.*}"
  patch="${rest#*.}"

  case "$part" in
    fix) echo "$major.$minor.$((patch + 1))" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    major) echo "$((major + 1)).0.0" ;;
  esac
}

# Neither step may reuse a tag: locally, and on the remote, where it would have
# published already.
assert_tag_is_free() {
  if git rev-parse -q --verify "refs/tags/$1" >/dev/null; then
    echo "error: tag $1 already exists locally" >&2
    exit 1
  fi

  if [ -n "$(git ls-remote --tags origin "refs/tags/$1" 2>/dev/null)" ]; then
    echo "error: tag $1 already exists on origin" >&2
    exit 1
  fi
}

# --- step 1: the bump, on a branch, for review ------------------------------
bump_step() {
  version="$1"
  tag="v$version"
  branch="release/$tag"

  # A release is hard to take back, so everything checkable is checked before
  # anything is written.
  assert_tag_is_free "$tag"

  if git rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
    echo "error: branch $branch already exists locally" >&2
    exit 1
  fi

  if [ -n "$(git ls-remote --heads origin "refs/heads/$branch" 2>/dev/null)" ]; then
    echo "error: branch $branch already exists on origin" >&2
    exit 1
  fi

  base="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$base" != 'main' ]; then
    echo "warning: branching from '$base', not main" >&2
  fi

  # Only the version files get committed, so unrelated work in the tree is
  # left alone -- but it would not be in the released commit either.
  if [ -n "$(git status --porcelain -- . ':!python/src/hello_world/version.py' ':!docker/VERSION')" ]; then
    echo "warning: other uncommitted changes will NOT be part of $tag" >&2
  fi

  echo "Preparing $tag on $branch, off $base"
  [ "$DRY_RUN" -eq 1 ] && echo '(dry run: nothing will be written or pushed)'
  echo
  echo 'Current versions:'
  show

  echo
  echo 'Branching:'
  run git switch -c "$branch"

  echo
  echo 'Setting versions:'
  for tech in $TECHNOLOGIES; do
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  [dry-run] $(file_of "$tech") -> $version"
    else
      "write_$tech" "$version"
      echo "  $(file_of "$tech") -> $version"
    fi
  done

  # Re-read every file and confirm it round-tripped, so a bad write surfaces
  # here rather than in the release gate.
  if [ "$DRY_RUN" -eq 0 ]; then
    for tech in $TECHNOLOGIES; do
      actual="$("read_$tech")"
      if [ "$actual" != "$version" ]; then
        echo "error: $(file_of "$tech") reads '$actual' after the write, expected '$version'" >&2
        echo "nothing was committed; restore with: git checkout -- . && git switch $base" >&2
        exit 1
      fi
    done
  fi

  echo
  echo 'Committing:'
  version_files=''
  for tech in $TECHNOLOGIES; do
    version_files="$version_files $(file_of "$tech")"
  done
  # shellcheck disable=SC2086  # deliberate word splitting into separate paths
  run git add $version_files
  run git commit -m "Release $tag"

  echo
  if ! confirm "Push $branch to origin?"; then
    echo
    echo "Stopped. $branch is committed locally but not pushed."
    echo "  push later:  git push -u origin $branch"
    echo "  undo:        git switch $base && git branch -D $branch"
    exit 0
  fi

  echo 'Pushing:'
  run git push -u origin "$branch"

  echo
  if [ "$DRY_RUN" -eq 1 ]; then
    echo 'Dry run complete; nothing was changed.'
  else
    echo "Pushed $branch. Nothing publishes yet -- the tag does that."
    echo '  1. open and merge the pull request:'
    echo "       $(repo_url)/compare/$base...$branch?expand=1"
    echo '  2. then, on the merged main:'
    echo '       git switch main && git pull'
    echo '       scripts/release-helper.sh --tag'
  fi
}

# --- step 2: tag the merged main --------------------------------------------
tag_step() {
  version="$(current_version)"
  tag="v$version"

  assert_tag_is_free "$tag"

  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$branch" != 'main' ]; then
    echo "error: --tag expects main, not '$branch'" >&2
    echo 'the tag has to point at the merged commit that main carries.' >&2
    exit 1
  fi

  if [ -n "$(git status --porcelain)" ]; then
    echo 'error: the working tree is dirty; --tag expects the merged main as it is' >&2
    exit 1
  fi

  # The merge happened on the remote, so the local main is only trustworthy
  # once it has been compared against it.
  run git fetch origin main --tags
  if [ "$DRY_RUN" -eq 0 ] && [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo 'error: main is not in sync with origin/main; run: git pull' >&2
    exit 1
  fi

  echo
  echo "Tagging $tag at $(git rev-parse --short HEAD) on main"
  [ "$DRY_RUN" -eq 1 ] && echo '(dry run: nothing will be written or pushed)'
  echo
  echo 'Versions this tag claims:'
  show

  echo
  if ! confirm "Pushing $tag triggers release.yml: PyPI and Docker Hub, pending
environment approval. A PyPI version cannot be republished.
Tag and push?"; then
    echo
    echo "Stopped. Nothing was tagged."
    exit 0
  fi

  echo 'Tagging and pushing:'
  run git tag -a "$tag" -m "Release $tag"
  run git push origin "$tag"

  echo
  if [ "$DRY_RUN" -eq 1 ]; then
    echo 'Dry run complete; nothing was changed.'
  else
    echo "Released $tag. Approve the pypi and dockerhub environments to publish:"
    echo "  $(repo_url)/actions"
  fi
}

main() {
  version=''
  bump_part=''
  tag_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      -s | --show) show; exit 0 ;;
      -n | --dry-run) DRY_RUN=1 ;;
      -y | --yes) ASSUME_YES=1 ;;
      -t | --tag) tag_only=1 ;;
      --add-fix | --add-patch) set_bump_part fix ;;
      --add-minor) set_bump_part minor ;;
      --add-major) set_bump_part major ;;
      -*) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
      *)
        if [ -n "$version" ]; then
          echo "error: unexpected argument: $1" >&2
          exit 1
        fi
        version="$1"
        ;;
    esac
    shift
  done

  if [ "$tag_only" -eq 1 ]; then
    if [ -n "$version" ] || [ -n "$bump_part" ]; then
      echo 'error: --tag takes no version; it tags what the version files already say' >&2
      exit 1
    fi
    tag_step
    return
  fi

  if [ -n "$version" ] && [ -n "$bump_part" ]; then
    echo "error: pass either a version or --add-$bump_part, not both" >&2
    exit 1
  fi

  if [ -z "$version" ] && [ -z "$bump_part" ]; then
    usage >&2
    exit 1
  fi

  if [ -n "$bump_part" ]; then
    from="$(current_version)"
    version="$(bump "$from" "$bump_part")"
    echo "Bumping $bump_part: $from -> $version"
  fi

  # Exactly three numeric parts: the docker tag, the PyPI version and the test
  # in python/tests/test_hello.py all assume that shape.
  if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "error: '$version' is not a X.Y.Z version" >&2
    exit 1
  fi

  bump_step "$version"
}

main "$@"
