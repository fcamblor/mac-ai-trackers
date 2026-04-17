#!/usr/bin/env bash
# Verifies that the CLAUDE.md files passed as arguments are <= 250 lines.
# Called by gitdiff-watcher with {{ON_CHANGES_RUN_CHANGED_FILES}} separated by ','
#
# Usage: check-claude-md-lines.sh file1.md,file2.md,...

set -euo pipefail

MAX_LINES=250
ERRORS=0

if [[ $# -eq 0 ]] || [[ -z "$1" ]]; then
  exit 0
fi

IFS=',' read -ra FILES <<< "$1"

for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    continue
  fi

  line_count=$(wc -l < "$file")
  if [[ "$line_count" -gt "$MAX_LINES" ]]; then
    echo "ERROR: $file has $line_count lines (max $MAX_LINES). Extract content into .claude/rules/ or docs/."
    ERRORS=$((ERRORS + 1))
  fi
done

if [[ "$ERRORS" -gt 0 ]]; then
  exit 1
fi
