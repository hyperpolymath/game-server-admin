#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# CryoFall world backup script
#
# Invoked by GSA via the A2ML profile `backup` action:
#   podman exec cryofall /scripts/backup.sh
#
# Creates a timestamped tar.gz archive of the world Saves directory into
# /data/backups/.  GSA tracks backup metadata in VeriSimDB (port 8091,
# the backup instance defined in container/verisimdb-backup/).
#
# Retention: keeps the 10 most recent backups; older archives are pruned
# automatically so the volume does not grow unbounded.

set -e

DATA_DIR="${CRYOFALL_DATA_DIR:-/data/cryofall}"
BACKUP_DIR="${CRYOFALL_BACKUP_DIR:-/data/backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE="${BACKUP_DIR}/cryofall-${TIMESTAMP}.tar.gz"
RETENTION=10  # keep this many recent backups

# Ensure backup directory exists
mkdir -p "${BACKUP_DIR}"

echo "[gsa-cryofall-backup] Creating world backup: ${ARCHIVE}"
tar -czf "${ARCHIVE}" -C "${DATA_DIR}" Saves

ARCHIVE_SIZE=$(du -sh "${ARCHIVE}" | cut -f1)
echo "[gsa-cryofall-backup] Archive complete: ${ARCHIVE_SIZE}"

# Prune archives older than the retention limit (sorted by modification time)
ARCHIVE_COUNT=$(ls -t "${BACKUP_DIR}"/cryofall-*.tar.gz 2>/dev/null | wc -l)
if [ "${ARCHIVE_COUNT}" -gt "${RETENTION}" ]; then
    TO_DELETE=$(ls -t "${BACKUP_DIR}"/cryofall-*.tar.gz | tail -n +"$((RETENTION + 1))")
    echo "[gsa-cryofall-backup] Pruning ${ARCHIVE_COUNT} archives to ${RETENTION} (removing $(echo "${TO_DELETE}" | wc -l) old)"
    # shellcheck disable=SC2086
    rm -f ${TO_DELETE}
fi

REMAINING=$(ls "${BACKUP_DIR}"/cryofall-*.tar.gz 2>/dev/null | wc -l)
echo "[gsa-cryofall-backup] Backup done. ${REMAINING} archive(s) retained."
