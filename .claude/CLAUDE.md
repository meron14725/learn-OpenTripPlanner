#### Pull Request Workflow:

- All changes must go through Pull Requests
- No direct commits to main branch allowed
- Use `gh pr create -a unsolublesugar -l enhancement` for PR creation (automatically assigns repository owner and adds enhancement label)
- Include appropriate PR descriptions and test plans
- Always include a "## 対応チケット" section in the PR description listing which tasks from `開発計画.md` were completed (e.g., `#0-1`, `#0-2`)
- Before creating a PR, update the checkboxes in `開発計画.md` for all completed tasks and include that change in the same commit/push
