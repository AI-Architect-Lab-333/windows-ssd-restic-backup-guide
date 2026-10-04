#!/bin/bash
# Runs inside WSL (Ubuntu 24.04). Pulls the production export into $1 and verifies its SHA-256 sums.
# Exits non-zero on any failure. Uses the dedicated key ~/.ssh/pull-backup-pc and the pinned host key.
set -euo pipefail
DEST="$1"
mkdir -p "$DEST"
rsync -a --no-perms --no-owner --no-group --delete \
  -e "ssh -p 2222 -i $HOME/.ssh/pull-backup-pc -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=30" \
  pullbackup@100.x.y.1:/srv/backups/export/ "$DEST/"
cd "$DEST"
sha256sum -c --quiet SHA256SUMS
echo "pull OK: $(ls | wc -l) files, $(du -sb . | cut -f1) bytes"
