# CJA MCP Server

An MCP (Model Context Protocol) server that exposes every exported function from the [cjar](https://benrwoodard.github.io/cjar/) R package as an MCP tool, built on top of [mcpr](https://mcpr.opifex.org/). Lets Claude Code (or any MCP client) drive Adobe Customer Journey Analytics.

## Prerequisites

- **R** ≥ 4.1 on PATH (`Rscript` must be runnable from the shell Claude Code uses).
- **Adobe CJA OAuth Server-to-Server credentials** as a JSON file. Adobe's older JWT flow was deprecated 2025-06-30; use S2S.
- **Claude Code** CLI installed.

## Install dependencies

```r
install.packages(c("pak", "jsonlite"))
pak::pkg_install("benrwoodard/cjar")
pak::pkg_install("devOpifex/mcpr")
```

`cjar` pulls a fair number of transitive deps (httr, httr2, jsonlite, dplyr, glue, lubridate, vctrs, openssl, R6, …). `pak` resolves them.

### Windows without Rtools

`pak` insists on `pkgbuild::check_build_tools` even for pure-R installs, so the GitHub install of `mcpr` will fail with *"Could not find tools necessary to compile a package"* unless Rtools is present. Easiest workaround if you don't want Rtools:

```powershell
# Install the one compiled dep from a CRAN binary first
Rscript -e "install.packages('yyjsonr', repos='https://cloud.r-project.org', type='binary')"

# Then install mcpr directly from a source zip (no pkgbuild check)
$tmp = "$env:TEMP\mcpr_install"
Remove-Item -Recurse -Force $tmp -ErrorAction Ignore
New-Item -ItemType Directory -Path $tmp | Out-Null
Invoke-WebRequest "https://github.com/devOpifex/mcpr/archive/refs/heads/master.zip" -OutFile "$tmp\mcpr.zip" -UseBasicParsing
Expand-Archive "$tmp\mcpr.zip" -DestinationPath $tmp -Force
$src = (Get-ChildItem $tmp -Directory | Where-Object Name -like 'mcpr-*').FullName
$rexe = Join-Path (Split-Path (Get-Command Rscript).Source) 'R.exe'
& $rexe CMD INSTALL --no-multiarch --no-test-load $src
```

## Configure CJA credentials

1. In Adobe Developer Console, create a project with **Customer Journey Analytics API** and **Experience Platform API** added, using **OAuth Server-to-Server** credentials.
2. Download the credentials JSON. The file must contain `CLIENT_ID`, `CLIENT_SECRETS`, `ORG_ID`, `SCOPES`.
3. Point an env var at it:

   ```powershell
   # PowerShell, persistent for the current user
   [Environment]::SetEnvironmentVariable('CJA_AUTH_FILE', 'C:\path\to\cja_credentials.json', 'User')
   ```

   Optionally also set a default data view so dimension/metric/freeform tools don't need it spelled out every call:

   ```powershell
   [Environment]::SetEnvironmentVariable('CJA_DATAVIEW_ID', 'dv_XXXXXXXXXXXXXXXXXXXXXXXX', 'User')
   ```

   Restart your terminal so new env vars are visible to child processes.

## Register the server with Claude Code

From any directory:

```bash
claude mcp add cja -- Rscript "C:/Users/ben.woodard/OneDrive - Accenture/Documents/cjar_mcpr/cja_mcp_server.R"
```

(Use forward slashes or escape backslashes in the path.)

Verify:

```bash
claude mcp list
```

You should see `cja` listed. Inside a Claude Code session, the tools appear as `mcp__cja__cja_get_me`, `mcp__cja__cja_freeform_table`, etc.

## Tools exposed

Auth / session:
- `cja_auth` — force reauth
- `cja_auth_with`, `cja_auth_path`, `cja_auth_name` — get/set session options

Metadata:
- `cja_get_me` — current user info (good connectivity check)
- `cja_get_dataviews` — data views (≈ report suites)
- `cja_get_dimensions`, `cja_get_metrics`, `cja_get_calculatedmetrics`
- `cja_get_filters`, `cja_get_filter`
- `cja_get_dateranges`
- `cja_get_projects`, `cja_get_project_config`
- `cja_get_audit_logs`, `cja_get_audit_logs_search`

Reporting:
- `cja_freeform_table` — the main reporting tool, equivalent to a Workspace Freeform Table

Filter (segment) authoring:
- `filter_verbs` — list available operators
- `filter_rule` — build a single rule
- `filter_con` — combine rules into a container
- `filter_seq` — combine rules into a sequence
- `filter_then` — time-restriction object for sequences
- `filter_build` — assemble a complete filter (optionally POST it)
- `filter_val` — validate a filter JSON body

The filter-authoring tools pass nested structures as JSON strings, since they originally compose R lists. Build them up step by step: `filter_rule` → JSON → pass that JSON as a string into `filter_con`'s `rules` arg, etc.

## How responses are shaped

Every tool returns a single text content block containing pretty-printed JSON. Data frames are serialized row-wise. `NA` becomes `null`. Large freeform queries can produce a lot of JSON — cap rows with the `top` argument or paginate via `page`.

## Troubleshooting

- **"CJA_AUTH_FILE not set"** in startup log — set the env var (see above) and restart Claude Code so the env propagates.
- **Server starts but every tool returns an auth error** — check the credentials JSON has all four expected fields and Experience Platform API is enabled on the Adobe Console project.
- **Tool call hangs** — `cja_freeform_table` with many breakdowns can take minutes. cjar logs estimated runtime to stderr (visible in Claude Code's MCP logs); consider reducing the dimension list or using `top` more aggressively.
- **`Rscript` not found** — check PATH; on Windows the typical install path is `C:\Program Files\R\R-4.4.x\bin\`. Either add it to PATH or use the full path in `claude mcp add`.
- **stdout pollution breaks the protocol** — the server is careful to send all logging through `message()` (stderr). If you fork this and add `print()`/`cat()` calls, route them through `message()` instead or the MCP handshake will fail.
- **Windows stdin gotcha** — the server includes a local `serve_io_persistent` that wraps `mcpr::serve_io`. mcpr's stock implementation calls `readLines("stdin", n = 1)` inside its loop, which on Windows Rscript reopens stdin each iteration and only ever sees the first line. The local wrapper opens `file("stdin")` once and reuses it, restoring the expected multi-request behavior. Verified by feeding `initialize` + `tools/list` and getting both responses back.

## File layout

```
cja_mcp_server.R   # The MCP server (Rscript entry point)
README.md          # This file
```
