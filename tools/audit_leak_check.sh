#!/usr/bin/env bash
#
# tools/audit_leak_check.sh -- leak audit for the public repository.
#
# The project was developed against local PostgreSQL build trees and an
# internal engineering record before being published.  This script greps
# the tree for tokens that would betray that origin: absolute paths,
# user names, internal port conventions, internal tool names, references
# to the internal engineering documents, and copyright lines that
# misattribute the work to the PostgreSQL project.  It is meant to run
# in CI and as a pre-release check; any hit blocks the merge.
#
# Inside a git work tree only TRACKED files are scanned (transient test
# instances and their shimmed installs live under ignored paths and
# carry machine-local paths by design); outside one, the raw tree is
# scanned with the known transient paths excluded.
#
# Usage:   tools/audit_leak_check.sh [tree-root]     (default: repo root)
# Exit:    0 = clean, 1 = hits found

set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

PATTERNS="$ROOT/tools/audit_patterns.txt"
STATUS=0

EXCLUDES="--exclude-dir=.git --exclude=LICENSE \
--exclude=audit_patterns.txt --exclude=audit_leak_check.sh \
--exclude='*.o' --exclude='*.so' --exclude='*.dll' \
--exclude-dir=.bootstrap --exclude=.pgqp_env.sh"

if [ -d "$ROOT/.git" ] && command -v git > /dev/null 2>&1; then
    # tracked files only; grep -I skips binaries
    mapfile -t FILES < <(git ls-files -- . ':(exclude)LICENSE' \
        ':(exclude)tools/audit_patterns.txt' ':(exclude)tools/audit_leak_check.sh')
    if [ "${#FILES[@]}" -gt 0 ]; then
        grep -rEn -I -f "$PATTERNS" "${FILES[@]}" && STATUS=1
        CODEFILES=$(printf "%s\n" "${FILES[@]}" | grep -E '\.(c|h|sql|sh|control)$|^Makefile$')
        [ -n "$CODEFILES" ] && grep -En "PostgreSQL Global Development Group" $CODEFILES && STATUS=1
        grep -rnP -I '[^\x00-\x7F]' "${FILES[@]}" && STATUS=1
    fi
else
    # raw tree scan
    # shellcheck disable=SC2086
    grep -rEn -f "$PATTERNS" $EXCLUDES . && STATUS=1
    # shellcheck disable=SC2086
    grep -rEn "PostgreSQL Global Development Group" \
        --include='*.c' --include='*.h' --include='*.sql' \
        --include='*.sh' --include='*.control' --include='Makefile' \
        --exclude-dir=.git --exclude=audit_leak_check.sh \
        . && STATUS=1
    # shellcheck disable=SC2086
    grep -rnP '[^\x00-\x7F]' $EXCLUDES . && STATUS=1
fi

if [ "$STATUS" = "0" ]; then
    echo "audit: clean (0 hits)"
else
    echo "audit: HITS FOUND -- remove the internal references before committing"
fi
exit $STATUS
