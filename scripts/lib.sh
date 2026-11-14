# Shared helpers, sourced by the other scripts.
# shellcheck shell=bash

# die prints "error: <msg>" to stderr and exits 1.
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# out writes a step output (key=value) to $GITHUB_OUTPUT, or to stdout
# when it is not set (local runs). A newline would start another output.
out() {
  [[ $2 != *$'\n'* ]] || die "output $1 must be a single line"
  printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT:-/dev/stdout}"
}

# need_env fails unless every named variable is non-empty.
need_env() {
  local name
  for name in "$@"; do
    [[ -n ${!name:-} ]] || die "$name is required"
  done
}

# need_files fails if the directory contains a subdirectory (release assets
# are uploaded flat).
need_files() {
  local entry
  for entry in "$1"/*; do
    [[ ! -d $entry ]] || die "release assets must be files, $entry is a directory"
  done
}
