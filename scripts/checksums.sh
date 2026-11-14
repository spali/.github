#!/usr/bin/env bash
# Writes <dir>/checksums.txt (sha256sum format) over all files in <dir>.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

dir=${1:-}
files=()
if [[ -d $dir ]]; then
  need_files "$dir"
  rm -f "$dir/checksums.txt"
  while IFS= read -r -d '' file; do
    files+=("$(basename "$file")")
  done < <(find "$dir" -maxdepth 1 -type f -print0 | sort -z)
fi
((${#files[@]})) || die "no release assets found in $dir"
(cd "$dir" && sha256sum -- "${files[@]}") >"$dir/checksums.txt.tmp"
mv "$dir/checksums.txt.tmp" "$dir/checksums.txt"
