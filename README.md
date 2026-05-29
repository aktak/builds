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
