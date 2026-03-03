from pydantic import BaseModel
from typing import Optional, List


class TransitLeg(BaseModel):
    mode: str                  # "WALK" / "RAIL" / "SUBWAY" / "BUS"
    line_name: Optional[str]   # 例: "中央線快速"（WALK のときは None）
    from_station: str          # 例: "高円寺"
    to_station: str            # 例: "新宿"
    departure_time: str        # 例: "08:35"（HH:MM 形式）
    arrival_time: str          # 例: "08:42"


class RouteResponse(BaseModel):
    board_station: str     # 最初に乗車する駅名
    depart_at: str         # 最寄り駅の出発時刻 "HH:MM"
    arrive_at: str         # 目的地への到着時刻 "HH:MM"
    num_transfers: int     # 乗り換え回数
    legs: List[TransitLeg] # 区間ごとの乗換案内
    message: str           # "08:35 に高円寺 を出発してください"


class DepartureTimeResponse(BaseModel):
    leave_home_at: str     # 家を出る時刻 "HH:MM"
    board_station: str     # 最寄り駅名
    board_at: str          # 最寄り駅の出発時刻 "HH:MM"
    message: str           # "08:20 に家を出発してください（身支度15分を含む）"
