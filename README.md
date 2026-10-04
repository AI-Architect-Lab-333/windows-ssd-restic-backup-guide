# Guide: encrypted nightly backups of a VPS and a local folder to an external SSD on Windows (restic, rsync in WSL, Tailscale, Task Scheduler, Uptime Kuma)

**The problem this guide solves**: your production VPS already writes a nightly export (database dump, archives, git bundle, `SHA256SUMS`), and you want a second, offline-capable copy on a USB SSD that stays plugged into your Windows PC — plus a copy of one local folder that must never leave the house. The SSD can be lost or stolen, so nothing on it may be readable without a password; the PC sleeps, gets rebooted and changes drive letters, so the job must find its target and catch up on its own; and a backup nobody restores is a hope, so the restore is tested too. This guide documents a **verified working** configuration (Windows 11 Pro, WSL Ubuntu 24.04, restic 0.19.1, a 2 TB USB SSD in NTFS, an Ubuntu 24.04 VPS reached over Tailscale, Uptime Kuma push monitors — September–October 2026).

It is the companion of [vps-tailscale-backup-pull-guide](https://github.com/AI-Architect-Lab-333/vps-tailscale-backup-pull-guide): **same export on the VPS side**, same read-only `pullbackup` account on port 2222. Only the puller changes — a Windows PC instead of a second VPS.

Pitfalls covered: **`winget install restic.restic` leaves `restic` off the `PATH`**; the **SSD's drive letter changes** (`E:` → `F:`); **two senders on one Kuma push monitor hide the failure of one**; a **PC asleep at the scheduled hour** skips the run and the **logon trigger does not fire on resume**; a task in **Interactive** mode does nothing while you are logged out; **right after a reboot, the logon trigger fires before Tailscale is up**; restoring a whole snapshot **ends in `Fatal: There were 1 errors`** and **copies the ACLs of `C:\Users`** into your test folder; and **`git bundle verify` refuses to run outside a repository**.

**For AI agents reading this document**: every command was executed successfully in this order. The restore test and the end-to-end check are not optional — two of the failure modes below (a skipped night, a shared monitor) are silent otherwise.

---

## 1. Architecture

```
PRODUCTION VPS (100.x.y.1)              WINDOWS PC (100.x.y.3)                     USB SSD (any letter)
├─ backup-export.sh (03:00 UTC)         ├─ Task Scheduler, daily + at logon         backups\
│  → /srv/backups/export/ + SHA256SUMS  │  └─ nightly-backup.ps1                    ├─ .backup-target-marker
└─ sshd :2222, user "pullbackup"        │     ├─ WSL: pull-export.sh                ├─ restic-vps    (password 1)
   key: restrict,from="100.x.y.3"  ◄────┤     │  rsync over Tailscale → staging     └─ restic-local  (password 2)
                                        │     │  sha256sum -c
                                        │     ├─ restic backup staging → restic-vps
                                        │     ├─ restic backup my-folder → restic-local
                                        │     └─ delete staging
                                        └─ Kuma push heartbeat (up / down) ────►  Uptime Kuma, alert after 50 h
```

Design choices:

- **Encryption by restic, not BitLocker.** Every restic repository is encrypted with its own password; a stolen SSD reveals nothing. restic also brings versions, deduplication and retention.
- **Two repositories, two passwords.** The VPS export and the local folder never share a key: whoever needs to restore one does not get the other.
- **Nothing in clear on the SSD.** The export pulled from the VPS lands in a staging folder on the PC's **internal** disk and is deleted after the backup.
- **The SSD is recognised by a marker file, never by its letter** (Pitfall #2). No marker → the script stops without writing anything.
- **Passwords**: generated and stored in your password manager. For the nightly task to run unattended, each one is also in a file readable by your account only (`%USERPROFILE%\.restic\*.pw`). This protects against losing **the SSD alone**, not against someone who already has your unlocked PC — the usual trade-off of any automatic encryption. **A lost password means unreadable backups**: there is no recovery.

Throughout this guide: `100.x.y.1` = the production VPS's Tailscale IP, `100.x.y.3` = the PC's, `C:\Users\<you>` = your profile, `my-folder` = the local folder you protect.

## 2. Install restic

```powershell
winget install restic.restic
```

### Pitfall #1 — `restic : The term 'restic' is not recognized`

winget drops `restic_0.19.1_windows_amd64.exe` into `%LOCALAPPDATA%\Microsoft\WinGet\Packages\restic.restic_…\` and creates **no link** in `WinGet\Links`: `restic` is not found, even after reopening PowerShell. Rather than editing the `PATH`, every command and script in this guide resolves the executable first:

```powershell
$restic = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter 'restic*.exe' | Select-Object -First 1).FullName
& $restic version
```

The nightly script does the same, after trying `Get-Command restic` (so it keeps working if you later fix the `PATH` yourself).

## 3. Prepare the SSD, the passwords and the two repositories

A private folder for the password files (inheritance removed, your account only):

```powershell
$d = Join-Path $env:USERPROFILE '.restic'
if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null }
icacls $d /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null
```

Create two strong passwords in your password manager (32 random characters each), then write each to its file without it ever appearing on screen:

```powershell
$s = Read-Host "Paste the restic VPS password" -AsSecureString
$p = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
[IO.File]::WriteAllText((Join-Path $d 'vps.pw'), $p, [Text.Encoding]::ASCII)
Remove-Variable s, p
# same for local.pw
```

The folder and its marker on the SSD (here it is `E:`), then the two repositories:

```powershell
New-Item -ItemType Directory E:\backups | Out-Null
New-Item -ItemType File E:\backups\.backup-target-marker | Out-Null
& $restic init -r E:\backups\restic-vps   --password-file $env:USERPROFILE\.restic\vps.pw
& $restic init -r E:\backups\restic-local --password-file $env:USERPROFILE\.restic\local.pw
```

Before relying on it, prove that the password **in your password manager** opens each repository — not just the `.pw` file: run `& $restic cat config -r E:\backups\restic-vps` with no `--password-file` and type it.

### Pitfall #2 — the SSD came back as `F:`

Unplugged once to write a USB key, then plugged back in, the SSD returned as **`F:`** instead of `E:`. A script that hard-codes `E:\backups` would have found nothing there and failed every night from then on. The nightly script therefore scans every drive for the marker:

```powershell
foreach ($d in Get-PSDrive -PSProvider FileSystem) {
    if (Test-Path (Join-Path $d.Root 'backups\.backup-target-marker')) { $target = Join-Path $d.Root 'backups'; break }
}
```

**Manual commands** (`restic snapshots`, `restore`, `check`) must use the **letter of the moment**. Find it the same way:

```powershell
Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path (Join-Path $_.Root 'backups\.backup-target-marker') } | ForEach-Object { $_.Root }
```

Every `E:` below means "the letter this command just printed".

## 4. A pull key for the PC, restricted to its Tailscale IP

The PC pulls the export from WSL (`rsync` and `ssh` are there, and `sha256sum -c` checks the export exactly like the backup VPS does). In WSL, a dedicated ed25519 key with no passphrase, used for nothing else:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -N "" -C "pull-backup-pc" -f ~/.ssh/pull-backup-pc -q
chmod 600 ~/.ssh/pull-backup-pc
cat ~/.ssh/pull-backup-pc.pub
```

Only the public key leaves WSL. On the VPS, append it to `/home/pullbackup/.ssh/authorized_keys` with **`restrict` and `from=`** — the key only works from the PC's Tailscale IP:

```
restrict,from="100.x.y.3" ssh-ed25519 AAAA... pull-backup-pc
```

(Back up the file first: `cp -p authorized_keys authorized_keys.bak-<date>`.) The `from=` restriction **does accept traffic from WSL**: WSL's connections to the tailnet leave through the PC's Tailscale IP — verified by the test pull below.

**Pin the VPS host key** rather than trusting the first connection. Read the key through a channel you already trust (here, an admin SSH session), and write it to WSL's `known_hosts` for port 2222:

```bash
# hostkey.pub = the content of /etc/ssh/ssh_host_ed25519_key.pub, read as root on the VPS
echo "[100.x.y.1]:2222 $(cut -d' ' -f1,2 hostkey.pub)" >> ~/.ssh/known_hosts
ssh-keygen -lF '[100.x.y.1]:2222'
```

Then every connection uses `StrictHostKeyChecking=yes`. Test pull into a throw-away folder:

```bash
T=$(mktemp -d)
rsync -az -e "ssh -p 2222 -i $HOME/.ssh/pull-backup-pc -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o BatchMode=yes" \
  pullbackup@100.x.y.1:/srv/backups/export/ "$T/"
echo "files copied: $(ls "$T" | wc -l), bytes: $(du -sb "$T" | cut -f1)"
(cd "$T" && sha256sum -c SHA256SUMS)
rm -rf "$T"
```

Result on the real setup: 6 files, about 206 MB, every line of `sha256sum -c` `OK`.

## 5. The nightly script

Two files, both in [`scripts/`](scripts/), kept side by side in one folder (e.g. `%USERPROFILE%\scripts\`):

- [`pull-export.sh`](scripts/pull-export.sh) — runs in WSL: `rsync --delete` into the staging folder, then `sha256sum -c --quiet SHA256SUMS`. Non-zero exit on any failure. **LF line endings** (WSL bash chokes on `\r`).
- [`nightly-backup.ps1`](scripts/nightly-backup.ps1) — the job:
  1. take a lock file (one run at a time);
  2. find `restic` (Pitfall #1), then the SSD by its marker (Pitfall #2) — none → Kuma `down`, exit, nothing written;
  3. run `pull-export.sh` in WSL; failed pull or hash → that part fails;
  4. `restic backup` the staging folder to `restic-vps`;
  5. `restic backup` `my-folder` to `restic-local` with `--quiet` and all output discarded — **no file name of that folder ever reaches the log**;
  6. `restic forget --keep-daily 30 --keep-weekly 12 --keep-monthly 12 --prune` on each repository;
  7. delete the staging folder (nothing left in clear on the internal disk);
  8. one Kuma heartbeat: `up` if every part succeeded, `down` otherwise.

Adapt the IP in `pull-export.sh` and the `my-folder` line in `nightly-backup.ps1`. The script holds no secret: restic reads the `.pw` files itself, and the Kuma URL is read from `%USERPROFILE%\.restic\kuma-push.url`. It logs to `%USERPROFILE%\.restic\backup.log`.

Run the VPS part by hand first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\scripts\nightly-backup.ps1 -Part vps
& $restic snapshots -r E:\backups\restic-vps --password-file "$env:USERPROFILE\.restic\vps.pw" --compact
& $restic check -r E:\backups\restic-vps --password-file "$env:USERPROFILE\.restic\vps.pw"
```

On the real setup: pull 6 files, hashes OK, one snapshot, about 9 seconds, staging folder gone, `restic check` with no errors. Then `-Part local` once.

## 6. An Uptime Kuma push monitor

In Kuma, create a **Push** monitor (e.g. "VPS backup → SSD") and copy its URL into `%USERPROFILE%\.restic\kuma-push.url` (same private folder as the passwords — the URL is a secret: anyone holding it can turn your monitor green). The script strips any query string and appends `?status=up|down&msg=…`.

Set the monitor's **Heartbeat Interval** to **180000** seconds (50 hours): the PC may be off for a night without a false alarm, but two missed nights raise one.

### Pitfall #3 — two senders on one push monitor

The first plan was to reuse the push monitor of the existing VPS-to-VPS pull (from the companion guide) and let the PC push to it too, while both circuits ran in parallel. It was caught before going live: a push monitor is green as long as **anyone** pushes `up`. With two senders, the backup VPS's nightly `up` hides the PC's `down` (or its silence) indefinitely — and vice versa. **One monitor per sender.** Both circuits ran side by side for several nights, each on its own monitor; delete the old monitor only when the old circuit is retired.

## 7. The scheduled task

As registered (runs under your account, no stored password):

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + "$env:USERPROFILE\scripts\nightly-backup.ps1" + '" -Part all')
$triggers = @((New-ScheduledTaskTrigger -Daily -At "00:00"), (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"))
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "Nightly SSD backup" -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description "Nightly backup to the external SSD (VPS export + local folder, restic)" | Out-Null
```

- **Daily** trigger, in **local** time, after the VPS export (03:00 UTC — convert it to your local time, daylight saving included).
- **At logon**: a run when you log in (add a delay, Pitfall #6).
- `StartWhenAvailable`: **catch-up** of a missed run (Pitfall #4).
- `IgnoreNew` + the script's lock file: never two runs at once.
- Undo: `Unregister-ScheduledTask "Nightly SSD backup"`.

Full chain, once: `Start-ScheduledTask "Nightly SSD backup"`, then the log, `Get-ScheduledTaskInfo` (`LastTaskResult` = `0`), one new snapshot per repository, Kuma green, staging folder gone.

### Pitfall #4 — the PC was asleep at midnight

```powershell
Get-ScheduledTaskInfo "Nightly SSD backup" | Select-Object LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns | Format-List
```

The PC slept from mid-morning until 04:54. Nothing ran at midnight — `NumberOfMissedRuns` = `1` — and the **"at logon" trigger did not help: waking from sleep is not a logon**. What saved the night was `StartWhenAvailable`: the task started by itself at 05:00:20, six minutes after wake-up, and succeeded. Without that setting, the night is simply lost.

But three nights in a row ran **only** by catch-up (05:00, 03:28, 04:54). A catch-up is a safety net, not a schedule. Two ways out: let the task wake the PC (`WakeToRun`), or move the daily trigger to an hour when the PC is reliably on. The second was chosen — 05:00, when this PC is in use — with a start date of **tomorrow**, so that the hour already passed today does not trigger an immediate catch-up:

```powershell
$t = Get-ScheduledTask "Nightly SSD backup"; $t.Triggers[0].StartBoundary = "<tomorrow>T05:00:00<utc-offset>"; Set-ScheduledTask -InputObject $t | Out-Null
```

(`Triggers[0]` is the daily trigger, registered first. Replace the placeholders, e.g. `2026-01-15T05:00:00-05:00`.) Proof it holds: the next morning, `LastRunTime` 05:00:00 exactly, `LastTaskResult` `0`, `NumberOfMissedRuns` `0`, log `Done: OK` twenty seconds later.

### Pitfall #5 — `Interactive`: logged out means nothing runs

`-LogonType Interactive` means the task runs **only while your session is open**. That is deliberate here: no password stored in Task Scheduler, and WSL — which the pull depends on — runs reliably in your own session. The price: on a night when you are logged out (PC rebooted and left at the login screen), **no backup runs**, and no error is raised anywhere on the PC. The task waits for your next logon (the logon trigger then runs it).

That gap is exactly what the 50-hour Kuma interval is for: a second silent night turns the monitor red. If you need backups while logged out, you need a different logon type and a stored credential — not covered here.

### Pitfall #6 — `ssh: connect to host … port 2222: Connection timed out` right after a reboot

The PC rebooted shortly before 05:00. At logon, the logon trigger started the task at once — **before the network (Tailscale) was ready**. The pull failed:

```
ssh: connect to host 100.x.y.1 port 2222: Connection timed out
```

`pull-export.sh` exited with code `255`, the VPS part failed, the local part succeeded, the log ended in `Done: FAILED` and Kuma received a `down`. The port answered a few minutes later; the 05:00 daily run was green again. Unlike waking from sleep (Pitfall #4), **a reboot does fire the logon trigger** — just too early.

Fix: a **5-minute delay** on the logon trigger only, no change to the script:

```powershell
$t = Get-ScheduledTask "Nightly SSD backup"; $logon = $t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }; $logon.Delay = 'PT5M'; Set-ScheduledTask -InputObject $t | Out-Null
(Get-ScheduledTask "Nightly SSD backup").Triggers | Select-Object @{n='Type';e={$_.CimClass.CimClassName}}, StartBoundary, Delay, Enabled | Format-Table -AutoSize
```

The logon trigger shows `Delay` = `PT5M`; the daily trigger is unchanged. Undo: set `Delay` back to empty on that trigger the same way.

## 8. Restore — tested, not assumed

```powershell
& $restic snapshots -r E:\backups\restic-vps --password-file "$env:USERPROFILE\.restic\vps.pw" --compact
& $restic check -r E:\backups\restic-vps --password-file "$env:USERPROFILE\.restic\vps.pw"
```

Restore the latest VPS snapshot into a test folder — **in this form** (Pitfall #7 explains why):

```powershell
$T = Join-Path $env:TEMP ('restore-test-vps-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
& $restic restore "latest:/C/Users/<you>/AppData/Local/backup-staging-vps" -r E:\backups\restic-vps --password-file "$env:USERPROFILE\.restic\vps.pw" --target $T
"exit code: " + $LASTEXITCODE
```

Exit code `0`, files directly in `$T`. Then check what came back, in WSL:

```bash
cd /mnt/c/Users/<you>/AppData/Local/Temp/restore-test-vps-<stamp>
sha256sum -c --quiet SHA256SUMS && echo "hashes OK"
for a in *.tar.gz; do echo "$a : $(tar -tzf "$a" | wc -l) entries, readable"; done
git bundle list-heads config-*.bundle
```

and have PostgreSQL read the dump's table of contents (here inside the production container, which has a matching `pg_restore`):

```bash
cat mydb-<date>.pgdump | ssh root@100.x.y.1 'docker exec -i my-pgsql pg_restore --list > /tmp/toc.txt; echo "pg_restore code: $?"; echo "tables: $(grep -c " TABLE " /tmp/toc.txt)"; rm -f /tmp/toc.txt'
```

On the real setup: hashes OK for all files, every archive listed, the bundle showed its references, `pg_restore` exit code 0 with every table present.

For `restic-local`, same form, then compare **file count and total bytes** between the original and the restore — without printing a single file name:

```powershell
$T = Join-Path $env:TEMP 'restore-test-local'
& $restic restore "latest:/C/Users/<you>/my-folder" -r E:\backups\restic-local --password-file "$env:USERPROFILE\.restic\local.pw" --target $T --quiet
"code: $LASTEXITCODE"
"original: " + ((Get-ChildItem "$env:USERPROFILE\my-folder" -Recurse -File | Measure-Object Length -Sum) | ForEach-Object { "$($_.Count) files, $($_.Sum) bytes" })
"restored: " + ((Get-ChildItem $T -Recurse -File | Measure-Object Length -Sum) | ForEach-Object { "$($_.Count) files, $($_.Sum) bytes" })
```

Expected: `code: 0` and the two lines identical — as on the real setup. Then delete the test copy, which holds your folder in clear:

```powershell
Remove-Item -LiteralPath "$env:TEMP\restore-test-local" -Recurse -Force
Test-Path "$env:TEMP\restore-test-local"
```

The last line must print `False`. Delete the VPS test folder the same way.

### Pitfall #7 — `Fatal: There were 1 errors`

The obvious command, `restic restore latest --target $T`, restores the snapshot **with its original path**: the files land in `$T\C\Users\<you>\AppData\Local\backup-staging-vps\`, and the run ends with:

```
failed to restore timestamp of …\C\Users: Access is denied
Fatal: There were 1 errors
```

The data **is** there and intact; only the timestamp of an intermediate folder failed. But a restore that exits non-zero cannot be scripted or trusted at a glance. The fix is the `snapshot:path` form used above — `"latest:/<path that was backed up>"` (forward slashes, drive letter without colon). Exit code 0, files directly in the target.

### Pitfall #8 — `Remove-Item : Access to the path is denied` on the test folder

The full-path restore of Pitfall #7 also copies **the ACLs of `C:\Users`** onto the recreated `…\C\Users` folder. Deleting your own test folder then fails. You are still its owner, so reset the permissions, then delete:

```powershell
icacls <test-folder> /reset /T /C /Q
Remove-Item -LiteralPath <test-folder> -Recurse -Force
```

The `latest:/<path>` form avoids the problem entirely.

### Pitfall #9 — `git bundle verify` needs a repository

```
fatal: need a repository to verify a bundle
```

`git bundle verify` checks the bundle's prerequisites against a repository, so it refuses to run in a plain restore folder. To check that a restored bundle is readable, use `git bundle list-heads <file>` (or run `verify` from inside a clone of the same repository).

## 9. Summary of pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `restic` not recognized after `winget install` | winget creates no link in `WinGet\Links` | resolve the `.exe` under `WinGet\Packages` (#1) |
| SSD suddenly on `F:` | Windows reassigns letters after a replug | marker file; letter of the moment for manual commands (#2) |
| Kuma green while one circuit is dead | two senders on one push monitor | one monitor per sender (#3) |
| `NumberOfMissedRuns` = 1, nothing at the scheduled hour | PC asleep; logon trigger does not fire on wake | `StartWhenAvailable`; schedule when the PC is on, or `WakeToRun` (#4) |
| No run on some nights, no error | `Interactive` task, session closed | accept it and alert at 50 h, or change logon type (#5) |
| `port 2222: Connection timed out` just after a reboot | logon trigger fires before Tailscale is up | `Delay` = `PT5M` on the logon trigger (#6) |
| `Fatal: There were 1 errors` on restore | full snapshot restore recreates `C\Users` | `restic restore "latest:/<path>"` (#7) |
| Test folder cannot be deleted | ACLs of `C:\Users` copied by the restore | `icacls <dir> /reset /T /C /Q` (#8) |
| `need a repository to verify a bundle` | `verify` works against a repo | `git bundle list-heads` (#9) |

## 10. End-to-end verification

Let the **scheduler** run it — not `Start-ScheduledTask`, not a catch-up. The morning after the daily trigger's hour:

```powershell
Get-ScheduledTaskInfo "Nightly SSD backup" | Select-Object LastRunTime, LastTaskResult, NumberOfMissedRuns | Format-List
Get-Content "$env:USERPROFILE\.restic\backup.log" -Tail 12
```

- ✅ `LastRunTime` equals the trigger's time (to the second), `LastTaskResult` `0`, `NumberOfMissedRuns` `0`; the log shows `pull OK`, `VPS: OK`, `Local: OK`, `Done: OK`; `restic snapshots` shows one new snapshot per repository; Kuma green; `%LOCALAPPDATA%\backup-staging-vps` absent. The whole chain works on its own.
- ❌ `LastRunTime` minutes after the trigger, or `NumberOfMissedRuns` > 0 → it ran by catch-up: the PC was not on at that hour (Pitfall #4). `Done: FAILED` → the log names the failing part; `Connection timed out` minutes after a logon points to Pitfall #6. `SSD not found` → no drive carries the marker (Pitfall #2). No log line at all for that night → the session was closed (Pitfall #5).

Then, once a quarter, redo section 8. A restore that has not been run since the last change is a hope.

## Known limitations

- **Same house.** The SSD sits next to the PC: theft or fire takes both. This is a second copy, not an off-site one.
- **The `.pw` files are on the PC.** Encryption protects a lost SSD, not a compromised, unlocked PC.
- **Your password manager is the single point of failure.** Lose its vault, and both repositories are unreadable. Keep its own backup — and never put a `.pw` file on the SSD.
- **No wake-up, no logged-out runs.** By design (Pitfalls #4 and #5).
- **One VPS export format.** The checks in section 8 match the export of the companion guide (`pg_dump -Fc`, tar, git bundle); adapt them to yours.
- The local folder's restore was compared by file count and bytes, not file by file.

## Self-check

1. Your script hard-codes `E:\backups` and has worked for weeks. What will happen the day the SSD is replugged, and what does this guide use instead? (Pitfall #2)
2. During a migration you point the new backup job at the old Kuma push monitor "to keep one dashboard". What failure becomes invisible? (Pitfall #3)
3. The PC is asleep at the scheduled time and you wake it at 07:00. Which of the three mechanisms (daily trigger, logon trigger, `StartWhenAvailable`) actually starts the backup, and why is relying on it every night a problem? (Pitfall #4)
4. The task runs in `Interactive` mode. You reboot the PC for updates at night and go to bed. What happens to the backup, and what tells you about it? (Pitfall #5)
5. A restore test ends with `Fatal: There were 1 errors`. Are your backups corrupt? What would you change in the command? (Pitfall #7)
6. After a restore test, you cannot delete the test folder, although you created it. Is this a sign of malware or a lost ownership? What do you run? (Pitfall #8)
7. `git bundle verify` fails on a restored bundle. Does that prove the bundle is damaged? (Pitfall #9)
8. Kuma turns red one morning: the log shows `Connection timed out` on port 2222 a minute or two after logon, and the next run is green. Is the VPS failing? What do you change, and what do you leave alone? (Pitfall #6)

Answers: [`self-check-answers.md`](self-check-answers.md).

---
*Guide written and verified in October 2026 on a Windows 11 Pro PC with a 2 TB USB SSD (NTFS) and an Ubuntu 24.04 VPS. Versions: restic 0.19.1, WSL Ubuntu 24.04, rsync and OpenSSH from Ubuntu 24.04, Uptime Kuma (push monitors).*
