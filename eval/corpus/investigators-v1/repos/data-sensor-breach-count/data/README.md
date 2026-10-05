# cold-chain monitoring

- `sensors.json`: each sensor's id, location and `threshold_c` in degrees
  Celsius.
- `readings-day1.csv` and `readings-day2.csv`: `sensor_id,reading`. Readings
  are integers in **tenths of a degree Celsius** (so `82` means 8.2 C).

A breach is a reading strictly above the sensor's threshold.
