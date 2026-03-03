from pydantic import BaseModel
from datetime import datetime


class RouteRequest(BaseModel):
    origin: str                      # 例: "高円寺"（駅名）
    destination: str                 # 例: "渋谷"（駅名）
    desired_arrival_time: datetime   # 例: "2026-03-10T09:00:00+09:00"


class DepartureTimeRequest(BaseModel):
    origin: str                      # 例: "高円寺"
    destination: str                 # 例: "渋谷"
    desired_arrival_time: datetime   # 例: "2026-03-10T09:00:00+09:00"
    preparation_minutes: int = 0     # 身支度にかかる時間（分）
