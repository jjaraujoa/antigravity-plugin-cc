---
description: Verify the Antigravity CLI (`agy`) is installed and authenticated; offer to install it if missing
allowed-tools: Bash(bash:*), Bash(curl:*), PowerShell, AskUserQuestion
---

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" check
```

Then interpret the JSON output:

- If `installed: false`, use `AskUserQuestion` once to offer installation.
  Options:
  - `Install agy now (Recommended)` — run the official installer:
    ```bash
    curl -fsSL https://antigravity.google/cli/install.sh | bash
    ```
    On Windows (native, not WSL) use the PowerShell installer instead,
    which puts `agy.exe` in `%LOCALAPPDATA%\agy\bin`:
    ```powershell
    irm https://antigravity.google/cli/install.ps1 | iex
    ```
    Then re-run the check (the wrapper finds `agy.exe` there even before
    Claude Code is restarted with the new PATH).
  - `Skip for now` — explain that `/antigravity:ask`, `/antigravity:delegate`,
    and `/antigravity:review` will fail until `agy` is installed.

- If `installed: true` but `auth: missing`, tell the user to either:
  - run `!agy` once interactively to complete OAuth (cached in the system
    keyring), **or**
  - export `ANTIGRAVITY_API_KEY` in their shell rc and reload it.

- If `installed: true` and `auth` is `api-key` or `oauth`, report that
  everything is ready — one short status line is enough.
