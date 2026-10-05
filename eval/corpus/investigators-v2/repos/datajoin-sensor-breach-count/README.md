# Telemetry export

Rules:

1. `readings/<sensor>/<day>.csv` holds `value_tenths`, the reading in tenths
   of a unit. A reading breaches when its calibrated value is strictly
   greater than the site threshold in effect at the reading's timestamp.
2. Calibration: add `offset_tenths` from `calibration/offsets.csv` to the
   raw value for readings on or after the offset's `effective_from`.
3. Thresholds: `thresholds/sites.csv` gives each site's threshold in whole
   units; `thresholds/changes.csv` lists changes, effective from the date
   given (inclusive). The site's sensors are listed in `sites/<site>.json`.
