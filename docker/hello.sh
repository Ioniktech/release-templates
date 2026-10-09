#!/bin/sh
set -eu

printf 'Hello, %s!\n' "${1:-world}"
printf 'release-templates docker example, release %s\n' "${RELEASE:-dev}"
