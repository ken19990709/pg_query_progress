#!/usr/bin/env bash
#
# tools/audit_leak_check.sh -- leak audit for the public repository.
#
# The project was developed against local PostgreSQL build trees and an
# internal engineering record before being published.  This script greps
# the whole tree for tokens that would betray that origin: absolute paths,
# user names, internal port conventions, internal tool names, references to
# the internal engineering documents, and copyright lines that misattribute
# the work to the PostgreSQL project.  It is meant to run in CI and as a
# pre-release check; any hit blocks the merge.
#
# Usage:   tools/audit_leak_check.sh [tree-root]     (default: repo root)
# Exit:    0 = clean, 1 = hits found

set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

PATTERNS="$ROOT/tools/audit_patterns.txt"
STATUS=0

# --- 1. token audit (whole tree) -------------------------------------------
# Exclusions:
#   .git/            repository metadata
#   LICENSE          whitelisted: the PostgreSQL License text names the
#                    PostgreSQL Global Development Group by necessity
#   audit_patterns.txt, audit_leak_check.sh
#                    this audit itself necessarily spells out the patterns
grep -rEn -f "$PATTERNS" \
    --exclude-dir=.git \
    --exclude=LICENSE \
    --exclude=audit_patterns.txt \
    --exclude=audit_leak_check.sh \
    . && STATUS=1

# --- 2. copyright misattribution (code files only, LICENSE whitelisted) ----
grep -rEn "PostgreSQL Global Development Group" \
    --include='*.c' --include='*.h' --include='*.sql' \
    --include='*.sh' --include='*.control' --include='Makefile' \
    --exclude-dir=.git \
    --exclude=audit_leak_check.sh \
    . && STATUS=1

# --- 3. non-ASCII guard -----------------------------------------------------
# The tree is deliberately plain ASCII (bar glyphs in code are emitted via
# byte escapes; documentation uses ASCII art).  Any non-ASCII byte is most
# likely a leftover from a non-English internal note.
grep -rnP '[^\x00-\x7F]' \
    --exclude-dir=.git \
    --exclude=LICENSE \
    --exclude=audit_patterns.txt \
    --exclude=audit_leak_check.sh \
    . && STATUS=1

if [ "$STATUS" = "0" ]; then
    echo "audit: clean (0 hits)"
else
    echo "audit: HITS FOUND -- remove the internal references before committing"
fi
exit $STATUS
