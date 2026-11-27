# Minecraft backups

The `mcbackup` sidecar backs up `/data` with Restic. Backup settings and
retention are declared in [`app/values.yaml`](app/values.yaml).

Check snapshots and repository integrity:

```sh
kubectl exec -n minecraft deploy/minecraft-java -c mcbackup -- restic snapshots --host minecraft-java --tag world
kubectl exec -n minecraft deploy/minecraft-java -c mcbackup -- restic check
```

Run recovery from the repository root with administrative cluster access:

```sh
bash scripts/restore-minecraft-restic-backup.sh
bash scripts/restore-minecraft-restic-backup.sh SNAPSHOT_ID
```

The first command lists snapshots. Use an ID or `latest` to restore. Recovery
replaces the contents of `/data`, verifies `world/level.dat`, and restarts the
server. If recovery fails after shutdown, the server stays stopped; inspect
the restore Job before restarting it.
