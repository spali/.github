# Test helper: a fake `gh` on PATH.
#
# Every call is logged as one line ("$*") to $GH_LOG.
# Responses are registered with gh_respond '<glob>' <file|->: the first glob
# that matches the full argument string wins, its file is printed (use - to
# read the response from stdin). gh_fail '<glob>' <message> makes a matching
# call print the message to stderr and exit 1. Unmatched calls print nothing
# and succeed.

stub_gh() {
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export GH_RESPONSES="$BATS_TEST_TMPDIR/gh.responses"
  : >"$GH_LOG"
  : >"$GH_RESPONSES"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
while IFS=$'\t' read -r kind glob arg; do
  # shellcheck disable=SC2053 # glob match on purpose
  if [[ "$*" == $glob ]]; then
    if [[ $kind == fail ]]; then
      printf '%s\n' "$arg" >&2
      exit 1
    fi
    cat "$arg"
    exit 0
  fi
done <"$GH_RESPONSES"
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

gh_respond() {
  local glob=$1 file=$2
  if [[ $file == - ]]; then
    file=$(mktemp "$BATS_TEST_TMPDIR/response.XXXXXX")
    cat >"$file"
  fi
  printf 'respond\t%s\t%s\n' "$glob" "$file" >>"$GH_RESPONSES"
}

gh_fail() {
  printf 'fail\t%s\t%s\n' "$1" "$2" >>"$GH_RESPONSES"
}

# gh_calls prints the logged calls.
gh_calls() {
  cat "$GH_LOG"
}
