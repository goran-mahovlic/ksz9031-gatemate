#!/bin/bash
# Build a publishable copy of this repository's history.
#
#   ./scripts/prepare_public_history.sh [output-dir]
#
# Why this exists
# ---------------
# Commit f756400 removed the bench addresses from the working tree, but a
# commit only changes the tip. Every earlier version of scripts/flash.sh and
# scripts/test.sh still sits in history with the real addresses in it, and two
# commit messages still name the flash account and its NOPASSWD sudoers entry.
# `git log -p` on a public clone would hand all of that straight back.
#
# The same pass also drops the generated build output (build/, build_phase2..4),
# which is ~19 MB of the tree and shrinks the pack from 8.2 MiB to under 1 MiB.
#
# This script never touches your working repository. It clones it, rewrites the
# clone, verifies the result, and leaves it for you to inspect and push.
#
# Values to scrub are read from scripts/lab.env, which is git-ignored, so this
# script contains no addresses of its own.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
out="${1:-$HOME/.tmp/ksz9031-public}"

FILTER_REPO="$(command -v git-filter-repo || echo "$HOME/.local/bin/git-filter-repo")"
if [ ! -x "$FILTER_REPO" ]; then
    echo "ERROR: git-filter-repo not found. Install it, or pass its path in FILTER_REPO."
    exit 1
fi
if [ ! -f "$here/lab.env" ]; then
    echo "ERROR: $here/lab.env not found — it supplies the values to scrub."
    echo "       Copy scripts/lab.env.example and fill in the real bench values."
    exit 1
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# --- build the replacement list from lab.env -------------------------------
# Longest strings first: a short rule would otherwise chop up a longer one
# (replacing the account name first would mangle the sudoers path around it).
{
    # Every quoted value in lab.env is private by definition, so all of them are
    # scrubbed. Very short strings are skipped: they would match innocent text.
    grep -oE '"[^"]+"' "$here/lab.env" | tr -d '"' |
        awk 'length($0) >= 5 { print length, $0 }' | sort -rn | cut -d' ' -f2- |
        while read -r v; do echo "$v==><redacted-lab-value>"; done
    # bare host part of any user@host entry, and the account name on its own
    grep -oE '"[^"]+@[^"]+"' "$here/lab.env" | tr -d '"' |
        while IFS='@' read -r u h; do
            echo "$h==><redacted-lab-host>"
            echo "$u==><flash-account>"
        done
} | awk '!seen[$0]++' > "$work/replacements.txt"

echo "=== scrubbing $(wc -l < "$work/replacements.txt") distinct values ==="

# --- clone and rewrite ------------------------------------------------------
rm -rf "$out"
git clone --no-local --quiet "$repo" "$out"
before=$(git -C "$out" count-objects -vH | awk '/size-pack/{print $2, $3}')

"$FILTER_REPO" --force --source "$out" --target "$out" \
    --path-glob 'build/*' --path-glob 'build_phase2/*' \
    --path-glob 'build_phase3/*' --path-glob 'build_phase4/*' --invert-paths \
    --replace-text "$work/replacements.txt" \
    --replace-message "$work/replacements.txt" >/dev/null

after=$(git -C "$out" count-objects -vH | awk '/size-pack/{print $2, $3}')

# --- verify -----------------------------------------------------------------
echo "=== verifying rewritten history ==="
fail=0

leftover=$(git -C "$out" rev-list --all --objects | awk '{print $2}' | grep -cE '^build' || true)
[ "$leftover" -eq 0 ] && echo "  ok   no build artefacts remain" \
                      || { echo "  FAIL $leftover build paths remain"; fail=1; }

grep -oE '^[^=]+' "$work/replacements.txt" > "$work/needles.txt"

msgs=$(git -C "$out" log --all --format='%B' | grep -cFf "$work/needles.txt" || true)
[ "$msgs" -eq 0 ] && echo "  ok   no scrubbed value left in commit messages" \
                  || { echo "  FAIL $msgs commit-message lines still match"; fail=1; }

blobs=0
while read -r sha _; do
    [ "$(git -C "$out" cat-file -t "$sha" 2>/dev/null)" = "blob" ] || continue
    if git -C "$out" cat-file -p "$sha" 2>/dev/null | grep -qFf "$work/needles.txt"; then
        blobs=$((blobs+1))
    fi
done < <(git -C "$out" rev-list --all --objects)
[ "$blobs" -eq 0 ] && echo "  ok   no scrubbed value left in any blob, at any revision" \
                   || { echo "  FAIL $blobs blobs still contain a scrubbed value"; fail=1; }

# the published sources must still be byte-identical to what we have now
a=$(git -C "$out"  ls-tree -r HEAD | grep -v '	build' | sha1sum | cut -d' ' -f1)
b=$(git -C "$repo" ls-tree -r HEAD | grep -v '	build' | sha1sum | cut -d' ' -f1)
[ "$a" = "$b" ] && echo "  ok   source tree identical to local HEAD ($a)" \
                || { echo "  FAIL source tree differs: $a vs $b"; fail=1; }

echo
echo "pack size: $before  ->  $after"
echo "output:    $out"
if [ "$fail" -ne 0 ]; then
    echo "VERIFICATION FAILED — do not push this."
    exit 1
fi
cat <<EOF

Verification passed. Nothing has been pushed.

Review it yourself before publishing, e.g.:
    git -C "$out" log --stat | less
    git -C "$out" log -p -- scripts/flash.sh | less

Publishing rewrites the public branch, so it needs a force push:
    git -C "$out" remote add gh https://github.com/goran-mahovlic/ksz9031-gatemate.git
    git -C "$out" push --force gh HEAD:main

Because the SHAs change, anyone holding an old clone has to re-clone.
EOF
