#!/usr/bin/env bash
#
# Cuts a release: sets the version across every technology directory, commits,
# tags and pushes.
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
  scripts/release-helper.sh --show

Arguments:
  <version>    X.Y.Z, set across every technology directory

Options:
      --add-fix     bump the current version's patch:  1.2.3 -> 1.2.4
      --add-minor   bump the minor, reset the patch:   1.2.3 -> 1.3.0
      --add-major   bump the major, reset the rest:    1.2.3 -> 2.0.0
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

main() {
  version=''
  bump_part=''
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      -s | --show) show; exit 0 ;;
      -n | --dry-run) DRY_RUN=1 ;;
      -y | --yes) ASSUME_YES=1 ;;
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

  tag="v$version"

  # --- preflight -----------------------------------------------------------
  # A release is hard to take back, so everything checkable is checked before
  # anything is written.

  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "error: tag $tag already exists locally" >&2
    exit 1
  fi

  if [ -n "$(git ls-remote --tags origin "refs/tags/$tag" 2>/dev/null)" ]; then
    echo "error: tag $tag already exists on origin" >&2
    exit 1
  fi

  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$branch" != 'main' ]; then
    echo "warning: releasing from '$branch', not main" >&2
  fi

  # Only the version files get committed, so unrelated work in the tree is
  # left alone -- but it would not be in the released commit either.
  if [ -n "$(git status --porcelain -- . ':!python/src/hello_world/version.py' ':!docker/VERSION')" ]; then
    echo "warning: other uncommitted changes will NOT be part of $tag" >&2
  fi

  echo "Releasing $tag from $branch"
  [ "$DRY_RUN" -eq 1 ] && echo '(dry run: nothing will be written or pushed)'
  echo
  echo 'Current versions:'
  show

  # --- set versions --------------------------------------------------------
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
        echo 'nothing was committed; restore with: git checkout -- .' >&2
        exit 1
      fi
    done
  fi

  # --- commit and tag ------------------------------------------------------
  echo
  echo 'Committing and tagging:'
  version_files=''
  for tech in $TECHNOLOGIES; do
    version_files="$version_files $(file_of "$tech")"
  done
  # shellcheck disable=SC2086  # deliberate word splitting into separate paths
  run git add $version_files
  run git commit -m "Release $tag"
  run git tag -a "$tag" -m "Release $tag"

  # --- push ----------------------------------------------------------------
  echo
  if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    echo "Pushing $tag triggers release.yml: PyPI and Docker Hub, pending"
    echo 'environment approval. A PyPI version cannot be republished.'
    printf 'Push to origin? [y/N] '
    read -r reply
    case "$reply" in
      y | Y | yes | YES) ;;
      *)
        echo
        echo "Stopped. $tag is committed and tagged locally but not pushed."
        echo "  push later:  git push && git push origin $tag"
        echo "  undo:        git tag -d $tag && git reset --hard HEAD~1"
        exit 0
        ;;
    esac
  fi

  echo 'Pushing:'
  run git push
  run git push origin "$tag"

  echo
  if [ "$DRY_RUN" -eq 1 ]; then
    echo 'Dry run complete; nothing was changed.'
  else
    echo "Released $tag. Approve the pypi and dockerhub environments to publish:"
    echo "  $(git remote get-url origin | sed -e 's|git@github.com:|https://github.com/|' -e 's|\.git$||')/actions"
  fi
}

main "$@"
