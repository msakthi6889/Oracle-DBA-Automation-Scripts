
# Oracle DB Patching Bundle (Sakthivel)

This bundle provides a reusable, environment-agnostic framework to patch Oracle Database homes and manage GoldenGate services.

## Contents

- `patch_orchestrator.sh` — main runner: stop → backup+patch → start
- `01_stop_db_services.sh` — stops GoldenGate, DB instances (PMON discovery), and listener
- `02_backup_and_patch.sh` — backs up `$ORACLE_HOME` and applies patches using OPatch
- `03_start_db_services.sh` — starts listener, DBs, restarts GoldenGate, runs `datapatch`
- `scripts/common.sh` — shared helpers (logging, guards)
- `patch_state.env` — sample environment configuration
- `scripts/gg_control.sh` — single controller for GoldenGate (start/stop/status/verify)

## Quick Start

1. Edit `patch_state.env` for your environment (ORACLE_HOME, GG_HOME, PATCH_BASE_DIR, etc.).
2. Make scripts executable:
   ```bash
   chmod +x patch_orchestrator.sh 01_stop_db_services.sh 02_backup_and_patch.sh 03_start_db_services.sh scripts/gg_control.sh
   ```
3. Dry run:
   ```bash
   ./patch_orchestrator.sh -s ./patch_state.env
   ```
4. With a specific PATCH_ID (e.g., RU 37960098):
   ```bash
   ./patch_orchestrator.sh -s ./patch_state.env -p 37960098
   ```

## GoldenGate Control
Use `scripts/gg_control.sh`:
```bash
scripts/gg_control.sh status
scripts/gg_control.sh stop
scripts/gg_control.sh start
scripts/gg_control.sh verify --timeout 600 --interval 5
```

## Notes
- Ensure you run as the Oracle OS user.
- Logs are written under `./logs/` by default; customize via `patch_state.env`.
- For out-of-place patching, we’ll add a clone/switch flow in a v2.
