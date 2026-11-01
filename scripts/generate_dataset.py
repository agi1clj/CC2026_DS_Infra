#!/usr/bin/env python3
"""Generate the CC2026 P2 energy dataset (standard library only, deterministic).

    python3 generate_dataset.py                      # writes ./energy_readings.csv (525,600 rows)
    python3 generate_dataset.py --sample             # also writes energy_sample.csv, energy_invalid.csv and energy_too_dirty.csv
    python3 generate_dataset.py --expected-gold DIR  # also writes the expected gold JSON files to DIR

Same devices as the P1 mock data (device-001 .. device-005). One reading every 5 minutes
for 365 days (2025-11-01 .. 2026-10-31). About 1% of the rows are dirty on purpose
(duplicates, missing or negative kWh, impossible humidity or temperature): the silver layer removes them.
"""

import argparse
import csv
import json
import math
import random
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

START = datetime(2025, 11, 1, tzinfo=timezone.utc)
DAYS = 365
STEP = timedelta(minutes=5)
SEED = 2026
HEADER = ["device_id", "timestamp", "temperature", "humidity", "kwh", "location"]

# device_id -> (location, base load in kWh per 5 minutes, daytime swing, weekend factor)
DEVICES = {
    "device-001": ("Office-A", 0.040, 0.060, 0.35),
    "device-002": ("Server-Room", 0.180, 0.020, 0.98),
    "device-003": ("Lab", 0.060, 0.090, 0.50),
    "device-004": ("Cafeteria", 0.030, 0.110, 0.60),
    "device-005": ("Workshop", 0.020, 0.140, 0.25),
}

# Silver rules. The ETL job in each cloud applies the same rules.
MAX_HUMIDITY = 100.0
TEMPERATURE_RANGE = (-40.0, 60.0)


def clean_rows(rows):
    """Silver layer: drop missing or negative kWh and impossible values, then duplicates.

    Filtering comes first so a dirty copy of a reading can never replace the good one.
    """
    seen = set()
    for row in rows:
        key = (row["device_id"], row["timestamp"])
        kwh = row["kwh"]
        if kwh in (None, "") or float(kwh) < 0:
            continue
        if not 0 <= float(row["humidity"]) <= MAX_HUMIDITY:
            continue
        if not TEMPERATURE_RANGE[0] <= float(row["temperature"]) <= TEMPERATURE_RANGE[1]:
            continue
        if key in seen:
            continue
        seen.add(key)
        yield row


def generate_rows(rng):
    steps = int(timedelta(days=DAYS) / STEP)
    for device_id, (location, base, swing, weekend) in DEVICES.items():
        for i in range(steps):
            ts = START + i * STEP
            hour = ts.hour + ts.minute / 60
            day_of_year = ts.timetuple().tm_yday
            daytime = max(0.0, math.sin((hour - 6) / 12 * math.pi))  # 0 at night, 1 at noon
            factor = weekend if ts.weekday() >= 5 else 1.0
            outdoor = 10 - 13 * math.cos((day_of_year - 15) / 365 * 2 * math.pi)
            temperature = round(21 + 0.15 * (outdoor - 10) + 2.0 * daytime + rng.gauss(0, 0.4), 2)
            humidity = round(min(85, max(25, 55 - 0.6 * (temperature - 21) + rng.gauss(0, 3))), 2)
            heating = max(0.0, 18 - outdoor) * 0.0015 if device_id != "device-002" else 0.0
            kwh = round(max(0.001, (base + swing * daytime * factor + heating) * rng.uniform(0.9, 1.1)), 4)
            yield {
                "device_id": device_id,
                "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "temperature": temperature,
                "humidity": humidity,
                "kwh": kwh,
                "location": location,
            }


def make_dirty(rows, rng):
    """About 1% bad rows: duplicates, missing kWh, negative kWh, impossible humidity or temperature."""
    for row in rows:
        yield row
        roll = rng.random()
        if roll < 0.004:
            yield dict(row)  # exact duplicate
        elif roll < 0.009:
            yield {**row, "kwh": ""}  # same key, no value: the clean copy above is the duplicate to keep
        elif roll < 0.011:
            yield {**row, "kwh": -abs(row["kwh"])}
        elif roll < 0.013:
            yield {**row, "humidity": 140.0}
        elif roll < 0.014:
            yield {**row, "temperature": -999.0}


def write_csv(path, rows, header=HEADER):
    count = 0
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=header, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
            count += 1
    return count


def write_expected_gold(directory, raw_rows):
    """The three gold files the pipeline must produce from the full dataset."""
    directory.mkdir(parents=True, exist_ok=True)
    daily = defaultdict(lambda: {"kwh": 0.0, "temp": 0.0, "hum": 0.0, "n": 0})
    by_location = defaultdict(lambda: {"kwh": 0.0, "devices": set(), "days": set()})
    latest = []
    for row in clean_rows(raw_rows):
        day = row["timestamp"][:10]
        key = (row["device_id"], row["location"], day)
        kwh = float(row["kwh"])
        bucket = daily[key]
        bucket["kwh"] += kwh
        bucket["temp"] += float(row["temperature"])
        bucket["hum"] += float(row["humidity"])
        bucket["n"] += 1
        loc = by_location[row["location"]]
        loc["kwh"] += kwh
        loc["devices"].add(row["device_id"])
        loc["days"].add(day)
        latest.append(row)

    daily_out = [
        {
            "device_id": device_id,
            "location": location,
            "date": day,
            "total_kwh": round(b["kwh"], 3),
            "avg_temperature": round(b["temp"] / b["n"], 2),
            "avg_humidity": round(b["hum"] / b["n"], 2),
            "readings": b["n"],
        }
        for (device_id, location, day), b in sorted(daily.items())
    ]
    location_out = [
        {
            "location": location,
            "total_kwh": round(b["kwh"], 3),
            "devices": len(b["devices"]),
            "avg_kwh_per_day": round(b["kwh"] / len(b["days"]), 3),
        }
        for location, b in sorted(by_location.items())
    ]
    latest.sort(key=lambda r: (r["timestamp"], r["device_id"]), reverse=True)
    latest_out = [
        {**row, "temperature": float(row["temperature"]), "humidity": float(row["humidity"]), "kwh": float(row["kwh"])}
        for row in latest[:200]
    ]
    for name, data in (
        ("daily_energy_by_device.json", daily_out),
        ("energy_by_location.json", location_out),
        ("latest_readings.json", latest_out),
    ):
        (directory / name).write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
        print(f"{directory / name}: {len(data)} records")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=Path("."), help="output directory (default: current directory)")
    parser.add_argument("--sample", action="store_true", help="also write energy_sample.csv, energy_invalid.csv and energy_too_dirty.csv")
    parser.add_argument("--expected-gold", type=Path, help="write the expected gold JSON files to this directory")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    rng = random.Random(SEED)
    rows = list(make_dirty(generate_rows(rng), rng))
    count = write_csv(args.out / "energy_readings.csv", rows)
    print(f"{args.out / 'energy_readings.csv'}: {count} rows")

    if args.sample:
        first_day = [r for r in rows if r["timestamp"].startswith("2025-11-01")]
        count = write_csv(args.out / "energy_sample.csv", first_day)
        print(f"{args.out / 'energy_sample.csv'}: {count} rows")
        # Missing the kwh column: the data flow rejects it (schema validation) and Teams reports a failure.
        count = write_csv(args.out / "energy_invalid.csv", first_day[:50], header=[h for h in HEADER if h != "kwh"])
        print(f"{args.out / 'energy_invalid.csv'}: {count} rows (no kwh column, must fail)")
        # Half of the kwh values are empty: more than 10% of the rows are rejected, the drop-ratio check fails the run.
        too_dirty = [{**row, "kwh": ""} if i % 2 else row for i, row in enumerate(first_day)]
        count = write_csv(args.out / "energy_too_dirty.csv", too_dirty)
        print(f"{args.out / 'energy_too_dirty.csv'}: {count} rows (half of kwh empty, must fail the ratio check)")

    if args.expected_gold:
        write_expected_gold(args.expected_gold, rows)


if __name__ == "__main__":
    main()
