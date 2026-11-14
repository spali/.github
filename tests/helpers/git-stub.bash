# Test helper: a fake `git` on PATH.
#
# Every call is logged as one line ("$*") to $GIT_LOG.
# Responses are registered with git_respond '<glob>' <file|->: the first glob
# that matches the full argument string wins, its file is printed (use - to
# read the response from stdin). git_fail '<glob>' <message> makes a matching
# call print the message to stderr and exit 128. Unmatched calls print nothing
# and succeed.

stub_git() {
  export GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  export GIT_RESPONSES="$BATS_TEST_TMPDIR/git.responses"
  : >"$GIT_LOG"
  : >"$GIT_RESPONSES"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GIT_LOG"
while IFS=$'\t' read -r kind glob arg; do
  # shellcheck disable=SC2053 # glob match on purpose
  if [[ "$*" == $glob ]]; then
    if [[ $kind == fail ]]; then
      printf '%s\n' "$arg" >&2
      exit 128
    fi
    cat "$arg"
    exit 0
  fi
done <"$GIT_RESPONSES"
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

git_respond() {
  local glob=$1 file=$2
  if [[ $file == - ]]; then
    file=$(mktemp "$BATS_TEST_TMPDIR/response.XXXXXX")
    cat >"$file"
  fi
  printf 'respond\t%s\t%s\n' "$glob" "$file" >>"$GIT_RESPONSES"
}

git_fail() {
  printf 'fail\t%s\t%s\n' "$1" "$2" >>"$GIT_RESPONSES"
}
