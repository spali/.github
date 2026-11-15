# Test helper: a fake `gh` on PATH.
#
# Every call is logged as one line ("$*") to $GH_LOG. The file named by an
# --input argument is copied to $GH_INPUTS/<n> (n = line number in the log,
# so the body sent by call n is $GH_INPUTS/n) and the GH_TOKEN of each call
# is logged to $GH_TOKENS.
# Responses are registered with gh_respond '<glob>' <file|->: the first glob
# that matches the full argument string wins, its file is printed (use - to
# read the response from stdin). gh_fail '<glob>' <message> makes a matching
# call print the message to stderr and exit 1. Unmatched calls print nothing
# and succeed.

stub_gh() {
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export GH_RESPONSES="$BATS_TEST_TMPDIR/gh.responses"
  export GH_INPUTS="$BATS_TEST_TMPDIR/gh.inputs"
  export GH_TOKENS="$BATS_TEST_TMPDIR/gh.tokens"
  mkdir -p "$GH_INPUTS"
  : >"$GH_LOG"
  : >"$GH_TOKENS"
  : >"$GH_RESPONSES"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
printf '%s\n' "${GH_TOKEN:-}" >>"$GH_TOKENS"
args=("$@")
for i in "${!args[@]}"; do
  if [[ ${args[$i]} == --input ]]; then
    cp "${args[$((i + 1))]}" "$GH_INPUTS/$(wc -l <"$GH_LOG")"
  fi
done
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
