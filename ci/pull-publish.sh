#!/bin/sh
# The daily-pull workflow's pull-and-publish step. Needs GH_TOKEN with
# contents: write; the archive is metro.db.gz on the release tagged archive.
set -e
export PATH="$PWD/.venv/bin:$PATH" DB=raw_data/metro.db
mkdir -p raw_data

# Restore the published archive; a crashed publish leaves metro.db.new.gz.
if gh release download archive --pattern metro.db.gz --output metro.db.gz --clobber 2>/dev/null && [ -s metro.db.gz ]; then
  :
elif gh release download archive --pattern metro.db.new.gz --output metro.db.gz --clobber 2>/dev/null && [ -s metro.db.gz ]; then
  echo "recovered from interrupted publish"
else
  echo "ERROR: no metro.db.gz on release 'archive'; aged-out records cannot be recovered"
  exit 1
fi
gunzip -c metro.db.gz > "$DB" && rm metro.db.gz
echo "restored $(du -h "$DB" | cut -f1)"

counts() {
  sqlite3 -noheader -separator ' ' "$DB" \
    "SELECT source, COUNT(*) FROM incidents GROUP BY source ORDER BY source"
  sqlite3 -noheader -separator ' ' "$DB" \
    "SELECT source || '+amend', COUNT(*) FROM incident_amendments GROUP BY source ORDER BY source" 2>/dev/null || true
  sqlite3 -noheader -separator ' ' "$DB" \
    "SELECT source || '+raw', COUNT(*) FROM raw_records GROUP BY source ORDER BY source" 2>/dev/null || true
  sqlite3 -noheader -separator ' ' "$DB" \
    "SELECT agency || '+search', COUNT(*) FROM alpr_searches GROUP BY agency ORDER BY agency" 2>/dev/null || true
}
counts > before.txt
cat before.txt

# OPD amends records filed months ago; sweep the whole feed on Sundays.
if [ "$(date -u +%u)" = "7" ]; then
  echo "full sweep"
  python ingest.py --full opd sarpy cbpd alpr flock opd_archive
else
  # The default set, spelled out: Python 3.14's argparse rejects an empty
  # list against choices, so a bare call errors before it pulls anything.
  python ingest.py opd sarpy cbpd alpr flock
fi

counts > after.txt
cat after.txt
test -s after.txt || { echo "ERROR: archive is empty"; exit 1; }
awk -v first=before.txt '
     FILENAME == first { was[$1] = $2; next }
     { now[$1] = $2 }
     END {
       for (s in was)
         if (now[s] + 0 < was[s] + 0) {
           printf "ERROR: %s lost rows: %d -> %d\n", s, was[s], now[s]
           bad = 1
         }
       exit bad
     }' before.txt after.txt

# An amendment identical to its original means the digest drifted.
phantom=$(sqlite3 -noheader "$DB" "
  SELECT COUNT(*) FROM incident_amendments a
  JOIN incidents o ON o.source = a.source AND o.source_key = a.source_key
  WHERE a.agency IS o.agency AND a.case_id IS o.case_id
    AND a.occurred_at IS o.occurred_at AND a.category IS o.category
    AND a.call_type IS o.call_type AND a.disposition IS o.disposition
    AND a.offense_desc IS o.offense_desc AND a.is_stop IS o.is_stop
    AND a.address IS o.address AND a.lat IS o.lat AND a.lon IS o.lon")
if [ "$phantom" -ne 0 ]; then
  echo "ERROR: $phantom amendments are identical to their original"
  exit 1
fi

# Publish. The .new asset makes the sequence crash-safe: at every
# point at least one asset holds the full archive.
sqlite3 "$DB" "VACUUM;"
gzip -c "$DB" > metro.db.gz
cp metro.db.gz metro.db.new.gz
gh release delete-asset archive metro.db.new.gz --yes 2>/dev/null || true
gh release upload archive metro.db.new.gz
gh release upload archive metro.db.gz --clobber
gh release delete-asset archive metro.db.new.gz --yes
rm metro.db.gz metro.db.new.gz
{
  echo "SQLite archive of Omaha metro police incident feeds, rebuilt twice daily."
  echo "Sarpy County and Council Bluffs publish a rolling 12-month window,"
  echo "so this holds records their own feeds no longer serve."
  echo
  echo "Updated $(date -u '+%Y-%m-%d %H:%M UTC'). Schema: schema.sql."
  echo
  echo "incidents holds each record as first published; every later"
  echo "version the feed served is a row in incident_amendments"
  echo "($(sqlite3 -noheader "$DB" 'SELECT COUNT(*) FROM incident_amendments') so far)."
  echo
  echo '```'
  sqlite3 -header -column "$DB" \
    "SELECT agency, COUNT(*) AS rows, SUM(is_stop) AS stops,
            MIN(occurred_at) AS earliest, MAX(occurred_at) AS latest
     FROM incidents GROUP BY agency ORDER BY rows DESC"
  echo '```'
} > notes.md
gh release edit archive --title 'Incident archive' --notes-file notes.md
rm notes.md
echo "archive published"
