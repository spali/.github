# Shared helpers, sourced by the other scripts.
# shellcheck shell=bash

# die prints "error: <msg>" to stderr and exits 1.
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# out writes a step output (key=value) to $GITHUB_OUTPUT, or to stdout
# when it is not set (local runs).
out() {
  printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT:-/dev/stdout}"
}

# need_env fails unless every named variable is non-empty.
need_env() {
  local name
  for name in "$@"; do
    [[ -n ${!name:-} ]] || die "$name is required"
  done
}
