# Local NFS lab and rollback

This lab creates a read-only NFSv3 export restricted to the IPv4 loopback host.
It is useful for checking that LumeFS discovers an NFS mount and reads local
NFS client counters.

It does **not** validate pNFS. macOS's local `nfsd` configuration used here does
not create a pNFS metadata/data-server topology, and a successful NFS mount is
not evidence of parallel data paths.

## Safety boundary

The setup script:

- requires `LUMEFS_NFS_LAB_CONFIRM=YES`;
- creates only `/private/var/tmp/com.hephaistos.LumeFS.nfs-lab.<uid>`;
- adds one marked block to `/etc/exports`;
- exports only to `127.0.0.1` and maps access to the invoking user;
- exports the fixture read-only;
- mounts with bounded soft retry/timeouts and `noexec`, `nosuid`, `nodev`, and
  `nobrowse` options;
- starts, but never enables, `nfsd` when it is not already running;
- waits up to 10 seconds for the loopback NFSv3 RPC service before mounting;
- mounts only its own fixed mount directory;
- never uses forced unmount or recursive deletion;
- records whether `nfsd` was running and whether `/etc/exports` existed;
- removes only its marked export block during cleanup and restores an initially
  absent `/etc/exports` when no unrelated entries remain.

Administrator authorization is required because `/etc/exports`, `nfsd`, and
mount operations are system-level. Review `scripts/nfs_lab.sh` before running it.

## 1. Validate without system changes

```bash
./scripts/nfs_lab.sh validate
```

This creates a temporary alternate exports file, checks it with
`nfsd -F <file> checkexports`, and removes the temporary directory. It does not
change `/etc/exports`, start a service, or mount a volume.

When `nfsd` is not running, macOS may warn that it cannot verify export
permissions. A zero exit status still verifies the generated syntax, but not
runtime access to the exported directory.

## 2. Inspect current state

```bash
./scripts/nfs_lab.sh status
```

Save the output privately if rollback evidence is needed. It can reveal whether
the local NFS service is in use.

## 3. Create the lab

```bash
LUMEFS_NFS_LAB_CONFIRM=YES ./scripts/nfs_lab.sh setup
```

Expected evidence is limited to:

- the marked export block exists;
- the exact lab mount appears as NFS;
- `showmount -e 127.0.0.1` lists the lab export;
- LumeFS lists the mount after its mount refresh interval.

Do not infer pNFS support from any of these facts.

## 4. Read-only checks

```bash
./scripts/nfs_lab.sh status
/usr/bin/nfsstat -f JSON -c
```

Do not publish raw command output without reviewing hostnames, mount names, and
other client activity. NFS counters are system-wide, not isolated to the lab.

## 5. Roll back

```bash
./scripts/nfs_lab.sh cleanup
./scripts/nfs_lab.sh status
```

Cleanup first performs a normal unmount. If unmount fails, the script stops and
leaves the export in place rather than forcing a potentially unsafe detach.
Close Finder windows or shells using the mount and run cleanup again.

After a successful cleanup, the mount and marked block are absent, lab
directories and temporary backup are removed, and an initially absent
`/etc/exports` is absent again when no unrelated entries were added. `nfsd` is
stopped only when the script started it and no other exports remain. The script
never disables the NFS service because setup never enables it.

## Interrupted setup or manual recovery

Run cleanup first:

```bash
./scripts/nfs_lab.sh cleanup
```

If the script reports malformed markers, do not run broad `sed` or overwrite
`/etc/exports`. Inspect these exact items:

```bash
grep -n 'LUMEFS_NFS_LAB' /etc/exports
ls -l /etc/exports.lumefs-backup-"$UID"
/sbin/mount | grep 'com.hephaistos.LumeFS.nfs-lab' || true
/sbin/nfsd status
```

Restore the root-owned backup only after confirming that no unrelated export was
added after the backup was created:

```bash
sudo cp -p /etc/exports.lumefs-backup-"$UID" /etc/exports
sudo /sbin/nfsd checkexports
sudo /sbin/nfsd update
```

That manual restore can overwrite unrelated changes, so it is a last resort.
Prefer the script's marker-based cleanup.
