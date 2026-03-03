import httpx
from datetime import datetime, timezone, timedelta

OTP2_GRAPHQL_URL = "http://localhost:8080/otp/gtfs/v1"


def _build_query(
    from_lat: float, from_lon: float,
    to_lat: float, to_lon: float,
    arrival_str: str,
) -> str:
    """座標と到着時刻をインラインで埋め込んだ GraphQL クエリを生成する。

    OTP2 v2.7.0 の planConnection は座標に CoordinateValue 型を使うため、
    GraphQL 変数（Float!）では型不一致エラーになる。インライン値で回避する。
    """
    return f"""
{{
  planConnection(
    origin:      {{ location: {{ coordinate: {{ latitude: {from_lat}, longitude: {from_lon} }} }} }}
    destination: {{ location: {{ coordinate: {{ latitude: {to_lat},   longitude: {to_lon}   }} }} }}
    dateTime: {{ latestArrival: "{arrival_str}" }}
    modes: {{
      transit: {{ transit: [{{ mode: RAIL }}, {{ mode: SUBWAY }}, {{ mode: BUS }}] }}
      direct: [WALK]
    }}
    first: 3
  ) {{
    edges {{
      node {{
        start
        end
        numberOfTransfers
        legs {{
          mode
          route {{ shortName longName }}
          from  {{ name }}
          to    {{ name }}
          start {{ scheduledTime }}
          end   {{ scheduledTime }}
          interlineWithPreviousLeg
        }}
      }}
    }}
  }}
}}
"""


async def search_route(
    from_lat: float, from_lon: float,
    to_lat:   float, to_lon:   float,
    arrival_time: datetime,
) -> dict:
    # ISO8601 + JST オフセット付き文字列に変換
    jst = timezone(timedelta(hours=9))
    arrival_str = arrival_time.astimezone(jst).strftime("%Y-%m-%dT%H:%M:%S+09:00")

    query = _build_query(from_lat, from_lon, to_lat, to_lon, arrival_str)

    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            OTP2_GRAPHQL_URL,
            json={"query": query},
        )
        resp.raise_for_status()
        return resp.json()
