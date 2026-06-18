# builds

Public build / setup scripts.

## install-docker-nito-macos.sh

One-shot setup for the NITO dev environment on **macOS (Apple Silicon)**. It:

1. Installs Docker Desktop if missing (Homebrew or direct download), and starts it.
2. Creates a `nito-network` Docker network.
3. Ensures the `nito-sql2022` SQL Server container exists and is running
   (data persisted in `~/nito/sql`).
4. Pulls the latest `ghcr.io/aktak/nito:dev` (prompting for a GitHub username +
   token if needed) and ensures the `nito-app-dev` container runs that image,
   recreating it when a newer image is available. Its config is mounted from
   `~/nito/app-dev/CITO.config` — seeded on first run, then yours to edit — and its
   logs are written to `~/nito/app-dev/Log`.

On the shared network the app reaches SQL Server at host `nito-sql2022:1433`.

### Run it

Paste this into Terminal:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/aktak/builds/main/install-docker-nito-macos.sh)
```

> Uses `bash <(...)` rather than `curl … | bash` so the script can still read
> your GitHub username/token from the keyboard when it pulls the private image.

The GitHub token needs the `read:packages` scope to pull `ghcr.io/aktak/nito:dev`.

### Run it as a macOS app

If you'd rather double-click an app than paste a Terminal command, build a
`.app` bundle once:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/aktak/builds/main/install-docker-nito-macos-create-as-app.sh)
```

This creates `~/Applications/nito.app`. Open it from Finder and it'll
launch Terminal and run the installer (so it can still prompt you for the
GitHub token and menu choices). The app always fetches the latest installer at
launch, so it stays current without rebuilding.

## install-docker-sp-macos.sh

One-shot setup for the **smart-portal** dev environment on **macOS**. It installs and
starts Docker Desktop, creates the `nito-network`, ensures the `nito-sql2025` SQL Server
2025 container, then pulls `ghcr.io/aktak/smart-portal:latest` and runs the `nito-sp-dev`
container (web app + OData API). Its config is mounted from `~/nito/sp-dev/config.json`,
seeded on first run and then yours to edit.

### Run it

Paste this into Terminal:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/aktak/builds/main/install-docker-sp-macos.sh)
```

> `bash <(...)` (not `curl … | bash`) keeps the keyboard free so the script can prompt
> for your GitHub token and the host ports. The token needs the `read:packages` scope.

## install-docker-sp-windows.ps1

Windows port of the script above — same `nito-sql2025` + `nito-sp-dev` containers. It also
makes sure Docker Desktop is set to **Linux containers**, switching the engine
automatically if it's currently on Windows containers. Run it in an **elevated** PowerShell
the first time (installing Docker Desktop needs admin).

### Run it

From a PowerShell terminal — download, then run (so the script can still prompt you):

```powershell
$u = 'https://raw.githubusercontent.com/aktak/builds/main/install-docker-sp-windows.ps1'; $f = "$env:TEMP\install-docker-sp-windows.ps1"; irm $u -OutFile $f; powershell -ExecutionPolicy Bypass -File $f
```

Or, if you've cloned the repo, run the local file directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-docker-sp-windows.ps1
```

> Avoid `irm … | iex` here — piping to `iex` consumes stdin, which breaks the interactive
> token/port prompts. Download-then-run (above) keeps them working.
