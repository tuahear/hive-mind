---
applyTo: "docs/**,README.md,CHANGELOG.md"
---

# Review guidance for hive-mind docs

Documentation lives at two layers:

- **README.md** — short marketing + install snippet. Don't suggest expanding it; it intentionally links out to the docs site.
- **docs/** — VitePress site. Routes strip `.md` automatically.
- **CHANGELOG.md** — Keep-a-Changelog format, manually curated.

## Skip these kinds of comments

- **Relative link style `./foo` vs `./foo.md`** — VitePress resolves both. Only flag if the link 404s.
- **"Add a TOC"** — VitePress renders one automatically in the sidebar.
- **Suggestions to add emojis, callout boxes, or decorative markdown** — English-only plain prose is the house style.
- **"Reword for clarity" on terminology that's already precise** — words like "adapter", "hook", "marker", "sync" are specific terms in this project; don't suggest softening them to generic synonyms.

## Raise these kinds of comments

- **Docs that describe behavior the code doesn't implement yet** — e.g. "setup.sh auto-detects the adapter" when it defaults to `ADAPTER=claude-code`. Actual mismatches between doc and code are high-value.
- **Broken links** (verify first — VitePress routing means many reasonable-looking "broken" links actually work).
- **Stale version strings, hook paths, or command examples** — files that quote `~/.claude/hive-mind/scripts/X.sh` after the refactor moved things to `core/`.
- **Missing CHANGELOG entry** for user-visible behavior changes. Internal refactors don't need one unless they change the adapter contract or hook strings.

## Non-goals (stated once, don't re-raise per-file)

- **No i18n.** English only across CLI, docs, and UI.
- **No telemetry.** Don't suggest analytics or usage reporting.
- **No vendor-specific cloud dependencies.** Docs must work for any git host.

## Style

- Sentences, not bullets, when the prose is explaining *why*. Bullets are for enumerating choices or checklist items.
- Code fences with language tags (`bash`, `json`, `toml`) — don't flag unlabeled fences unless they contain actual code that would benefit from highlighting.
- Link to the issue tracker (`#NN`) not external tickets.
