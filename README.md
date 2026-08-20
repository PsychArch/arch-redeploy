# arch-redeploy

`arch-redeploy` guides an x86_64 Linux server through a remotely recoverable
redeploy to official Arch Linux. Its `arch-redeploy` command is the single
state-aware entrypoint: it verifies the network, packages, and recovery path
before disk erasure, then keeps a persistent recovery environment until the new
Arch system passes its first-boot checks.

> [!CAUTION]
> The recovery installer eventually erases the selected disk and every
> partition on it. Keep provider-console access available and use a disposable
> machine for the first end-to-end tests.

## Before you begin

Make an external backup of anything you need to keep. This tool does not create
or restore backups.

The source system must:

- run x86_64 Linux with systemd or OpenRC;
- have Secure Boot disabled;
- run from a normal disk-backed root, not a container or live tmpfs system;
- have exactly one physical disk behind `/`, with `/boot` and the mounted EFI
  system partition on that same disk; and
- have at least 8 GiB of disk and 512 MiB of RAM. The prepared payload may
  require more, and the review shows the calculated requirements.

BIOS and writable UEFI firmware are supported. The target must already have a
readable DOS or GPT partition table with at least one partition so its identity
can be captured and checked before erasure.

Source distributions using `apt-get`, `dnf` or `yum`, `zypper`, `apk`, or
`pacman` are recognized. Preparation reports distro-specific commands for
missing dependencies but never invokes the source package manager itself.

Windows, ARM, encrypted target layouts, RAID or multipath roots, custom or
preserved partitions, bonds, bridges, VLAN default routes, and full-disk backup
or restoration are out of scope.

## Run the guided redeploy

Run the same command to start or resume:

```bash
sudo ./arch-redeploy
# On doas-based systems such as Alpine:
doas ./arch-redeploy
```

There are no stage-named commands to remember. Each invocation returns to the
current item:

```text
Arch redeploy progress - stage 2 of 9

   1. Inspect system and capture plan
 > 2. Build and verify installer
   3. Review redeploy plan
   4. Arm one-shot boot and reboot
      -------- reboot boundary --------
   5. Revalidate disk, network, and payload
      ---- disk erasure begins here ----
   6. Create Arch layout and persistent recovery
   7. Install and configure Arch
   8. Validate target and reboot
   9. Verify first boot and remove recovery
```

Before scheduling a reboot, the tool checks the host and target disk, captures
the administrator and network settings, verifies its installer and Arch
payload, and shows the complete plan for review. It prefers a complete offline
payload so package downloads are not required after erasure. If that cannot be
built, the review clearly marks an online fallback that depends on two verified
mirrors. A source that needs a proxy or custom CA must use the offline payload.

Declining the review pauses safely. Run the bare command again to return to the
same review. Continuing requires both an ordinary confirmation and an exact
`REDEPLOY /dev/...` confirmation before the one-shot recovery boot is armed.

## Check, cancel, or recover

Operational commands are deliberately limited to:

```bash
sudo ./arch-redeploy status
sudo ./arch-redeploy cancel
./arch-redeploy help
```

Before reboot, `cancel` restores the prior boot selection and removes the files
created for this redeploy. It is safe to run again after cleanup.

After reboot, recovery restores the captured network and starts SSH on the
preserved port. The recovery login is `root`, using the captured administrator
key or password:

```bash
ssh -p <port> root@<server-address>
```

For an offline payload, the one-shot loader starts a compact Alpine image. The
recovery environment mounts the still-intact source boot filesystem read-only,
verifies the separately staged Arch root archive, and copies it into RAM before
the erase boundary. Installation remains independent of the network after
erasure without requiring firmware or GRUB to load the full archive.

Use `arch-redeploy status` to show the current stage. Follow detailed progress
with:

```bash
tail -f /arch-redeploy.log
```

Recovery repeats its disk, network, and payload checks while the source
partitions are still untouched, then provides a fixed 60-second cancellation
window. Type `cancel` on the console or run:

```bash
arch-redeploy cancel
```

An accepted cancellation reboots the untouched source OS and cleans up the
temporary boot changes.

Once erasure begins, returning to the former distro is impossible without an
external backup. Failures stop in an accessible recovery shell rather than
rebooting automatically. After the persistent recovery environment has been
installed, rebooting or running
`/usr/local/lib/arch-redeploy/install.sh` resumes the matching installation.

A power loss between the initial partition-table write and completion of the
persistent recovery bootloader still requires provider rescue media; no design
can make that small destructive interval bootable without independent storage.

## The resulting Arch system

The installer carries the selected administrator, SSH keys or password hash,
SSH port, hostname, timezone, IPv4/IPv6 configuration, routes, and DNS settings
into the new system. It installs official signed Arch packages, enables SSH and
systemd-networkd, and creates a UUID-based `fstab`.

The final Arch layout is fixed ext4:

- UEFI: GPT, 100 MiB FAT32 ESP mounted at `/efi`, and one ext4 root.
- BIOS up to 2 TiB: MBR and one bootable ext4 root.
- BIOS above 2 TiB: GPT, a BIOS-boot partition, and one ext4 root.

On its first healthy boot, Arch checks SSH and network availability before
removing the temporary recovery system. The result is recorded in
`/var/lib/arch-redeploy/result.json`.

## Project documentation

- [DESIGN.md](DESIGN.md) explains the state machine, boot transaction, payload
  verification, disk ownership, and resume model.
- [TESTING.md](TESTING.md) contains non-destructive checks and the disposable
  machine protocol for firmware, disk, rollback, and recovery testing.

## License

This project is GPL-3.0-or-later.

## Acknowledgments

This project was inspired by
[`bin456789/reinstall`](https://github.com/bin456789/reinstall), particularly
its work on disk discovery, network capture, Alpine transitions, and bootloader
handling. We are grateful to its author and contributors.
