#!/usr/bin/env python3
"""
GTFS フィルタースクリプト
stops.txt の座標を bbox でフィルタし、関連する stop_times / trips / routes を削除する。

使い方:
    python scripts/filter_gtfs.py \
        --input  data/GTFS-data/JR-East-Train.gtfs.zip \
        --output data/GTFS-filtered/JR-East-Train.gtfs.zip \
        --bbox   138.90,35.00,140.90,36.30

    # --dry-run: 削減数だけ表示して出力しない
    python scripts/filter_gtfs.py --input ... --bbox ... --dry-run
"""

import argparse
import csv
import io
import sys
import zipfile


BBOX_DEFAULT = "138.90,35.00,140.90,36.30"


def parse_bbox(bbox_str):
    west, south, east, north = map(float, bbox_str.split(","))
    return west, south, east, north


def read_csv_from_zip(zf, filename):
    """zip 内の CSV を [{col: val, ...}] のリストで返す"""
    try:
        with zf.open(filename) as f:
            text = io.TextIOWrapper(f, encoding="utf-8-sig")
            return list(csv.DictReader(text))
    except KeyError:
        return []


def write_csv_to_zip(out_zf, filename, rows, fieldnames):
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=fieldnames, lineterminator="\r\n")
    writer.writeheader()
    writer.writerows(rows)
    out_zf.writestr(filename, buf.getvalue().encode("utf-8"))


def filter_gtfs(input_path, output_path, bbox, dry_run=False):
    west, south, east, north = bbox

    with zipfile.ZipFile(input_path, "r") as zf:
        all_files = zf.namelist()

        stops = read_csv_from_zip(zf, "stops.txt")
        stop_times = read_csv_from_zip(zf, "stop_times.txt")
        trips = read_csv_from_zip(zf, "trips.txt")
        routes = read_csv_from_zip(zf, "routes.txt")

        # --- stops フィルタ ---
        kept_stops = []
        removed_stop_ids = set()
        for s in stops:
            try:
                lat = float(s.get("stop_lat", "0") or "0")
                lon = float(s.get("stop_lon", "0") or "0")
            except ValueError:
                kept_stops.append(s)
                continue
            if west <= lon <= east and south <= lat <= north:
                kept_stops.append(s)
            else:
                removed_stop_ids.add(s["stop_id"])

        kept_stop_ids = {s["stop_id"] for s in kept_stops}

        # --- trips を「bbox 外の stop を含むかどうか」でフィルタ ---
        # bbox 外の stop が 1つでもあるトリップは除外
        removed_trip_ids = set()
        for st in stop_times:
            if st["stop_id"] in removed_stop_ids:
                removed_trip_ids.add(st["trip_id"])

        kept_stop_times = [
            st for st in stop_times if st["trip_id"] not in removed_trip_ids
        ]

        kept_trips = [t for t in trips if t["trip_id"] not in removed_trip_ids]
        kept_route_ids = {t["route_id"] for t in kept_trips}
        kept_routes = [r for r in routes if r["route_id"] in kept_route_ids]

        # --- 統計 ---
        stats = {
            "stops":       (len(stops),      len(kept_stops)),
            "stop_times":  (len(stop_times),  len(kept_stop_times)),
            "trips":       (len(trips),       len(kept_trips)),
            "routes":      (len(routes),      len(kept_routes)),
        }

        print(f"\n[{input_path.split('/')[-1]}]")
        for name, (before, after) in stats.items():
            removed = before - after
            pct = removed / before * 100 if before else 0
            print(f"  {name:12s}: {before:6d} → {after:6d}  (-{removed:5d}, -{pct:.1f}%)")

        if dry_run:
            print("  ※ dry-run: ファイルへの書き込みはスキップ")
            return stats

        # --- 出力 ---
        with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as out_zf:
            for fname in all_files:
                if fname == "stops.txt":
                    write_csv_to_zip(out_zf, fname, kept_stops,
                                     list(stops[0].keys()) if stops else [])
                elif fname == "stop_times.txt":
                    write_csv_to_zip(out_zf, fname, kept_stop_times,
                                     list(stop_times[0].keys()) if stop_times else [])
                elif fname == "trips.txt":
                    write_csv_to_zip(out_zf, fname, kept_trips,
                                     list(trips[0].keys()) if trips else [])
                elif fname == "routes.txt":
                    write_csv_to_zip(out_zf, fname, kept_routes,
                                     list(routes[0].keys()) if routes else [])
                else:
                    # calendar.txt, agency.txt 等はそのままコピー
                    out_zf.writestr(fname, zf.read(fname))

        return stats


def main():
    parser = argparse.ArgumentParser(description="GTFS bbox フィルター")
    parser.add_argument("--input",   required=True,  help="入力 GTFS zip パス")
    parser.add_argument("--output",  default=None,   help="出力 GTFS zip パス（省略時は dry-run）")
    parser.add_argument("--bbox",    default=BBOX_DEFAULT,
                        help="west,south,east,north (default: 4都県)")
    parser.add_argument("--dry-run", action="store_true",
                        help="統計のみ表示、ファイル出力しない")
    args = parser.parse_args()

    bbox = parse_bbox(args.bbox)
    dry_run = args.dry_run or args.output is None

    filter_gtfs(args.input, args.output or "", bbox, dry_run=dry_run)


if __name__ == "__main__":
    main()
