---
applyTo: ".github/workflows/**/*.yml"
---

# Review guidance for hive-mind GitHub Actions workflows

Workflow files are security-sensitive — they control CI, releases, deploys. High-quality Copilot review here has paid off repeatedly on this repo (real permissions scoping and concurrency bugs caught).

## Top principle: verify before asserting

Same rule as every other instruction file. For workflows specifically: check the YAML schema, the actions' docs for the version pinned, and the actual trigger conditions before claiming something's wrong.

## Don't re-raise resolved threads

If a prior review adjudicated the workflow's design, don't re-raise unless there's a concrete security or correctness defect the rationale doesn't address.

## Raise these kinds of comments — high-value

- **Top-level `permissions:` granted broadly** when per-job would suffice. Least-privilege: `contents: read` at top level, elevated perms only on jobs that need them.
- **Concurrency group scoped to the entire workflow** when it should be deploy-only. A shared group means PR builds serialize with main deploys — this is a real correctness bug.
- **Secrets passed to PRs from forked repos** — GitHub's default is safe, but any explicit workaround is a security risk worth flagging.
- **Missing `if:` gating on deploy steps** that must not fire on PR events. Pages/release workflows deploying on every `pull_request` event is wrong.
- **Hardcoded `secrets.GITHUB_TOKEN` usage when `permissions:` would suffice** — the default token should be the restricted one.
- **Missing `SHA256SUMS` / artifact integrity checks** for release workflows that publish binaries.
- **Actions pinned only by tag (not SHA)** for third-party actions — supply-chain risk. First-party (`actions/*`) tag-pinning is fine.

## Skip these kinds of comments

- **Matrix formatting style**, job naming conventions, step ordering for readability.
- **Cache key templates** unless they're genuinely wrong (cache misses aren't a correctness issue).
- **Suggestions to consolidate jobs for "efficiency"** — parallel jobs are a feature.
- **"Add caching to speed this up"** — don't add complexity for marginal CI time savings on a low-traffic repo.

## Repo-specific conventions

- Release workflows for `v*` tags (CLI) and `desktop-v*` tags (GUI) are parallel namespaces; one doesn't trigger the other. Don't suggest unifying them.
- Pages deploys only run on `push` to main or `workflow_dispatch`, never on `pull_request`.
- PR builds run build-only; deploy jobs gate on `github.event_name == 'push' || github.event_name == 'workflow_dispatch'`.
- Pre-commit `gitleaks` check is expected on commits touching anything under `.github/` or `core/` — don't suggest replacing it with hand-rolled regex (stated non-goal: hand-rolled secret detection).
