#!/usr/bin/env bash
# canary-rollout.sh (lib) — pure decision core for the ring-staged, health-gated
# promotion of agent releases (initiative #495, issue #501; rollback/observability #502).
#
# This file is side-effect-free and `source`-able: it defines pure functions only
# (no I/O, no gh/git calls) so the gate logic can be unit-tested deterministically.
# The orchestrator scripts/canary-rollout.sh sources this and feeds it real numbers
# gathered from `gh`.
#
# Gate standard: .github#548 (definitive spec). Per transition, evaluate on the
# SOURCE tier (the tier currently running the candidate), counting EXECUTED runs
# (success+failure; skipped/cancelled excluded) since the candidate's OWN cut:
#   - next->ring0:   dwell >= 4h  + sample >= clamp(round(0.25·avg), 3, 15)
#                    (dwell-only when the source tier has no caller)
#   - ring0->ring1:  dwell >= 8h  + CUMULATIVE-HEALTH-ONLY (fresh sample WAIVED)
#   - ring1->stable: dwell >= 12h + >= 1 ring1 run
#   - ALWAYS:        cumulative health = ZERO failures / ZERO startup_failures
#                    across EVERY tier since the candidate's own first cut.
# The dwell floors and sample fractions are registry-configurable per transition
# (see standards/canary-rings.json .gate); the numbers above are the defaults.

# clamp <value> <lo> <hi> — echo value bounded to [lo, hi].
clamp() {
  local v="$1" lo="$2" hi="$3"
  if [ "$v" -lt "$lo" ]; then echo "$lo"; return 0; fi
  if [ "$v" -gt "$hi" ]; then echo "$hi"; return 0; fi
  echo "$v"
}

# round_div <numerator> <denominator> — integer half-up rounding of n/d.
# Denominator must be > 0. Pure arithmetic, no bc.
round_div() {
  local n="$1" d="$2"
  if [ "${d:-0}" -le 0 ]; then echo 0; return 1; fi
  echo $(( (2 * n + d) / (2 * d) ))
}

# median_x2 <nums...> — echo 2×median as an exact integer (so an even-length set's
# half-integer median stays exact). Empty set → 0.
median_x2() {
  local n=$#
  [ "$n" -eq 0 ] && { echo 0; return 0; }
  local sorted
  sorted=$(printf '%s\n' "$@" | sort -n)
  local arr=()
  local x
  while IFS= read -r x; do arr+=("$x"); done <<< "$sorted"
  local mid=$(( n / 2 ))
  if [ $(( n % 2 )) -eq 1 ]; then
    echo $(( 2 * arr[mid] ))
  else
    echo $(( arr[mid - 1] + arr[mid] ))
  fi
}

# robust_sample_target <fraction_permille> <clamp_lo> <clamp_hi> <cap_multiple> <daily_counts...>
# Robust baseline: cap each per-day executed count at <cap_multiple>× the median day (default
# 3×, neutralising spikes like a runaway loop day), take the mean of the capped days, then the sample
# target = clamp(round(fraction · avg), lo, hi). fraction is in per-mille (250 == 0.25).
#
# All arithmetic stays exact in integers by working in "×2" units for the median:
#   capped_x2(c) = min(2c, 3·median_x2)     [3·median compared without rounding]
#   avg          = (Σ capped_x2) / (2·N)
#   target_raw   = round(fraction/1000 · avg) = round(fraction·Σcapped_x2 / (2000·N))
robust_sample_target() {
  local frac="$1" lo="$2" hi="$3" cap_multiple="${4:-3}"; shift 4
  local n=$#
  [ "$n" -eq 0 ] && { clamp 0 "$lo" "$hi"; return 0; }
  local m2 cap3 c c2 sum2=0
  m2=$(median_x2 "$@")
  cap3=$(( cap_multiple * m2 ))
  for c in "$@"; do
    c2=$(( 2 * c ))
    [ "$c2" -gt "$cap3" ] && c2=$cap3
    sum2=$(( sum2 + c2 ))
  done
  # target_raw = round( frac · sum2 / (2000·n) )
  local denom=$(( 2000 * n )) target_raw
  target_raw=$(round_div $(( frac * sum2 )) "$denom")
  clamp "$target_raw" "$lo" "$hi"
}

# ── version-bump math (autocut front end, #1069) ──────────────────────────────
# Pure semver helpers used by `canary-rollout.sh autocut` to compute the next
# immutable release version from the highest existing <agent>/vX.Y.Z on the host.

# bump_version <version> <patch|minor|major> — echo MAJOR.MINOR.PATCH bumped by one
# level. Unknown/absent level defaults to patch (the v1 default). Input must be a
# strict MAJOR.MINOR.PATCH; callers validate the tag before calling.
bump_version() {
  local ver="$1" level="${2:-patch}" major=0 minor=0 patch=0
  IFS=. read -r major minor patch <<< "$ver"
  case "$level" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    *)     echo "${major}.${minor}.$((patch + 1))" ;;
  esac
}

# ── breaking-change classification (autocut major-awareness, #712, epic #1083) ──
# The autocut front end decides the release bump from SIGNALS (a breaking change → major,
# a non-breaking feat → minor, else patch), with the manual `.agents[a].autocut.bump` knob
# kept as an explicit override. These pure cores make that decision unit-testable; the
# orchestrator gathers the raw signals (commit messages, workflow_call interface) and feeds
# them in.

# decide_bump <breaking:0|1> <feat:0|1> <override> — echo the semver bump level. An explicit
# <override> in {major,minor,patch} ALWAYS wins (back-compat / manual force); otherwise a
# breaking signal → major, a feat signal → minor, and neither → patch.
decide_bump() {
  local breaking="${1:-0}" feat="${2:-0}" override="${3:-}"
  case "$override" in major|minor|patch) echo "$override"; return 0 ;; esac
  if [ "$breaking" = 1 ]; then echo major; return 0; fi
  if [ "$feat" = 1 ]; then echo minor; return 0; fi
  echo patch
}

# ── promotion tag-write failure streak (#1023 defect 2) ────────────────────────
# A FAILED tag write (a permission/API rejection on the promote move) is UNEXPECTED — distinct
# from an EXPECTED gate-block. The orchestrator persists each failure to a sibling log and, on
# each scheduled tick, feeds the per-agent outcome through these pure cores to decide when a
# repeatedly-failing write should escalate to a durable blocker issue. Kept side-effect-free so
# the escalation threshold logic is unit-tested without touching GitHub.

# promotion_failure_next_count <prior_count> <outcome:failed|ok> — the new CONSECUTIVE-failure
# streak: a `failed` write increments the prior count by one; any other outcome (a successful
# write, or no attempt resolved to `ok`) RESETS the streak to 0. A non-numeric prior is treated
# as 0 (a fresh/garbled marker never blocks escalation from restarting cleanly).
promotion_failure_next_count() {
  local prior="$1" outcome="$2"
  case "$prior" in ''|*[!0-9]*) prior=0 ;; esac
  case "$outcome" in
    failed) echo $((prior + 1)) ;;
    *)      echo 0 ;;
  esac
}

# promotion_failure_should_escalate <count> <threshold> — echo 1 iff the consecutive-failure
# <count> has reached the escalation <threshold> (N consecutive failing runs), else 0. A
# threshold below 1 is clamped to 1 (escalate on the first failure); non-numeric input → 0.
promotion_failure_should_escalate() {
  local count="$1" threshold="$2"
  case "$count" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  case "$threshold" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  [ "$threshold" -lt 1 ] && threshold=1
  if [ "$count" -ge "$threshold" ]; then echo 1; else echo 0; fi
}

# ── autocut pagination termination (#1023) ────────────────────────────────────

# commit_page_done <found> <count> <per_page> — return 1 (done/stop) when the boundary commit was
# found OR when the page is short (fewer commits returned than per_page, meaning no further pages
# exist), else return 0 (keep paginating). Pure: no I/O, unit-testable.
commit_page_done() {
  local found="$1" count="${2:-0}" per_page="${3:-100}"
  if [ "$found" = "true" ] || [ "$count" -lt "$per_page" ]; then return 1; fi
  return 0
}

# workflow_call_iface <yaml_text> — parse a reusable workflow's `on.workflow_call` block into
# a normalized, sorted interface descriptor (one item per line), for a set-comparison diff:
#   input <name> <required 0|1>
#   secret <name>
# Outputs are intentionally omitted: a new output is not breaking and a removed output is out
# of scope for #712, so they never drive the verdict. Pure: a deterministic awk transform over
# the text (no gh/git/network I/O), tolerant of comments and standard 2-space GitHub indent.
workflow_call_iface() {
  tr -d '\r' <<< "$1" | awk '
    function ind(s){ match(s, /^ */); return RLENGTH }
    { raw = $0 }
    raw ~ /^[[:space:]]*($|#)/ { next }                                   # blank / comment
    { i = ind(raw) }
    raw ~ /^[[:space:]]*workflow_call:[[:space:]]*(#.*)?$/ { inwc=1; wci=i; sec=""; seci=-1; keyi=-1; next }
    (inwc && i <= wci) { inwc=0 }                                         # left workflow_call block
    !inwc { next }
    raw ~ /^[[:space:]]*inputs:[[:space:]]*(#.*)?$/  { sec="input";  seci=i; keyi=-1; next }
    raw ~ /^[[:space:]]*secrets:[[:space:]]*(#.*)?$/ { sec="secret"; seci=i; keyi=-1; next }
    raw ~ /^[[:space:]]*outputs:[[:space:]]*(#.*)?$/ { sec="output"; seci=i; keyi=-1; next }
    (sec != "" && i <= seci) { sec="" }                                  # left the section
    sec == "" { next }
    {
      if (keyi == -1) keyi = i
      if (i == keyi) {
        name = raw; sub(/^[[:space:]]*/, "", name); sub(/:.*/, "", name)
        cur = name
        if (sec == "input")  { inp[cur]=1; if (!(cur in req)) req[cur]=0 }
        else if (sec == "secret") { seclist[cur]=1 }
      } else if (i > keyi && sec == "input") {
        if (raw ~ /^[[:space:]]*required:[[:space:]]*true[[:space:]]*(#.*)?$/) req[cur]=1
      }
    }
    END {
      for (n in inp)     print "input "  n " " (req[n] ? 1 : 0)
      for (n in seclist) print "secret " n
    }
  ' | sort
}

# interface_break <old_desc> <new_desc> — echo 1 if the change from <old_desc> to <new_desc>
# (both workflow_call_iface descriptors) is a BREAKING interface change, else 0. Breaking iff:
#   - an input or secret present in OLD is absent in NEW (removed or renamed), OR
#   - an input is required:true in NEW but was not required:true in OLD (newly-added-required
#     or optional→required flip).
# Added-optional inputs and relaxing required→optional are NOT breaking. Pure: bash only.
interface_break() {
  local old="$1" new="$2" kind name req key
  local -A new_has=() old_has=() new_input_req=() old_input_req=()
  while read -r kind name req || [ -n "$kind" ]; do
    [ -z "$kind" ] && continue
    kind="${kind%$'\r'}"; name="${name%$'\r'}"; req="${req%$'\r'}"
    new_has["$kind/$name"]=1
    [ "$kind" = input ] && new_input_req["$name"]="${req:-0}"
  done <<< "$new"
  while read -r kind name req || [ -n "$kind" ]; do
    [ -z "$kind" ] && continue
    kind="${kind%$'\r'}"; name="${name%$'\r'}"; req="${req%$'\r'}"
    old_has["$kind/$name"]=1
    [ "$kind" = input ] && old_input_req["$name"]="${req:-0}"
  done <<< "$old"
  for key in "${!old_has[@]}"; do
    if [ -z "${new_has[$key]:-}" ]; then echo 1; return 0; fi   # removed / renamed
  done
  for name in "${!new_input_req[@]}"; do
    if [ "${new_input_req[$name]}" = 1 ] && [ "${old_input_req[$name]:-x}" != 1 ]; then
      echo 1; return 0                                          # newly-required input
    fi
  done
  echo 0
}

# _semver_gt <a> <b> — return 0 iff semver a is strictly greater than b (compared
# by major, then minor, then patch). Equal is NOT greater.
_semver_gt() {
  local a1=0 a2=0 a3=0 b1=0 b2=0 b3=0
  IFS=. read -r a1 a2 a3 <<< "$1"
  IFS=. read -r b1 b2 b3 <<< "$2"
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return $?; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return $?; fi
  [ "$a3" -gt "$b3" ]
}

# max_semver <version...> — echo the highest strict MAJOR.MINOR.PATCH among the
# args, ignoring any token that is not a strict semver. Empty if none are valid.
max_semver() {
  local v hi=""
  for v in "$@"; do
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [ -z "$hi" ] || _semver_gt "$v" "$hi"; then hi="$v"; fi
  done
  echo "$hi"
}

# major_component <version> — echo the MAJOR of a strict MAJOR.MINOR.PATCH, empty
# otherwise. Pure. Used (major-scoped-channels epic #657, Phase F4) to derive an
# agent's current major line from its highest vX.Y.Z release for v-form tagging.
major_component() {
  if [[ "$1" =~ ^([0-9]+)\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# _is_release_tag_suffix <suffix> — return 0 iff <suffix> (a tag name with the
# leading "<agent>/" already stripped, e.g. "v139.4.0") is an immutable release tag:
# a "v" followed by a strict MAJOR.MINOR.PATCH. Pure. This is the filter that keeps the
# candidate-cut-date resolution from mistaking a v-scoped channel tag "v<M>-<tier>"
# (a lightweight ref that shadows the release, sorting earlier) for the release tag,
# which returned an empty cut date and wedged the gate at BLOCKED indeterminate (#1046).
_is_release_tag_suffix() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# channel_tag <agent> <tier> [major] — build a channel tag name. With a MAJOR the
# v-scoped form `<agent>/v<major>-<tier>` (mirrors ring_canonical_ref in
# ring-pins.sh); without it the legacy bare `<agent>/<tier>`. Pure. (Epic #657 F4.)
channel_tag() {
  local agent="$1" tier="$2" major="${3:-}"
  if [ -n "$major" ]; then printf '%s/v%s-%s' "$agent" "$major" "$tier"
  else printf '%s/%s' "$agent" "$tier"; fi
}

# _looks_like_oid <s> — return 0 iff <s> is a bare git object id (7–64 lowercase hex). Pure.
_looks_like_oid() { [[ "$1" =~ ^[0-9a-f]{7,64}$ ]]; }

# dwell_met <dwell_hours> <floor_hours> — echo 1 if the candidate has dwelled at
# least floor_hours on the source tier, else 0.
dwell_met() {
  local dwell="${1:-0}" floor="${2:-0}"
  if [ "$dwell" -ge "$floor" ]; then echo 1; else echo 0; fi
}

# iso_after <a> <b> — echo "yes" if ISO-8601 UTC timestamp a is at or after b, else
# "no". Zulu ISO-8601 strings sort lexically, so a per-candidate window is a string
# comparison against the candidate's cut date (excludes pre-cut runs of prior versions).
iso_after() {
  local a="$1" b="$2"
  if [[ "$a" > "$b" || "$a" == "$b" ]]; then echo "yes"; else echo "no"; fi
}

# decide_graduated <dwell_h> <dwell_floor> <sample> <sample_target> <sample_waived> \
#                  <cum_failures> <cum_startup_failures>
# Pure graduated gate for one transition. Echoes exactly one of:
#   BLOCKED — cumulative health breached (>=1 failure or startup_failure across any
#             tier since the candidate's cut). Never advances; a human/triage
#             classifies it as REGRESSION (rollback) or PRE_EXISTING (report only).
#   PROMOTE — clean AND dwell floor met AND (sample target met OR sample waived).
#   SOAKING — clean but dwell floor or sample target not yet met → wait.
# Health is checked first: a cumulative breach is never masked by dwell/sample.
decide_graduated() {
  local dwell="${1:-0}" floor="${2:-0}" sample="${3:-0}" target="${4:-0}"
  local waived="${5:-false}" cum_fail="${6:-0}" cum_startup="${7:-0}"
  if [ "$cum_fail" -gt 0 ] || [ "$cum_startup" -gt 0 ]; then
    echo "BLOCKED"; return 0
  fi
  local dwell_ok sample_ok
  dwell_ok=$(dwell_met "$dwell" "$floor")
  if [ "$waived" = "true" ] || [ "$sample" -ge "$target" ]; then sample_ok=1; else sample_ok=0; fi
  if [ "$dwell_ok" -eq 1 ] && [ "$sample_ok" -eq 1 ]; then
    echo "PROMOTE"; return 0
  fi
  echo "SOAKING"
}

# classify_failure <reusable_differs 0|1> <category> [suspect_match 0|1] — triage an
# in-window failure (called only when decide_graduated returns BLOCKED). Echoes:
#   REGRESSION   — the candidate changed the reusable (differs=1) AND the failure is
#                  not a known environmental class and not a suspect class → HALT,
#                  auto-hold, recommend rollback.
#   SUSPECT      — the candidate changed the reusable (differs=1) AND the failure matches
#                  a `suspect_failure_classes` entry (#668 increment 2): a possibly-
#                  candidate-caused class (e.g. an exit-124 workload timeout) that COULD be
#                  a real regression, so it still BLOCKS + needs a human — but carries a
#                  per-class discriminating question so the human confirm is fast. Unlike a
#                  `version_independent` benign class it is NOT auto-cleared.
#   PRE_EXISTING — the reusable is byte-identical to the prior channel (differs=0), OR
#                  the failure is environmental (comment-cap / rate-limit / infra / data)
#                  → report, do NOT rollback, do NOT advance.
# Precedence: environmental category first, then differs=0 (can't be candidate-caused),
# then a suspect match narrows an otherwise-REGRESSION verdict to SUSPECT.
classify_failure() {
  local differs="${1:-0}" category="${2:-unknown}" suspect="${3:-0}"
  case "$category" in
    comment-cap|rate-limit|infra|data) echo "PRE_EXISTING"; return 0 ;;
  esac
  if [ "$differs" != "1" ]; then echo "PRE_EXISTING"; return 0; fi
  if [ "$suspect" -gt 0 ]; then echo "SUSPECT"; else echo "REGRESSION"; fi
}

# decide_suspect_downgrade <cand_rate_permille> <base_rate_permille> <base_sample> <knobs_json>
# Pure SUSPECT→PRE_EXISTING auto-downgrade core (#668 increment 6, optional 1c). Applied by the
# orchestrator AFTER classify_failure returns SUSPECT (so the verdict core stays small and
# unit-testable), for a suspect class that opts into `auto_downgrade`. Rates are per-mille failure
# rates of the SAME suspect class: the candidate's over its in-window runs vs the prior version's
# over the trailing baseline window. Echoes exactly one of:
#   DOWNGRADE — the baseline has enough data (base_sample >= min_baseline_sample) AND the candidate
#               is no worse than the baseline for this class (cand_rate <= base_rate + margin_permille)
#               → the failure is environmental, not a candidate regression; the caller re-triages it
#               PRE_EXISTING (report-only).
#   HOLD      — thin baseline (base_sample < min_baseline_sample: NEVER downgrade on tiny-n — the
#               conservative default keeps the human) OR the candidate is materially worse
#               (cand_rate > base_rate + margin_permille) → stay SUSPECT (increment 2 behaviour).
# Knobs object {min_baseline_sample, margin_permille}; absent knobs default to 0 (margin 0 = strict
# no-worse; min_baseline_sample 0 = no tiny-n guard, though the orchestrator always sets it).
decide_suspect_downgrade() {
  local cand="${1:-0}" base="${2:-0}" base_sample="${3:-0}" knobs="$4"
  [ -z "$knobs" ] && knobs='{}'
  local min_base margin
  min_base="$(jq -r '.min_baseline_sample // 0' <<< "$knobs" 2>/dev/null || echo 0)"
  margin="$(jq -r '.margin_permille // 0' <<< "$knobs" 2>/dev/null || echo 0)"
  case "$min_base" in ''|*[!0-9]*) min_base=0 ;; esac
  case "$margin" in ''|*[!0-9]*) margin=0 ;; esac
  # Tiny-n guard first: too little baseline data → keep the human (conservative), regardless of rate.
  if [ "$base_sample" -lt "$min_base" ]; then echo "HOLD"; return 0; fi
  if [ "$cand" -le $(( base + margin )) ]; then echo "DOWNGRADE"; return 0; fi
  echo "HOLD"
}

# benign_match <workflow_name> <failure_signature> <workflow_regex> <step_regex>
# Decide whether ONE in-window failure matches ONE known-benign failure-class allowlist
# entry (#1025 P2). A match requires a non-empty <step_regex> (guards against a match-all
# entry) that matches the failure signature (the failed step/error names), AND — when
# <workflow_regex> is non-empty — the run's workflow name. Echoes "yes" or "no".
# Pure: bash ERE only, no I/O. (Author regexes with explicit char classes, e.g. [Pp]ush,
# since ERE has no inline case-insensitivity flag.)
benign_match() {
  local wf="$1" sig="$2" wf_re="$3" step_re="$4"
  [ -z "$step_re" ] && { echo "no"; return 0; }
  if [ -n "$wf_re" ] && ! [[ "$wf" =~ $wf_re ]]; then echo "no"; return 0; fi
  if [[ "$sig" =~ $step_re ]]; then echo "yes"; else echo "no"; fi
}

# _is_evicted_run <conclusion> <completed_step_count> — pure classifier for a
# concurrency-EVICTED run (#1047, wired by slice 2 #1054). Returns 0 (IS an
# eviction — not evidence either way) iff <conclusion> is exactly "cancelled" AND
# <completed_step_count> is exactly 0: a `cancel-in-progress: true` preemption on
# the reusable's per-issue/per-PR lane (#402) that ran no candidate code and so
# cannot be evidence of a regression. Returns non-zero in EVERY other case —
# `cancelled` with a non-zero step count (a human cancelling mid-flight, genuinely
# ambiguous and NOT to be laundered into "benign"), any other conclusion, and a
# missing/empty/non-numeric count. Fail closed: when in doubt it is NOT an eviction,
# so the gate keeps counting it. Discriminates on the completed-step count, not on
# conclusion alone. Emits nothing; sourced under `set -euo pipefail`, so it returns
# and never exits.
_is_evicted_run() {
  [ "$#" -ge 2 ] || return 1
  local conclusion="$1" count="$2"
  [ "$conclusion" = "cancelled" ] || return 1
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  [ "$count" -eq 0 ]
}

# next_channel_in_order <current_channel> <ordered_channels_csv>
# Given the frontier channel and the ordered channel list (e.g. "next,ring0,ring1,stable"),
# echo the channel that a PROMOTE advances next, or empty if already at the last ring.
next_channel_in_order() {
  local current="$1" csv="$2"
  local prev="" ch found=""
  local chan_array=()
  IFS=, read -r -a chan_array <<< "$csv"
  for ch in "${chan_array[@]}"; do
    if [ "$prev" = "$current" ]; then found="$ch"; break; fi
    prev="$ch"
  done
  echo "$found"
}

# transition_key <frontier_channel> <ordered_channels_csv>
# Echo the per-transition registry key "<source>-><frontier>", where source is the
# ring immediately below the frontier in ring order (the tier running the candidate).
# Empty if the frontier is the first channel (no source below it).
transition_key() {
  local frontier="$1" csv="$2"
  local prev="" ch
  local chan_array=()
  IFS=, read -r -a chan_array <<< "$csv"
  for ch in "${chan_array[@]}"; do
    if [ "$ch" = "$frontier" ] && [ -n "$prev" ]; then echo "${prev}->${frontier}"; return 0; fi
    prev="$ch"
  done
  echo ""
}

# ── set-diff core (drift detection, #1082) ────────────────────────────────────
# The registry (.agents{}) is the MANUAL source of truth for what the canary pipeline
# manages; drift detection diffs it against the *-reusable.yml actually present on each
# host. Both sides of that diff are a plain set difference over whole-line strings.

# set_difference <set_a_newlines> <set_b_newlines> — echo each line of A that is NOT
# present in B (whole-line match; order + duplicates of A preserved, blank lines dropped).
# Pure: bash only (associative-array lookup), no gh/git I/O — deterministically unit-testable.
set_difference() {
  local a="$1" b="$2" line
  declare -A b_map
  while IFS= read -r line; do
    [ -n "$line" ] && b_map["$line"]=1
  done <<< "$b"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [[ -z "${b_map["$line"]:-}" ]]; then
      printf '%s\n' "$line"
    fi
  done <<< "$a"
}

# ── watched agent_ref paths (autocut/drift ship detection, #1019) ─────────────
# A consumer executes MORE than the reusable workflow at its pinned channel tag: the reusable
# checks out scripts/ (and prompts/, personas/) at `agent_ref`. Autocut previously compared only
# the reusable FILE blob, so a script-only change shipped nowhere. These pure cores decide, from
# a list of files changed between two commits and the set of watched paths, whether anything a
# consumer executes changed — powering both the autocut cut decision and the drift "merged but
# not shipped" report.

# watched_hits <changed_files_nl> <patterns_nl> — echo each watched pattern (in the given order,
# at most once) that at least one changed file is covered by. A pattern ending in "/" matches by
# directory prefix; otherwise it matches an exact file OR a file nested under it ("<pattern>/…").
# Pure: bash only, no I/O — deterministically unit-testable.
watched_hits() {
  local files="$1" patterns="$2" p f
  local -a pats=()
  while IFS= read -r p; do [ -n "$p" ] && pats+=("$p"); done <<< "$patterns"
  [ "${#pats[@]}" -eq 0 ] && return 0
  for p in "${pats[@]}"; do
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      case "$p" in
        */) if [ "${f#"$p"}" != "$f" ]; then printf '%s\n' "$p"; break; fi ;;
        *)  if [ "$f" = "$p" ] || [ "${f#"$p"/}" != "$f" ]; then printf '%s\n' "$p"; break; fi ;;
      esac
    done <<< "$files"
  done
}

# any_watched_change <changed_files_nl> <patterns_nl> — echo 1 if any changed file is covered by
# any watched pattern, else 0. Thin wrapper over watched_hits (DRY).
any_watched_change() {
  if [ -n "$(watched_hits "$1" "$2")" ]; then echo 1; else echo 0; fi
}

# gate_summary_line <transition> <state> <dwell_h> <dwell_floor> <sample> <sample_target> <cum_fail> <cum_startup> [cum_benign]
# One-line human/observability row (used by `evaluate`, doubling as the #502 report).
# cum_benign (allowlisted failures excluded from cum_fail) is shown when provided.
gate_summary_line() {
  printf '%-14s %-9s dwell=%sh/%sh  sample=%s/%s  cum_fail=%s startup=%s benign=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${9:-0}"
}

# ── decision telemetry: gross decision-mix shift (#668 Layer 2, increment 4) ────
# A canary doesn't need the *right* answer — it needs to detect the candidate answering
# DIFFERENTLY than the incumbent on comparable traffic. Both #668 pathologies (dispatching
# when it shouldn't; never dispatching) are DISTRIBUTION pathologies: a decision class's
# share swings toward ~100% or ~0% vs a stable-tier baseline. These pure cores tally the
# decision mix (from emitted `decision: <class>` step names) and decide a gross shift.
# jq is used as a pure, deterministic transform only — no gh/git/network I/O.

# decision_class <prefix> <run_jobs_json> — the decision class a run TOOK: the first step
# whose name starts with <prefix> AND did not skip (conclusion != "skipped"), with the prefix
# stripped. <run_jobs_json> is the `gh run view --json jobs` payload; non-`<prefix>` and
# skipped steps are ignored (the reusable emits one `decision: <class>` no-op step per outcome
# branch, only the taken branch runs). Empty when no decision step ran (absent/unparseable).
decision_class() {
  local prefix="$1" json="$2"
  [ -z "$json" ] && json='{}'
  jq -r --arg p "$prefix" '
    [ (.jobs[]?.steps[]?)
      | select((.conclusion // "") != "skipped")
      | (.name // "")
      | select(startswith($p))
      | .[($p|length):] ]
    | .[0] // ""
  ' <<< "$json" 2>/dev/null || echo ""
}

# decide_decision_shift <cand_counts_json> <base_counts_json> <knobs_json> — gate the
# candidate's decision mix against a prior-version baseline. Counts are objects of
# decision-class → run count, e.g. {"dispatched":6,"skip-draft":4}. Knobs:
#   {min_candidate_sample, min_baseline_sample, max_shift_permille}. Echoes exactly one of:
#   INSUFFICIENT — either side is below its min, or a side is empty/unparseable (no decision
#                  steps produced) → NO EFFECT: the caller degrades to reliability-only, so a
#                  low-traffic agent never stalls on a signal it cannot produce.
#   SHIFT        — some decision class's share (per-mille of that side's total) moved by at
#                  least max_shift_permille between candidate and baseline → HOLD (SUSPECT).
#   OK           — every class's share is within threshold → no effect.
# Shares are integer per-mille, rounded half-up; the max absolute per-class delta is compared
# to max_shift_permille (inclusive). Gross always/never/gross shifts only — by design (n=10–25).
decide_decision_shift() {
  local cand="$1" base="$2" knobs="$3"
  [ -z "$cand" ] && cand='{}'
  [ -z "$base" ] && base='{}'
  [ -z "$knobs" ] && knobs='{}'
  local min_c min_b max_shift
  min_c="$(jq -r '.min_candidate_sample // 0' <<< "$knobs" 2>/dev/null || echo 0)"
  min_b="$(jq -r '.min_baseline_sample // 0' <<< "$knobs" 2>/dev/null || echo 0)"
  max_shift="$(jq -r '.max_shift_permille // 0' <<< "$knobs" 2>/dev/null || echo 0)"
  local cand_total base_total
  cand_total="$(jq -r 'if type=="object" then ([.[]?]|add // 0) else "x" end' <<< "$cand" 2>/dev/null || echo x)"
  base_total="$(jq -r 'if type=="object" then ([.[]?]|add // 0) else "x" end' <<< "$base" 2>/dev/null || echo x)"
  # Unparseable / non-object / empty → INSUFFICIENT (no decision steps to compare).
  case "$cand_total" in ''|*[!0-9]*) echo "INSUFFICIENT"; return 0 ;; esac
  case "$base_total" in ''|*[!0-9]*) echo "INSUFFICIENT"; return 0 ;; esac
  if [ "$cand_total" -lt "$min_c" ] || [ "$base_total" -lt "$min_b" ]; then
    echo "INSUFFICIENT"; return 0
  fi
  if [ "$cand_total" -eq 0 ] || [ "$base_total" -eq 0 ]; then
    echo "INSUFFICIENT"; return 0
  fi
  # Max absolute per-class share delta, in integer per-mille (round half-up), over the union
  # of decision classes seen on either side (a class absent on one side counts as 0 there).
  local max_delta
  max_delta="$(jq -nr --argjson c "$cand" --argjson b "$base" \
    --argjson ct "$cand_total" --argjson bt "$base_total" '
    (($c|keys) + ($b|keys) | unique) as $classes
    | [ $classes[]
        | ((( ($c[.]//0)*1000 + ($ct/2) ) / $ct) | floor) as $cs
        | ((( ($b[.]//0)*1000 + ($bt/2) ) / $bt) | floor) as $bs
        | (($cs - $bs) | if . < 0 then -. else . end) ]
    | max // 0' 2>/dev/null || echo 0)"
  case "$max_delta" in ''|*[!0-9]*) max_delta=0 ;; esac
  if [ "$max_delta" -ge "$max_shift" ]; then echo "SHIFT"; else echo "OK"; fi
}
