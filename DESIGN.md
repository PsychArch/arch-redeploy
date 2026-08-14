# Design

This document explains how arch-redeploy's `arch-redeploy` command makes a
destructive remote redeploy reviewable before erasure, reversible before the
destructive boundary, and resumable afterward. The [README](README.md) is the
operator guide; [TESTING.md](TESTING.md) defines the validation protocol.

## Design goals

The implementation is organized around five properties:

1. **Validate early.** Discover dependencies, storage, firmware, network,
   mirrors, authentication, and payload requirements before scheduling a reboot.
2. **Make the boundary explicit.** Recovery revalidates the plan and offers a
   final cancellation window before writing the target disk.
3. **Reverse owned pre-erasure changes.** Boot scheduling and cleanup operate
   only on files, selectors, and firmware entries owned by the current install.
4. **Resume owned post-erasure state.** An install ID, filesystem labels, and
   persistent checkpoints distinguish a retry from a foreign disk layout.
5. **Fail accessible.** Recovery failures stay on the console and, when the
   captured network works, remain reachable over SSH.

This is not a general distribution installer. It deliberately does not model
arbitrary partition layouts, preserve selected partitions, reconstruct RAID or
multipath storage, migrate encrypted disks, or provide a backup system.

## System overview

The workflow has four execution environments:

| Environment | Main implementation | Responsibility |
| --- | --- | --- |
| Source Linux | [`arch-redeploy`](arch-redeploy), [`lib/`](lib/) | Inspect the host, capture and seal a plan, build artifacts, and schedule one recovery boot |
| Ephemeral recovery | [`installer/init`](installer/init), [`installer/install.sh`](installer/install.sh) | Restore access, revalidate the plan, cross the erase boundary, and install persistent recovery |
| Persistent recovery | Recovery files on the new root filesystem | Resume an interrupted installation without claiming an unrelated layout |
| Target Arch | [`installer/target.sh`](installer/target.sh), [`installer/finalize.sh`](installer/finalize.sh) | Configure Arch, validate it, and remove recovery artifacts after a healthy first boot |

The intended sequence is:

```text
source Linux
  -> captured and verified plan
  -> transactional one-shot boot
  -> ephemeral Alpine recovery
       ---- final cancellation window ----
       ======== disk erase boundary ========
  -> persistent recovery on the new disk
  -> configured Arch system
  -> first-boot validation and cleanup
```

The source OS remains recoverable through the final cancellation window. After
the erase boundary, recovery means completing the Arch installation or restoring
an external backup; it no longer means returning to the source filesystem.

## State and progress

### Source state

The source-side control plane stores `/var/lib/arch-redeploy/state.json` with
mode `0600`. JSON updates are written to a temporary file, validated, and
atomically renamed into place. A non-blocking `flock` prevents two source-side
commands from changing the operation concurrently.

The durable source states are intentionally small:

```text
preparing -> prepared -> scheduled
```

- `preparing` means the plan exists and artifacts may still be under
  construction.
- `prepared` means the kernel, recovery image, payload choice, and hashes have
  been committed.
- `scheduled` means the return hook and one-shot boot transaction are armed.

Only the next transition is accepted. A repeated bare invocation reads this
state, revalidates it, and either resumes preparation, returns to review, or
checks that the scheduled boot is still armed.

### Operator timeline

The source CLI, recovery control command, persistent checkpoint, and first-boot
finalizer share the same nine-stage vocabulary:

| Stage | Environment | Meaning |
| --- | --- | --- |
| `inspect` | Source | Inspect the system and capture the plan |
| `build` | Source | Build and verify the installer and payload |
| `review` | Source | Show the complete plan and wait for confirmation |
| `armed` | Source | Schedule the one-shot recovery boot |
| `revalidate` | Recovery | Restore access and repeat disk, network, mirror, and payload checks |
| `recovery` | Recovery | Erase, lay out the disk, and install persistent recovery |
| `install` | Recovery | Install and configure Arch |
| `verify` | Recovery | Validate the target and reboot |
| `cleanup` | Target | Verify first-boot health and remove recovery |

Normal progress updates can stay on the current stage or move forward by one
stage. This keeps the shared status output monotonic; the durable source state
and recovery control flow enforce the actual safety boundaries.

## Captured plan and sealing

Inspection records the information needed to identify the operation and rebuild
the target without consulting the source filesystem:

- a unique install ID and protocol version;
- source package-manager family and virtual-machine detection;
- disk path, size, serial, WWN, sector sizes, partition-table ID, and canonical
  partition-table hash;
- firmware mode and source boot arrangement;
- administrator name, authorized keys or password hash, and SSH port;
- hostname, timezone, IPv4 and IPv6 modes, addresses, routes, interface MAC
  addresses, and DNS servers; and
- selected Alpine and Arch mirrors, payload mode, package lock, artifact sizes,
  and hashes.

Two fingerprints seal different phases of this data. The input fingerprint
covers the captured plan before building. The prepared fingerprint also covers
the payload and built artifacts. If either changes outside the guided workflow,
continuation stops instead of silently adopting the edit.

Disk validation is repeated on the source and in recovery. Before erasure, both
the physical identity and the original canonical partition table must match the
captured plan. If the device path changes, recovery may locate the disk by a
unique matching serial or WWN, but ambiguity is fatal.

## Artifact and payload construction

Preparation builds a compact Alpine recovery environment on the source
system. The Alpine minirootfs archive, checksum, and detached signature are
downloaded from the selected release mirror and verified against the pinned
official release key in [`assets/alpine-release-key.asc`](assets/alpine-release-key.asc).

The builder installs the recovery tools, an appropriate Alpine kernel, the Arch
keyring, and the installer sources. Arch package verification remains enabled;
the design never switches pacman to an unsigned mode.

The payload has two modes:

### Offline payload

When staging space and the builder permit it, preparation installs and
configures a complete Arch root in a temporary tree, and archives it with
metadata. The archive is staged beside the recovery kernel and initramfs.
Recovery mounts the source boot filesystem read-only, verifies the archive,
copies it into RAM, and unmounts the source filesystem before erasure. Package
networking is then optional after the persistent recovery state exists.

### Online fallback

If a complete archive cannot be built, preparation resolves the exact package
names, versions, and mirror-relative paths into a lock file. Every locked
package and detached signature must be reachable from at least two selected
mirrors before online mode is offered. Recovery repeats that preflight before
erasure and verifies each downloaded package signature and identity.

Proxy credentials and custom CA paths are not copied into recovery. A source
using proxy environment variables or custom trust paths must successfully
produce the offline payload; it cannot fall back to online-after-wipe mode.

Completed artifacts are committed with sizes and SHA-256 hashes. A later run
reuses them only when the manifest, install ID, sizes, and hashes all agree.

## Transactional one-shot boot

Scheduling is the only phase that intentionally changes source boot state. The
recovery kernel and initramfs are first staged into an install-ID-owned directory
under `/boot/arch-redeploy`. A systemd or OpenRC return hook is then installed
so an aborted recovery that boots the source OS can remove the temporary state.

Each boot mutation follows a pending/commit pattern:

1. Record the intended mutation and the original selector or file hash.
2. Create or modify the owned boot resource.
3. Sync it and arm the one-shot selector.
4. Mark the schedule committed only after it can be read back as armed.

UEFI uses an install-ID-labelled standalone GRUB EFI program and a temporary
firmware entry selected with `BootNext`. BIOS uses the existing GRUB one-shot
mechanism when available and otherwise supports extlinux's one-time selector.

For GRUB and extlinux, the original configuration and selector state are
snapshotted. Rollback restores the exact file only if it still matches the
scheduled version. If another actor changed the file, cleanup removes only the
marked `arch-redeploy` block or leaves the external change untouched. UEFI
cleanup similarly removes only the owned firmware entry and EFI directory, and
restores the prior `BootNext` only when it has not been superseded.

An interrupted scheduling transaction is reconciled before the workflow offers
review again. `cancel` is therefore repeatable and scoped to the current install
ID rather than being a general bootloader cleanup command.

## Recovery access and revalidation

The recovery initramfs mounts its runtime filesystems, loads common server and
virtual-machine drivers, restores captured IPv4 and IPv6 settings by interface
MAC address, and writes the captured DNS servers. It then starts OpenSSH on the
preserved port.

Recovery SSH always logs in as `root`. If authorized keys were captured, they
are installed with password authentication disabled. Otherwise, the captured
password hash is assigned to recovery root. The same credentials are later
assigned to the selected target administrator. Plaintext passwords are never
stored by the workflow.

Before touching the disk, recovery validates:

- configuration schema and protocol;
- the writable whole-disk identity and original partition table;
- restored network access when it is required;
- the offline payload hash or the complete online package transaction; and
- mirror availability required by the selected payload mode.

The console and SSH control command expose the shared timeline. Full output is
written to `/arch-redeploy.log`. An error unmounts the target, prints the failing
line, refuses to reboot, and opens a recovery shell for inspection and retry.

## Cancellation and the erase boundary

After all recovery checks pass, a fixed 60-second countdown provides the final
opportunity to cancel. Console input and `arch-redeploy cancel` over SSH both
create the same request. The request path and erase path take the same lock, so
only one outcome can commit:

- cancellation wins and recovery reboots to the untouched source OS; or
- the boundary wins, records erasure as started, rechecks the disk and original
  partition table under the lock, and calls `wipefs`.

The source return hook removes the temporary schedule after a cancellation.
Once the erase marker is committed, the recovery control command refuses to
promise a return to the source system.

## Disk ownership and layout

Disk layouts are fixed so that validation and resume do not have to infer user
intent:

| Firmware and disk size | Partition table | Layout |
| --- | --- | --- |
| UEFI | GPT | 100 MiB FAT32 ESP at `/efi`, then one ext4 root |
| BIOS, up to 2 TiB | MBR | One bootable ext4 root |
| BIOS, above 2 TiB | GPT | BIOS-boot partition, then one ext4 root |

The root and ESP labels include a compact form of the install ID. The root also
contains an install-ID marker. Recovery claims a partial filesystem only when
those ownership signals match; a foreign label, marker, or checkpoint stops the
installer.

There is one unavoidable interval between the first destructive partition
write and completion of the persistent recovery bootloader. Power loss in that
interval may require provider rescue media. Immediately after formatting, the
installer writes a recovery kernel, initramfs, GRUB configuration, install ID,
and checkpoint to `/arch-redeploy-recovery`, then syncs them.

UEFI recovery installs both a labelled firmware entry and the removable
`EFI/BOOT/BOOTX64.EFI` fallback. BIOS recovery installs GRUB to the disk. Once
this checkpoint is complete, a reboot can return to the same recovery
environment without relying on the erased source system.

## Resume and idempotency

On entry, recovery distinguishes three cases:

1. A persistent recovery directory and checkpoint match the install ID.
2. A partially created root has the expected install-ID-derived label and no
   conflicting marker.
3. The current recovery runtime recorded that erasure began but partitioning
   did not finish.

Only the third case repeats partition creation. The other cases mount and repair
the owned layout, rebuild recovery boot files, and continue. Offline extraction,
locked-package installation, target configuration, initramfs generation,
bootloader installation, and progress writes are designed to tolerate replay.

The ownership rules are more important than guessing how far an interrupted
command ran. Uncertain owned work is repeated; unknown work is not adopted.

## Target configuration and cleanup

The target configuration creates or updates the selected administrator, carries
over SSH authentication and port, writes hostname and timezone, creates
systemd-networkd configuration, enables `systemd-networkd`, `systemd-resolved`,
and `sshd`, writes a UUID-based `fstab`, builds the Arch initramfs, and installs
the final GRUB bootloader.

Before reboot, recovery checks the Arch release marker, kernel, initramfs, SSH
configuration, enabled services, and GRUB configuration. It also installs a
one-shot finalizer in the target.

On first Arch boot, the finalizer requires active SSH, active networking, and a
default route before cleanup. It records a durable result in
`/var/lib/arch-redeploy/result.json`, removes the persistent recovery files and
temporary boot entries, regenerates GRUB configuration, and finally removes its
own service and helper files. A failed health check leaves recovery resources in
place for diagnosis.

## Failure model

| Failure point | Expected recovery |
| --- | --- |
| Inspection or build | Fix the reported condition and rerun the bare command, or cancel |
| One-shot scheduling | Reconciliation rolls back incomplete owned changes before retry |
| Recovery before erasure | Inspect over console or SSH, retry, or cancel back to the source OS |
| Partition write before persistent recovery | Use provider rescue media if the machine is no longer bootable |
| Persistent recovery or Arch installation | Reboot into matching recovery or rerun the installer from its shell |
| First-boot cleanup | Arch remains installed; inspect the finalizer and retained recovery state |

These are design guarantees, not proof for every firmware and storage stack.
The destructive matrix in [TESTING.md](TESTING.md) must be exercised on
disposable systems with provider-console access before relying on a new
environment in production.

## Source map

- [`arch-redeploy`](arch-redeploy): guided source-side entrypoint and review.
- [`lib/common.sh`](lib/common.sh): paths, locks, atomic JSON, and state helpers.
- [`lib/detect.sh`](lib/detect.sh): host, disk, administrator, network, and
  firmware discovery.
- [`lib/build.sh`](lib/build.sh): signed Alpine builder and Arch payload modes.
- [`lib/boot.sh`](lib/boot.sh): transactional boot scheduling and rollback.
- [`lib/stages.sh`](lib/stages.sh): shared timeline and progress transitions.
- [`installer/install.sh`](installer/install.sh): recovery validation, erase
  boundary, layout, installation, and retry behavior.
- [`installer/target.sh`](installer/target.sh): target identity, access, and
  network configuration.
- [`installer/finalize.sh`](installer/finalize.sh): first-boot validation and
  cleanup.
- [`tests/run.sh`](tests/run.sh): block-device-free behavior tests.
