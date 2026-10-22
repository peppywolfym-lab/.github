#!/usr/bin/env bash
# match-discussions.sh — deterministic matching between Mary's proposed ideas
# and existing Ideas Discussions, replacing the prose "use fuzzy matching"
# instruction in the original prompt.
#
# Why this exists:
#   The original Phase-5 instruction told Mary to "use fuzzy matching" against
#   existing Discussion titles in her head. There is no way to test, replay,
#   or audit that. Two runs could create duplicate Discussions for the same
#   idea with slightly different titles. This is R5 + R6.
#
# Approach:
#   1. Normalize titles to a canonical form (strip emoji, punctuation,
#      lowercase, collapse whitespace, drop common stopwords).
#   2. Tokenize and compute Jaccard similarity over token sets.
#   3. Match if similarity >= MATCH_THRESHOLD (default 0.6).
#
# Inputs:
#   $1  Path to signals.json (must contain .ideas_discussions.items)
#   $2  Path to proposals.json — array of { title, summary, ... }
#
# Output (stdout, JSON):
#   {
#     "matched":         [ { "proposal": {...}, "discussion": {...}, "similarity": 0.83 } ],
#     "new_candidates":  [ { "proposal": {...} } ],
#     "threshold":       0.6
#   }
#
# Env:
#   MATCH_THRESHOLD  Override default Jaccard similarity threshold.

set -euo pipefail

# NB: matching logic is implemented entirely in the embedded Python block
# below. Earlier drafts had standalone bash `normalize_title` /
# `jaccard_similarity` helpers that were never called; removed per Copilot
# review on PR petry-projects/.github#85.

match_discussions_main() {
  local signals_path="$1"
  local proposals_path="$2"
  local threshold="${MATCH_THRESHOLD:-0.6}"

  # Validate threshold is a parseable float in [0, 1] BEFORE handing it to
  # Python, so a typo doesn't surface as an opaque traceback. Caught by
  # Copilot review on PR petry-projects/.github#85.
  if ! printf '%s' "$threshold" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    printf '[match-discussions] MATCH_THRESHOLD must be a non-negative number, got: %s\n' "$threshold" >&2
    return 64
  fi
  # Validate range using awk (portable, no bash float math).
  if ! awk -v t="$threshold" 'BEGIN { exit !(t >= 0 && t <= 1) }'; then
    printf '[match-discussions] MATCH_THRESHOLD must be in [0, 1], got: %s\n' "$threshold" >&2
    return 64
  fi

  if [ ! -f "$signals_path" ]; then
    printf '[match-discussions] signals not found: %s\n' "$signals_path" >&2
    return 64
  fi
  if [ ! -f "$proposals_path" ]; then
    printf '[match-discussions] proposals not found: %s\n' "$proposals_path" >&2
    return 64
  fi

  python3 - "$signals_path" "$proposals_path" "$threshold" <<'PY'
import json
import re
import sys
import unicodedata

signals_path, proposals_path, threshold_str = sys.argv[1:4]
threshold = float(threshold_str)

STOPWORDS = {
    "a", "an", "the", "of", "for", "to", "and", "or", "with", "in", "on",
    "by", "via", "as", "is", "are", "be", "support", "add", "new",
    "feature", "idea",
}


def normalize(title: str) -> set[str]:
    no_sym = "".join(ch for ch in title if unicodedata.category(ch)[0] != "S")
    folded = (
        unicodedata.normalize("NFKD", no_sym).encode("ascii", "ignore").decode()
    )
    folded = folded.lower()
    cleaned = re.sub(r"[^a-z0-9]+", " ", folded).strip()
    return {t for t in cleaned.split() if t and t not in STOPWORDS}


def jaccard(a: set[str], b: set[str]) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def _load_json(path: str, label: str):
    """Load JSON from path, exiting with code 2 on any read or parse error."""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except OSError as exc:
        sys.stderr.write(f"[match-discussions] cannot read {label}: {exc}\n")
        sys.exit(2)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"[match-discussions] invalid JSON in {label}: {exc}\n")
        sys.exit(2)


signals = _load_json(signals_path, "signals")
proposals = _load_json(proposals_path, "proposals")

if not isinstance(proposals, list):
    sys.stderr.write("[match-discussions] proposals must be a JSON array\n")
    sys.exit(65)

discussions = signals.get("ideas_discussions", {}).get("items", []) or []
# Skip discussions without an id to avoid all id-less entries collapsing into
# a single `None` key in seen_disc_ids. Caught by CodeRabbit on PR #85.
disc_norm = [
    (d, normalize(d.get("title", "")))
    for d in discussions
    if d.get("id") is not None
]

# --- Optimal (similarity-sorted) matching ------------------------------------
# The original greedy per-proposal loop consumed discussions in proposal order,
# so an early lower-value match could block a later higher-value match.
# Instead we enumerate all (proposal, discussion) pairs, sort by similarity
# descending (ties broken by original proposal index for stability), then
# assign greedily. This guarantees globally higher-value matches are honoured
# first. Caught by CodeRabbit review on PR petry-projects/.github#85.

# Collect valid proposals with their original index (for tie-breaking + new_candidates).
proposals_indexed: list[tuple[int, dict]] = []
for p_idx, proposal in enumerate(proposals):
    if not isinstance(proposal, dict) or "title" not in proposal:
        sys.stderr.write(f"[match-discussions] skipping malformed proposal: {proposal!r}\n")
        continue
    proposals_indexed.append((p_idx, proposal))

# Build all (similarity, proposal_idx, disc_id, proposal, disc) tuples.
all_pairs: list[tuple[float, int, str, dict, dict]] = []
for p_idx, proposal in proposals_indexed:
    p_norm = normalize(proposal["title"])
    for disc, d_norm in disc_norm:
        sim = jaccard(p_norm, d_norm)
        all_pairs.append((sim, p_idx, disc["id"], proposal, disc))

# Sort descending by similarity; stable tie-break by proposal index ascending.
all_pairs.sort(key=lambda x: (-x[0], x[1]))

matched = []
seen_disc_ids: set[str] = set()
seen_proposal_idxs: set[int] = set()

for sim, p_idx, disc_id, proposal, disc in all_pairs:
    if p_idx in seen_proposal_idxs or disc_id in seen_disc_ids:
        continue
    if sim >= threshold:
        matched.append(
            {
                "proposal": proposal,
                "discussion": disc,
                "similarity": round(sim, 4),
            }
        )
        seen_disc_ids.add(disc_id)
        seen_proposal_idxs.add(p_idx)

# Unmatched proposals become new candidates.
new_candidates = []
for p_idx, proposal in proposals_indexed:
    if p_idx in seen_proposal_idxs:
        continue
    p_norm = normalize(proposal["title"])
    best_sim = max(
        (jaccard(p_norm, d_norm) for _, d_norm in disc_norm),
        default=0.0,
    )
    new_candidates.append({"proposal": proposal, "best_similarity": round(best_sim, 4)})

result = {
    "matched": matched,
    "new_candidates": new_candidates,
    "threshold": threshold,
}
print(json.dumps(result, indent=2))
PY
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -ne 2 ]; then
    printf 'usage: %s <signals.json> <proposals.json>\n' "$0" >&2
    exit 64
  fi
  match_discussions_main "$1" "$2"
fi
