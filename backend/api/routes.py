from fastapi import APIRouter, HTTPException
from datetime import datetime, timezone, timedelta
from models.request import RouteRequest, DepartureTimeRequest
from models.response import RouteResponse, DepartureTimeResponse, TransitLeg
from services.geocoder import geocode
from services.otp_client import search_route

router = APIRouter()
JST = timezone(timedelta(hours=9))


def fmt_time(iso_str: str) -> str:
    """ISO8601 文字列を "HH:MM" (JST) に変換する"""
    return datetime.fromisoformat(iso_str).astimezone(JST).strftime("%H:%M")


def _parse_edges(data: dict) -> list[dict]:
    """OTP2 レスポンスから edges を取得。空なら HTTPException を送出。"""
    edges = data.get("data", {}).get("planConnection", {}).get("edges", [])
    if not edges:
        raise HTTPException(
            status_code=404,
            detail="経路が見つかりませんでした（時刻・区間を確認してください）",
            headers={"X-Error-Code": "ROUTE_NOT_FOUND"},
        )
    return edges


async def _geocode_pair(origin: str, destination: str):
    """出発地・目的地を座標に変換。失敗時は HTTPException。"""
    try:
        from_lat, from_lon = geocode(origin)
        to_lat,   to_lon   = geocode(destination)
    except ValueError as e:
        raise HTTPException(
            status_code=400,
            detail=str(e),
            headers={"X-Error-Code": "STATION_NOT_FOUND"},
        )
    return from_lat, from_lon, to_lat, to_lon


@router.post("/api/v1/routes", response_model=RouteResponse)
async def get_routes(req: RouteRequest):
    # 1. 駅名 → 座標
    from_lat, from_lon, to_lat, to_lon = await _geocode_pair(req.origin, req.destination)

    # 2. OTP2 に経路検索
    try:
        data = await search_route(from_lat, from_lon, to_lat, to_lon, req.desired_arrival_time)
    except Exception:
        raise HTTPException(
            status_code=502,
            detail="OTP2 サーバーに接続できません",
            headers={"X-Error-Code": "OTP_UNAVAILABLE"},
        )

    edges = _parse_edges(data)
    itinerary = edges[0]["node"]  # 最初の候補を採用

    # 3. legs を整形
    legs = [
        TransitLeg(
            mode=leg["mode"],
            line_name=(leg["route"]["shortName"] or leg["route"].get("longName")) if leg.get("route") else None,
            from_station=leg["from"]["name"],
            to_station=leg["to"]["name"],
            departure_time=fmt_time(leg["start"]["scheduledTime"]),
            arrival_time=fmt_time(leg["end"]["scheduledTime"]),
        )
        for leg in itinerary["legs"]
    ]

    # 4. 最初の電車区間 = 最寄り駅からの乗車
    first_train = next((l for l in legs if l.mode not in ("WALK",)), legs[0])

    return RouteResponse(
        board_station=first_train.from_station,
        depart_at=first_train.departure_time,
        arrive_at=fmt_time(itinerary["end"]),
        num_transfers=itinerary["numberOfTransfers"],
        legs=legs,
        message=f"{first_train.departure_time} に {first_train.from_station} を出発してください",
    )


@router.post("/api/v1/routes/departure-time", response_model=DepartureTimeResponse)
async def get_departure_time(req: DepartureTimeRequest):
    # 1. 駅名 → 座標
    from_lat, from_lon, to_lat, to_lon = await _geocode_pair(req.origin, req.destination)

    # 2. OTP2 に経路検索
    try:
        data = await search_route(from_lat, from_lon, to_lat, to_lon, req.desired_arrival_time)
    except Exception:
        raise HTTPException(
            status_code=502,
            detail="OTP2 サーバーに接続できません",
            headers={"X-Error-Code": "OTP_UNAVAILABLE"},
        )

    edges = _parse_edges(data)
    itinerary = edges[0]["node"]

    # 3. 最初の電車区間を見つける
    first_train_leg = next(
        (leg for leg in itinerary["legs"] if leg["mode"] not in ("WALK",)),
        itinerary["legs"][0],
    )

    board_station = first_train_leg["from"]["name"]
    board_time_str = first_train_leg["start"]["scheduledTime"]
    board_dt = datetime.fromisoformat(board_time_str).astimezone(JST)
    board_at = board_dt.strftime("%H:%M")

    # 4. 身支度時間を引いて家を出る時刻を計算
    leave_dt = board_dt - timedelta(minutes=req.preparation_minutes)
    leave_home_at = leave_dt.strftime("%H:%M")

    if req.preparation_minutes > 0:
        msg = f"{leave_home_at} に家を出発してください（身支度{req.preparation_minutes}分を含む）"
    else:
        msg = f"{board_at} に {board_station} を出発してください"

    return DepartureTimeResponse(
        leave_home_at=leave_home_at,
        board_station=board_station,
        board_at=board_at,
        message=msg,
    )
