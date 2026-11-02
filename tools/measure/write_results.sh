#!/usr/bin/env bash
# Writes the results of a measurement with tools/summarize.py.
#
#   tools/measure/write_results.sh --version v0.2.13 --jobs-dir <dir> --out <dir> --notes-file <file>
#       [--pilot-jobs <glob>]... [--pilot-balance <before.json> <after.json>]
#       [--attempt-jobs <benchmark>:<n>=<job>,<job>]... [--attempt-pilot-jobs <benchmark>:<n>=<job>,<job>]...
#       [--pilot-file <pilot.json>]... [--balance <label> <before.json> <after.json>]...
#       [--calibration]
#
# 1. With --pilot-jobs (shell globs of job names under --jobs-dir, e.g. "pilot-*"):
#    `summarize.py pilot` writes <out>/pilot/pilot.json from those jobs and prints its cut
#    helper. A matching job in which no trial finished (an interrupted run) is left out.
# 2. `summarize.py results` writes <out>/{summary.json,env.json,README.md,<benchmark>/attempt-<n>.json}
#    from the jobs <benchmark>-attempt-<n> and their reruns, with the balance readings
#    balance-attempt-<n>-{before,after}.json under --jobs-dir. With --pilot-jobs, attempt 1
#    is the pilot's trials of the final tasks (the v0.2.13 accounting, see attempt1_cost.py)
#    and pilot.json gives the pilot's cost; --pilot-balance names the readings around the
#    pilot.
#    With --attempt-jobs and --attempt-pilot-jobs instead (not with --pilot-jobs), each
#    attempt of each benchmark draws on exactly the jobs listed for it, attempt jobs or pilot
#    jobs (`summarize.py results --help`): this is how a calibration round combines the
#    measured trials of unchanged tasks, from their old jobs, with the new jobs of the new
#    tasks. --pilot-file adds a pilot.json to the pilot cost (repeatable). --balance adds a
#    labelled balance span (repeatable) and turns the balance-attempt-<n>-* lookup off.
#
# --notes-file holds the deviations and remarks for env.json and README.md, one per
# paragraph (blank-line separated; the lines of a paragraph are joined with single spaces).
# <out> must not exist yet, or be empty: the results are written whole.
#
# --calibration rewrites a measured <out> in place instead, keeping its first set: its
# current summary.json and README.md are copied to <out>/calibration/summary-first.json and
# README-first.md first (once: when both copies exist they are kept, and the current files
# are not copied again), then summary.json, env.json, README.md and every
# <benchmark>/attempt-<n>.json are replaced by the new ones. The new set is written to a
# temporary directory first, so a failure leaves <out> as it was; everything else in <out>
# (pilot/, calibration/, PILOT.md, REPRODUCE.md) stays. It does not take --pilot-jobs, which
# would overwrite pilot/pilot.json: write the calibration pilot with `summarize.py pilot
# --out <out>/calibration/pilot-<round>.json` and pass it with --pilot-file.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2; exit 2; }
die() { echo "write_results.sh: $*" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
absolute() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }

VERSION="" JOBS_DIR="" OUT="" NOTES_FILE="" CALIBRATION=0 LISTED=0
PILOT_GLOBS=() BALANCE=() EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION=${2:?}; shift 2 ;;
    --jobs-dir) JOBS_DIR=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    --notes-file) NOTES_FILE=${2:?}; shift 2 ;;
    --pilot-jobs) PILOT_GLOBS+=("${2:?}"); shift 2 ;;
    --pilot-balance) BALANCE=(--pilot-balance "$(absolute "${2:?}")" "$(absolute "${3:?}")"); shift 3 ;;
    --attempt-jobs|--attempt-pilot-jobs) EXTRA+=("$1" "${2:?}"); LISTED=1; shift 2 ;;
    --pilot-file) EXTRA+=(--pilot "$(absolute "${2:?}")"); shift 2 ;;
    --balance) EXTRA+=(--balance "${2:?}" "$(absolute "${3:?}")" "$(absolute "${4:?}")"); shift 4 ;;
    --calibration) CALIBRATION=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument $1" >&2; usage ;;
  esac
done
[ -n "$VERSION" ] && [ -n "$JOBS_DIR" ] && [ -n "$OUT" ] && [ -n "$NOTES_FILE" ] || usage
[ -d "$JOBS_DIR" ] || die "no such jobs dir: $JOBS_DIR"
[ -r "$NOTES_FILE" ] || die "cannot read the notes file: $NOTES_FILE"
JOBS_DIR=$(absolute "$JOBS_DIR") OUT=$(absolute "$OUT") NOTES_FILE=$(absolute "$NOTES_FILE")
if [ "${#PILOT_GLOBS[@]}" -gt 0 ] && [ "$LISTED" = 1 ]; then
  die "--pilot-jobs takes attempt 1 from the pilot for every benchmark; with --attempt-jobs, list it per benchmark with --attempt-pilot-jobs (and the pilot.json with --pilot-file)"
fi
KEEP_FIRST=0
if [ "$CALIBRATION" = 1 ]; then
  [ "${#PILOT_GLOBS[@]}" = 0 ] || die "--calibration keeps pilot/pilot.json: write the calibration pilot with summarize.py pilot and pass it with --pilot-file"
  [ -d "$OUT" ] || die "--calibration rewrites a measured results directory, and $OUT does not exist"
  FIRST="$OUT/calibration"
  if [ -e "$FIRST/summary-first.json" ] || [ -e "$FIRST/README-first.md" ]; then
    [ -f "$FIRST/summary-first.json" ] && [ -f "$FIRST/README-first.md" ] \
      || die "$FIRST holds only one of summary-first.json and README-first.md; restore the pair first"
  else
    [ -f "$OUT/summary.json" ] && [ -f "$OUT/README.md" ] || die "$OUT has no summary.json and README.md to keep as the first set"
    KEEP_FIRST=1
  fi
elif [ -e "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
  die "$OUT is not empty; results are written whole (--calibration rewrites a measured set in place)"
fi

NOTES=()
while IFS= read -r -d '' note; do NOTES+=(--note "$note"); done < <(python3 -c '
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
for paragraph in re.split(r"\n[ \t]*\n", text):
    if paragraph.strip():
        sys.stdout.write(" ".join(paragraph.split()) + "\0")' "$NOTES_FILE")

cd "$ROOT"
TARGET="$OUT"
if [ "$CALIBRATION" = 1 ]; then
  TARGET=$(mktemp -d "$OUT/.write-results.XXXXXX")
  trap 'rm -rf "$TARGET"' EXIT
else
  mkdir -p "$OUT"
fi
PILOT=()
if [ "${#PILOT_GLOBS[@]}" -gt 0 ]; then
  PILOT_DIRS=()
  shopt -s nullglob
  for pattern in "${PILOT_GLOBS[@]}"; do
    for dir in "$JOBS_DIR"/$pattern; do
      [ -d "$dir" ] || continue
      [[ " ${PILOT_DIRS[*]-} " == *" $dir "* ]] && continue
      finished=("$dir"/*/result.json)
      if [ "${#finished[@]}" = 0 ]; then echo "left out $(basename "$dir"): no finished trial" >&2; continue; fi
      PILOT_DIRS+=("$dir")
    done
  done
  shopt -u nullglob
  [ "${#PILOT_DIRS[@]}" -gt 0 ] || die "no pilot job matches ${PILOT_GLOBS[*]} under $JOBS_DIR"
  mkdir -p "$OUT/pilot"
  python3 tools/summarize.py pilot --out "$OUT/pilot/pilot.json" "${PILOT_DIRS[@]}"
  PILOT=(--pilot "$OUT/pilot/pilot.json" --attempt1-pilot "${PILOT_DIRS[@]}")
fi
python3 tools/summarize.py results --version "$VERSION" --jobs-dir "$JOBS_DIR" --out "$TARGET" \
  ${PILOT[@]+"${PILOT[@]}"} ${BALANCE[@]+"${BALANCE[@]}"} ${EXTRA[@]+"${EXTRA[@]}"} ${NOTES[@]+"${NOTES[@]}"}

if [ "$CALIBRATION" = 1 ]; then
  if [ "$KEEP_FIRST" = 1 ]; then
    mkdir -p "$OUT/calibration"
    cp -p "$OUT/summary.json" "$OUT/calibration/summary-first.json"
    cp -p "$OUT/README.md" "$OUT/calibration/README-first.md"
    echo "kept the first set as calibration/summary-first.json and calibration/README-first.md"
  else
    echo "calibration/summary-first.json and README-first.md already hold the first set; left as they are"
  fi
  rm -f "$OUT/summary.json" "$OUT/env.json" "$OUT/README.md"
  for dir in "$OUT"/*/; do
    bench=$(basename "$dir")
    [ -f "benchmarks/$bench/selection.json" ] || [ -f "data/$bench/selection.json" ] || continue
    rm -f "$dir"attempt-*.json
  done
  cp -R "$TARGET"/. "$OUT"/
  rm -rf "$TARGET"
  trap - EXIT
fi
find "$OUT" -type f | sort
