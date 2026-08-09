# Testing

Local checks are intentionally block-device-free. Firmware boot and destructive
disk tests belong on a separate disposable machine.

## Local non-destructive checks

The normal check runs syntax checks, ShellCheck, state and timeline tests,
rollback tests, network generation tests, and release-key verification:

```bash
./scripts/check.sh
```

It does not change firmware, touch a block device, or run QEMU.

An optional disposable-container smoke test verifies the live signed Alpine
release, Arch keyring, package transaction, and builder without a block device:

```bash
docker build --network host -f scripts/Dockerfile.smoke -t arch-redeploy-smoke-runner .
docker run --rm --cap-add SYS_ADMIN --security-opt seccomp=unconfined --network host \
  -v "$PWD:/project:ro" arch-redeploy-smoke-runner
```

Add `-e RA_SMOKE_FULL=1` to `docker run` to build and configure a complete Arch
root archive. This remains a builder test, not a boot or disk test.

## Separate-machine destructive protocol

Do not run these tests on a machine containing data you care about. QEMU,
firmware boot, and destructive disk tests are deferred to a separate machine.

## Before testing

1. Use a disposable VM or server with provider-console access and a new test
   disk. Record its serial, firmware mode, and source image.
2. Snapshot the machine before starting.
3. Confirm no host or valuable block device is passed through.
4. Preinstall the prerequisites reported by `./arch-redeploy`; the tool itself
   must never invoke the source package manager.
5. Start with an SSH public key rather than a production password hash.

## Minimum matrix

| Source family | Firmware | Payload |
| --- | --- | --- |
| Debian/Ubuntu (`apt-get`) | SeaBIOS | offline |
| Fedora/RHEL (`dnf`/`yum`) | OVMF | offline |
| openSUSE (`zypper`) | SeaBIOS | online fallback |
| Alpine (`apk`) | OVMF | online fallback |
| Arch (`pacman`) | SeaBIOS | offline |

For each run, invoke only:

```bash
sudo ./arch-redeploy
```

Before accepting the review, inspect the timeline, disk identity, SSH access,
network addresses, mirror order, payload mode, and artifact sizes. Run the same
bare command again after any intentional pause and confirm it resumes the same
current item without duplicating work.

## Pre-erasure rollback cases

- Interrupt inspection and preparation, rerun, and confirm invalid temporary
  output is rebuilt while verified artifacts are reused.
- Cancel twice during preparation; both calls must leave normal boot intact.
- Interrupt BIOS/UEFI scheduling before and after every pending-state write.
  Rerun the bare command and confirm it rolls back before offering review.
- Begin with an existing GRUB `next_entry` or UEFI BootNext. Cancel and confirm
  the exact prior selection is restored.
- Modify a scheduled boot configuration externally. Cancellation must remove
  only the owned block and preserve the external change.
- Reboot into recovery, cancel during validation and during the 60-second
  countdown, and confirm the source OS boots and its return hook removes all
  owned files, services, selectors, and firmware entries.
- Race `arch-redeploy cancel` over SSH against the end of the countdown.
  Exactly one outcome is allowed: clean source return or committed erasure.
- Make every mirror unreachable, corrupt an artifact, or change the source
  partition table. Continuation must stop before erasure.

## Post-erasure resume cases

- Send termination signals before and after each recovery checkpoint, rerun the
  installer, and confirm only the matching install ID is resumed.
- Fail immediately after partition creation, filesystem creation, recovery-file
  copy, and bootloader installation. A retry in the running recovery shell must
  repair the owned partial layout without treating it as the source layout.
- Power-cycle after persistent recovery is installed and confirm recovery boot
  resumes without repartitioning.
- In offline mode, disable networking after installer SSH is observed and
  confirm installation continues from console without package URLs.
- In online mode, fail the first mirror and confirm rotation to the second;
  then fail all mirrors and confirm recovery remains accessible.
- Run target installation and configuration twice. Confirm there are no
  duplicate users, addresses, routes, GRUB kernel arguments, services, or UEFI
  entries.
- Block UEFI NVRAM writes and verify the removable `EFI/BOOT/BOOTX64.EFI`
  fallback reaches both recovery and final Arch.
- Present a foreign or modified partial layout and confirm the installer stops
  rather than claiming or formatting it.

The unavoidable power-loss window between the first destructive partition
write and a bootable persistent recovery installation must also be measured.
Recovery from that interval requires the provider rescue environment.

## Success checks

After final boot:

```bash
test -f /etc/arch-release
uname -m
findmnt /
systemctl is-active systemd-networkd systemd-resolved sshd
sshd -t
grep -R 'SigLevel = Required' /etc/pacman.conf
cat /var/lib/arch-redeploy/result.json
```

Confirm preserved SSH access and port, hostname/timezone, IPv4/IPv6 routes,
UUID-based `fstab`, expected BIOS/UEFI boot, serial-console output, and absence
of a swapfile. After first-boot cleanup, confirm the recovery directory, its
GRUB entry, temporary return hooks, and stale recovery firmware entries are
absent.
