# Self-check answers

Answers to the questions at the end of the [README](README.md). Same numbering.

1. **The hard-coded letter.** After a replug, Windows may give the SSD another letter (`E:` became `F:` in the real setup). The script then finds no `E:\backups` and fails every night until someone notices. This guide never trusts the letter: the script scans every drive for the marker file `backups\.backup-target-marker` and writes nothing if it is absent. Manual commands use the letter found the same way, at the moment you run them. (Pitfall #2)

2. **Two senders, one monitor.** A push monitor is green as long as *some* sender pushes `up` within the interval. With the old job and the new job on the same monitor, either one can be dead for weeks while the other keeps it green. One monitor per sender; retire the old monitor together with the old job. (Pitfall #3)

3. **Who starts the backup after sleep.** Not the daily trigger (its time passed while the PC slept), and not the logon trigger (waking from sleep is not a logon). `StartWhenAvailable` starts it, a few minutes after wake-up, and `NumberOfMissedRuns` records the missed run. Relying on it every night means your backup runs at an unpredictable time, and only if the PC wakes at all; a catch-up is a net, not a schedule. Schedule the task when the PC is reliably on, or let it wake the PC. (Pitfall #4)

4. **Interactive task, reboot, bed.** Nothing runs: in `Interactive` mode the task needs your session open, and after a reboot nobody has logged on. Nothing on the PC reports it. The task runs when you next log on (logon trigger). If you stay logged out long enough, the Kuma push monitor — set to 50 hours — turns red. (Pitfall #5)

5. **`Fatal: There were 1 errors` on restore.** No: with a full snapshot restore, the data is restored intact; the error is restic failing to set the timestamp of the recreated `C\Users` folder in the target. Restore the backed-up folder directly instead: `restic restore "latest:/<path that was backed up>" --target <dir>` — exit code 0, files directly in the target. (Pitfall #7)

6. **Undeletable test folder.** Neither. The full-path restore copied the permissions of `C:\Users` onto the recreated folder; you are still the owner. `icacls <dir> /reset /T /C /Q`, then `Remove-Item`. The `latest:/<path>` form avoids it. (Pitfall #8)

7. **`git bundle verify` failing.** No. Run outside a git repository, `verify` refuses to work at all ("need a repository to verify a bundle") — it says nothing about the file. Use `git bundle list-heads <file>` to prove the bundle is readable, or run `verify` from inside a clone of the same repository. (Pitfall #9)

8. **Red after a reboot.** Not necessarily: if the PC had just rebooted, the logon trigger started the task before the network (Tailscale) was up, so the SSH connection to the VPS timed out. Check the log's timestamp against the logon time. Add a delay (`PT5M`) to the logon trigger only; leave the script, the daily trigger and the VPS alone. (Pitfall #6)
