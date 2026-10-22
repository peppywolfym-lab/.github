#!/usr/bin/env bats
# Regression guard for SonarCloud GitHub Actions dependency-hardening findings
# (githubactions:S8541/S8543/S8544/S8545 for pip, S6505 for npx) — see issue #623.
#
# Every `pip install` in a workflow must resolve version- and hash-locked
# (`--require-hashes` + `--only-binary :all:`), and every `npx` invocation must
# refuse install-time lifecycle scripts (`--ignore-scripts`). These are the
# mitigations SonarCloud checks for; the guard fails loud if a new workflow
# reintroduces an unhardened install command.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

# Emit the non-comment `run:` command lines of every workflow file. A line is
# treated as a comment when its first non-whitespace character is '#'.
workflow_command_lines() {
  local f trimmed line
  for f in "$REPO_ROOT"/.github/workflows/*.yml; do
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      trimmed="${line#"${line%%[![:space:]]*}"}"
      [ "${trimmed:0:1}" = "#" ] && continue
      printf '%s\t%s\n' "$f" "$line"
    done < "$f"
  done
}

@test "every 'pip install' in a workflow is hash- and binary-locked" {
  local fail=0 file cmd
  while IFS=$'\t' read -r file cmd || [ -n "$file" ]; do
    case "$cmd" in
      *"pip install"*)
        case "$cmd" in *"--require-hashes"*) : ;; *)
          echo "MISSING --require-hashes: ${file##*/}: $cmd"; fail=1 ;;
        esac
        case "$cmd" in *"--only-binary :all:"*) : ;; *)
          echo "MISSING --only-binary :all:: ${file##*/}: $cmd"; fail=1 ;;
        esac
        ;;
    esac
  done < <(workflow_command_lines)
  [ "$fail" -eq 0 ]
}

@test "every 'npx' in a workflow refuses lifecycle scripts (--ignore-scripts)" {
  local fail=0 file cmd
  while IFS=$'\t' read -r file cmd || [ -n "$file" ]; do
    case "$cmd" in
      *"npx "*)
        case "$cmd" in *"--ignore-scripts"*) : ;; *)
          echo "MISSING --ignore-scripts: ${file##*/}: $cmd"; fail=1 ;;
        esac
        ;;
    esac
  done < <(workflow_command_lines)
  [ "$fail" -eq 0 ]
}

@test "every 'go install' in a workflow is version-pinned and S8545-exempted" {
  # S8545 flags `go install` as non-lockfile-enforcing. Go has no --locked /
  # --require-hashes equivalent: a pinned `@vX.Y.Z` is the reproducible install
  # (verified via the Go checksum DB, sum.golang.org), so the finding is a confirmed
  # false positive suppressed with an inline `# NOSONAR(githubactions:S8545)`
  # marker. This guard fails loud if a new `go install` is added unpinned
  # (@latest/@main) or without the marker.
  local fail=0 file cmd
  while IFS=$'\t' read -r file cmd || [ -n "$file" ]; do
    case "$cmd" in
      *"go install"*)
        case "$cmd" in
          *[a-zA-Z0-9_-]go\ install*) : ;;
          *)
            case "$cmd" in *"@v"[0-9]*) : ;; *)
              echo "UNPINNED go install (needs @vX.Y.Z): ${file##*/}: $cmd"; fail=1 ;;
            esac
            case "$cmd" in *"NOSONAR(githubactions:S8545)"*) : ;; *)
              echo "MISSING # NOSONAR(githubactions:S8545): ${file##*/}: $cmd"; fail=1 ;;
            esac
            ;;
        esac
        ;;
    esac
  done < <(workflow_command_lines)
  [ "$fail" -eq 0 ]
}

@test "each hash-locked requirements file referenced by a workflow exists" {
  local fail=0 file cmd path
  while IFS=$'\t' read -r file cmd || [ -n "$file" ]; do
    case "$cmd" in
      *"--require-hashes"*"-r "*)
        path="${cmd##*-r }"
        path="${path%% *}"
        path="${path#\'}"
        path="${path#\"}"
        path="${path%\'}"
        path="${path%\"}"
        # Reusable workflows check the tooling out under .feature-ideation-tooling/;
        # map that runtime prefix back to the repo root for the existence check.
        path="${path#.feature-ideation-tooling/}"
        if [ -z "$path" ]; then
          echo "EMPTY path extracted from: ${file##*/}: $cmd"; fail=1
        elif [ ! -f "$REPO_ROOT/$path" ]; then
          echo "MISSING requirements file: ${file##*/} references $path"; fail=1
        fi
        ;;
    esac
  done < <(workflow_command_lines)
  [ "$fail" -eq 0 ]
}
