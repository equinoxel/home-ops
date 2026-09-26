# Agent Instructions

This project uses **GitHub Issues** for issue tracking, managed via the `gh` CLI.

## Quick Reference

```bash
gh issue list                                   # Find open work
gh issue list --label "priority/low"            # Filter by label
gh issue view <number>                          # View issue details
gh issue create --title "..." --body "..." \
  --label "area/kubernetes"                      # File new work
gh issue comment <number> --body "..."          # Add progress notes
gh issue close <number>                          # Complete work
```

### Labels

- Area: `area/kubernetes`, `area/talos`, `area/docs`, `area/scripts`, etc.
- Priority: `priority/low` (add higher-priority labels as needed).
- Apply at least one `area/*` label, plus a priority label when relevant.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create GitHub issues (`gh issue create`) for anything that needs follow-up. Label appropriately (`area/*`, `priority/*`).
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished issues (`gh issue close`), comment progress on in-progress ones
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
