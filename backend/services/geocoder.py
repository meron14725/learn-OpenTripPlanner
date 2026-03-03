import json
from pathlib import Path

_COORDS_FILE = Path(__file__).parent / "station_coords.json"


def _load_station_coords() -> dict[str, tuple[float, float]]:
    with open(_COORDS_FILE, encoding="utf-8") as f:
        raw = json.load(f)
    return {name: tuple(coords) for name, coords in raw.items()}


STATION_COORDS = _load_station_coords()


def geocode(station_name: str) -> tuple[float, float]:
    """駅名から (latitude, longitude) を返す。駅名末尾の「駅」は除去する。"""
    name = station_name.replace("駅", "").strip()
    if name not in STATION_COORDS:
        raise ValueError(
            f"未対応の駅名: '{name}' — GTFS データに含まれていない駅です"
        )
    return STATION_COORDS[name]
