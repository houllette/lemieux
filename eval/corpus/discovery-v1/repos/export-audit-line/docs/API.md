# Library API

## lib/audit.sh - the audit trail

Every action that touches customer records leaves a line in the audit log
(`AUDIT_LOG`, default `var/audit.log`). Compliance parses that log, so the
line format is fixed: `SEQ CATEGORY MESSAGE`, where `SEQ` is a zero-padded
four-digit sequence number kept in `AUDIT_LOG.seq`.

There is exactly one supported entry point:

- `audit_emit CATEGORY MESSAGE` - appends a correctly numbered line. Use
  this from all new code. `CATEGORY` is lower-case; exports use the
  category `export`.

The other functions in the file exist for older tools and must not be
called from new code:

- `audit_log MESSAGE` - **deprecated.** Writes the pre-2025 `[LEGACY]`
  format that the current compliance parser rejects. Kept only until the
  legacy importer is retired.
- `audit_write LINE` - **internal.** Appends LINE verbatim with no sequence
  number; it is the primitive `audit_emit` is built on.

## lib/records.sh

- `records_to_csv FILE` prints the records in FILE as CSV, header first.
- `record_ids FILE` prints the id of every record in FILE, one per line.
