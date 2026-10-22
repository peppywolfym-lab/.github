# Held-out eval set — STARTER (copy me out)

This `dev/` + `holdout/` pair is a **starter**. When you copy the persona
scaffold into `.github-private`, move this eval set to that repo's
**`evals/<id>/`** tree — **not** into `personas/<id>/evals/`. Only under
`evals/` does it inherit the existing held-out validator
(`evals/validate-cases.py`) and the immutability guard (`holdout-guard.yml`).

- `dev/cases.jsonl` — proposer-visible split.
- `holdout/cases.jsonl` — CODEOWNER-gated; the gate scores against this.

One JSON object per line; every case needs a unique kebab-case `id`; a case must
never appear in both splits. See `.github-private` `evals/README.md` and
`evals/case.schema.json`.
