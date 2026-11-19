# Test helper: real local git repositories for the sync scripts.
#
# repos_init creates two bare repositories, $UP (upstream) and $TG (target),
# both with default branch main, and exports UPSTREAM_URL/TARGET_URL as
# file:// URLs, WORK (an empty directory) and a fixed identity. Commits are
# built with plumbing in a scratch repository ($SCRATCH) and written to a
# bare repository with set_ref.
# shellcheck shell=bash

repos_init() {
  UP="$BATS_TEST_TMPDIR/upstream.git"
  TG="$BATS_TEST_TMPDIR/target.git"
  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  WORK="$BATS_TEST_TMPDIR/work"
  export UPSTREAM_URL="file://$UP" TARGET_URL="file://$TG" WORK
  export GIT_AUTHOR_NAME=author GIT_AUTHOR_EMAIL=author@example.com
  export GIT_COMMITTER_NAME=sync GIT_COMMITTER_EMAIL=sync@example.com
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  git init -q --bare -b main "$UP"
  git init -q --bare -b main "$TG"
  git init -q -b main "$SCRATCH"
  mkdir "$WORK"
}

# commit PARENT FILE CONTENT [MESSAGE] prints the sha of a new commit that
# writes CONTENT to FILE on top of PARENT (- for a root commit).
commit() {
  local parent=$1 file=$2 content=$3 msg=${4:-"$2: $3"} blob tree
  local -a p=()
  export GIT_INDEX_FILE="$BATS_TEST_TMPDIR/index"
  rm -f "$GIT_INDEX_FILE"
  if [[ $parent != - ]]; then
    git -C "$SCRATCH" read-tree "$parent"
    p=(-p "$parent")
  fi
  blob=$(printf '%s\n' "$content" | git -C "$SCRATCH" hash-object -w --stdin)
  git -C "$SCRATCH" update-index --add --cacheinfo "100644,$blob,$file"
  tree=$(git -C "$SCRATCH" write-tree)
  unset GIT_INDEX_FILE
  git -C "$SCRATCH" commit-tree "$tree" "${p[@]}" -m "$msg"
}

# atag NAME COMMIT prints the sha of a new annotated tag object.
atag() {
  git -C "$SCRATCH" tag -f -a -m "tag $1" "$1" "$2" >/dev/null
  git -C "$SCRATCH" rev-parse "refs/tags/$1"
}

# set_ref BARE REF SHA points REF of the bare repository at SHA (objects
# included).
set_ref() {
  git -C "$SCRATCH" push -q -f "$1" "$3:$2"
}

# del_ref BARE REF deletes REF of the bare repository.
del_ref() {
  git -C "$1" update-ref -d "$2"
}

# ref BARE REF prints the sha of REF in the bare repository.
ref() {
  git -C "$1" rev-parse "$2"
}

# plan_line REF prints the plan.tsv line of REF (fields 2-4).
plan_line() {
  awk -F'\t' -v r="$1" '$1 == r { print $2 "\t" $3 "\t" $4 }' "$WORK/plan.tsv"
}

# entry KIND [BRANCHES_JSON [FOLLOW_JSON [TAGS]]] exports ENTRY like
# fork_entry prints it (TAGS true or false, default true).
entry() {
  ENTRY=$(jq -nc --arg kind "$1" --argjson branches "${2:-[]}" \
    --argjson follow "${3:-[]}" --argjson tags "${4:-true}" \
    '{repo: "spali/t", upstream: "https://example.com/u/t.git", kind: $kind,
      upstream_repo: null, branches: $branches, follow: $follow, tags: $tags,
      settings: {}, private: false}')
  export ENTRY
}
