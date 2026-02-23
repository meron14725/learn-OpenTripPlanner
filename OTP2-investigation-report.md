# OTP2 技術検証レポート：日本の鉄道乗換案内への適用可能性

**作成日**: 2026-02-23
**調査対象**: OpenTripPlanner 2 (OTP2)
**参照プロジェクト**: `../demo-project-Google-Directions-API`

---

## 1. 概要

### プロジェクト目的

「執事アプリ」の核心機能として、**目的地と到着希望時刻を入力 → 電車を使った最適経路と最寄駅の出発時刻を表示**することが求められている。

本レポートでは、OSSである OpenTripPlanner 2 (OTP2) を用いてこの機能が実現できるかを調査・検証する。

### やりたいこと

```
入力: 目的地（例: 渋谷駅）、到着希望時刻（例: 09:00）
出力:
  - 乗換案内付きの電車経路（○○線 → △△線 乗り換え など）
  - 最寄駅を何時に出れば間に合うか（例: 最寄駅 08:35 発の山手線に乗ってください）
```

---

## 2. デモプロジェクト（Google Directions API）の現状分析

### 構成

`../demo-project-Google-Directions-API` は FastAPI (Python) バックエンド + React フロントエンドの構成。

```
backend/app/
├── api/directions.py          # POST /api/v1/routes エンドポイント
├── services/
│   ├── google_maps.py         # Google Routes API v2 統合
│   └── ekispert_service.py    # 駅すぱあとAPI統合
└── models/
    ├── request.py             # RouteRequest（origin, destination, desired_arrival_time）
    └── response.py            # RouteResponse（recommended_departure_time, transit_steps）
```

### 推奨出発時刻の計算ロジック

```python
# backend/app/api/directions.py
if request.desired_arrival_time:
    recommended_departure_time = request.desired_arrival_time - timedelta(
        seconds=duration_seconds
    )
```

到着希望時刻から所要時間を引くだけのシンプルな実装。

### 重大な問題：Google Routes API v2 は東京のTRANSITデータを持っていない

調査ログ（`transit_tokyo_response.log`）と `docs/final-report-transit-tokyo-investigation.md` によると：

| テスト | 結果 |
|--------|------|
| 東京 DRIVE モード | 正常動作 |
| 東京 TRANSIT モード | レスポンス 29バイト、ルートデータなし |
| SF TRANSIT モード | 14KB の正常データを返す |

これは Google Issue Tracker #35826181 でも報告されている既知の問題であり、**Google Routes API v2 では東京エリアの電車経路検索は実質不可能**。

### 現行の回避策：駅すぱあとAPI

日本国内の TRANSIT 検索には駅すぱあと（エキスパート）APIを採用。

| プラン | 発車時刻 | 乗換案内 | 費用 |
|--------|---------|---------|------|
| フリープラン | 不可 | 不可 | 無料（90日評価） |
| スタンダードプラン | 可 | 可 | 約1円/リクエスト |

「09:05発の山手線に乗ってください」という案内には**スタンダードプランが必須**。

---

## 3. OTP2（OpenTripPlanner 2）とは

OTP2 は Java ベースのオープンソース（LGPL）マルチモーダル経路探索エンジン。

### 基本アーキテクチャ

```
GTFS データ（時刻表）
OpenStreetMap PBF（地図）
         ↓
  [OTP2 Java サーバー]
    グラフビルド
         ↓
  GraphQL API（ポート8080）
         ↓
  クライアント（REST/GraphQL）
```

- **APIコスト**: ゼロ（リクエスト課金なし。サーバーインフラ費用のみ）
- **リアルタイム**: GTFS-RT 対応（遅延・運休情報）
- **REST API**: OTP2 では廃止。**GraphQL API のみ**対応
- **Geocoding**: OTP2 自体は住所→座標変換しない。別途 OSM Nominatim 等が必要

---

## 4. 機能検証：要件ごとの対応確認

### 4.1 到着時刻指定検索（arriveBy）

**結論: ✅ 対応済み**

OTP2 の `plan` クエリには `arriveBy: true` パラメータがある。これを使うと指定時刻を**到着希望時刻**として扱い、逆方向に経路探索する。

より新しい `planConnection` クエリでは `latestArrival` を使用する（OTP2 v2.7.0 以降推奨）。

```graphql
# plan クエリ（従来型、現在非推奨）
{
  plan(
    from: { lat: 35.6895, lon: 139.6917 }   # 出発地（最寄駅付近）
    to:   { lat: 35.6580, lon: 139.7016 }   # 目的地
    date: "2026-03-01"
    time: "09:00:00"
    arriveBy: true                            # ← 到着希望時刻として扱う
    numItineraries: 3
    transportModes: [{ mode: TRANSIT }, { mode: WALK }]
  ) {
    itineraries {
      startTime    # 出発すべき時刻（これが答え）
      endTime      # 到着時刻
      duration
      numberOfTransfers
      legs { ... }
    }
  }
}
```

```graphql
# planConnection クエリ（v2.7.0 以降推奨）
{
  planConnection(
    origin: {
      location: { coordinate: { latitude: 35.6895, longitude: 139.6917 } }
    }
    destination: {
      location: { coordinate: { latitude: 35.6580, longitude: 139.7016 } }
    }
    dateTime: { latestArrival: "2026-03-01T09:00:00+09:00" }  # ← 到着希望時刻
    modes: {
      transit: { transit: [{ mode: RAIL }] }
      direct: [WALK]
    }
    first: 5
  ) {
    edges {
      node {
        start   # 出発すべき時刻
        end     # 到着時刻
        legs { ... }
      }
    }
  }
}
```

### 4.2 乗換案内（路線名・乗換駅の取得）

**結論: ✅ 対応済み**

経路結果の `Itinerary` は `legs`（乗車区間の配列）を持つ。各 `Leg` には以下が含まれる：

| フィールド | 内容 |
|-----------|------|
| `mode` | WALK, RAIL, SUBWAY, BUS など |
| `route.shortName` | 路線名（例: "山手線"） |
| `route.longName` | 路線正式名称 |
| `from.name` | 乗車駅名 |
| `to.name` | 降車駅名 |
| `start.scheduledTime` | 乗車時刻 |
| `end.scheduledTime` | 降車時刻 |
| `headsign` | 行先（例: "渋谷・恵比寿方面"） |
| `interlineWithPreviousLeg` | 直通運転（stay-seated）かどうか |

`numberOfTransfers` で乗り換え回数（直通は除外）も取得可能。

```graphql
# legs フィールドの詳細クエリ例
legs {
  mode
  route {
    shortName
    longName
    agency { name }
  }
  from {
    name
    stop { gtfsId }
  }
  to {
    name
    stop { gtfsId }
  }
  start { scheduledTime }
  end   { scheduledTime }
  headsign
  interlineWithPreviousLeg
}
```

**乗換案内の表示例（返却データから生成）:**

```
1. 徒歩 8分 → 高円寺駅まで
2. 中央線（快速）09:23発 → 新宿 09:29着
3. 乗り換え（新宿駅）
4. 山手線（内回り）09:33発 → 渋谷 09:38着
```

### 4.3 最寄駅の発車時刻（中間停車駅の時刻）

**結論: ✅ 対応済み**

ユーザーの最寄駅が電車の始発駅でない場合（多くの場合そう）、`stopCalls` フィールドを使う。
これは **当該 leg が停車する全駅のリスト**で、各停車駅の発着時刻が含まれる。

```graphql
legs {
  mode
  route { shortName }
  stopCalls {
    stopLocation {
      ... on Stop {
        name
        gtfsId
      }
    }
    schedule {
      scheduledDeparture   # 予定発車時刻
      scheduledArrival     # 予定到着時刻
    }
    realTime {
      estimatedDeparture   # リアルタイム発車予測（GTFS-RT使用時）
      estimatedArrival
    }
  }
}
```

`stopCalls` の中から「from.name と一致する停車駅」のエントリを探せば、ユーザーの最寄駅における正確な発車時刻が得られる。

### 4.4 直通運転（through-service / 直通運転）への対応

**結論: ✅ 対応済み（`block_id` サポート）**

東京の鉄道では相鉄→東急→東京メトロ→都営など多数の直通運転がある。GTFS の `block_id` フィールドでこれを表現し、OTP2 はこれをサポートしている。

`Leg.interlineWithPreviousLeg` が `true` の場合、乗り換えなしの直通（stay-seated）を示す。

---

## 5. 日本向け GTFS データの入手方法

### 5.1 ODPT（公共交通オープンデータセンター）

**URL**: https://www.odpt.org/
**開発者登録**: https://developer.odpt.org/ （無料・誰でも可・承認まで最大2営業日）

登録後に取得できる GTFS データ（チャレンジキーが必要なものは「要チャレンジ登録」と表記）：

| 事業者 | データ | 備考 |
|--------|--------|------|
| 東京メトロ | 全線時刻表 GTFS | 要 consumerKey パラメータ |
| 都営（東京都交通局） | 地下鉄・荒川線・日暮里舎人ライナー | |
| JR東日本（関東） | 関東在来線の一部（新幹線は除く）| Open Data Challenge 2025 限定ライセンス（無料登録で誰でも取得可） |
| 東武鉄道 | | |
| 相模鉄道（Sotetsu） | | |
| つくばエクスプレス | | |
| 横浜市営地下鉄 | | |
| 多摩都市モノレール | | |
| 東京臨海高速鉄道（りんかい線） | | |

**ダウンロード例（東京メトロ）:**

```bash
curl "https://api.odpt.org/api/v4/files/TokyoMetro/data/TokyoMetro-Train-GTFS.zip\
?acl:consumerKey=YOUR_API_KEY" -o tokyo-metro.gtfs.zip
```

### 5.2 TokyoGTFS（GitHub プロジェクト）

**URL**: https://github.com/MKuranowski/TokyoGTFS
**ライセンス**: MIT（鉄道 GTFS）

ODPT データをもとに、首都圏全民営鉄道の GTFS を生成するツール。

- 東急、小田急、京王、西武、京急、東武、京成など私鉄各社をカバー
- **`block_id` を含む**（直通運転データ付き）
- ODPT API キーが必要

```bash
# インストール・実行例
pip install TokyoGTFS
python -m tokyo_gtfs --apikey YOUR_ODPT_API_KEY --output ./gtfs/
```

### 5.3 TrainGTFSGenerator（最も手軽な選択肢）

**URL**: https://github.com/fksms/TrainGTFSGenerator
**ライセンス**: MIT（ツール本体）/ 元データは ODPT 由来

Mini Tokyo 3D プロジェクトのデータ（git サブモジュールとして同梱）を GTFS に変換するツール。
**ODPT API キー不要で実行でき、首都圏 22 事業者の GTFS を一括生成できる。**

#### カバー路線

JR東日本（49ファイル）：

| 路線 | ファイル名 | サイズ |
|------|-----------|--------|
| 山手線 | jreast-yamanote.json | 2.0 MB |
| 京浜東北・根岸線 | jreast-keihintohokunegishi.json | 3.0 MB |
| 中央・総武各停 | jreast-chuosobulocal.json | 2.4 MB |
| 中央線快速 | jreast-chuorapid.json | 1.8 MB |
| 埼京・川越線 | jreast-saikyokawagoe.json | 1.1 MB |
| 東海道線 | jreast-tokaido.json | 0.9 MB |
| 横須賀線 | jreast-yokosuka.json | 0.7 MB |
| 常磐線（快速・中距離・各停） | jreast-joban*.json | 各0.4〜0.7 MB |
| 相模線 | jreast-sagami.json | 0.3 MB |
| 鶴見線 | jreast-tsurumi.json | 0.4 MB |
| 南武線 | jreast-nambu.json | 1.3 MB |
| 武蔵野線 | jreast-musashino.json | 1.0 MB |
| 宇都宮線 | jreast-utsunomiya.json | 0.7 MB |
| 高崎線 | jreast-takasaki.json | 0.7 MB |
| その他支線を含む全49路線 | | |

**ODPT の JR東チャレンジ版より広いカバレッジ**（相模線・鶴見線・南武支線が含まれる）。

その他の事業者（22社）：東京メトロ（10路線）、都営（6路線）、東急、小田急、京王、西武、東武、京急、京成、相鉄、横浜市営、つくばEX、多摩モノレール、ゆりかもめ 等

#### セットアップと実行

```bash
# クローン（サブモジュール含む）
git clone --recursive --shallow-submodules \
  https://github.com/fksms/TrainGTFSGenerator.git
cd TrainGTFSGenerator

# 依存インストール
pipx install poetry
poetry install

# GTFS 生成（dist/ に事業者別 ZIP が出力される）
poetry run python src/main.py
```

#### 注意点

| 項目 | 内容 |
|------|------|
| API キー | 不要（データはサブモジュールに同梱） |
| データの鮮度 | コミット時点のスナップショット（時刻改定で古くなる可能性あり） |
| ライセンス | ツールは MIT。元データは ODPT 由来のため ODPT ライセンスが適用される可能性あり |
| 新幹線 | 含まれない |

### 5.4 OpenStreetMap PBF（歩行経路データ）

**URL**: https://download.geofabrik.de/asia/japan.html
**ライセンス**: ODbL（無料）

```bash
# 関東地方 PBF をダウンロード
curl https://download.geofabrik.de/asia/japan/kanto-latest.osm.pbf -o kanto.osm.pbf
```

---

## 6. セットアップ手順の概要

OTP2 サーバーを構築して東京の鉄道経路検索を動かすには以下の手順が必要：

### Step 1: OTP2 バイナリの取得

```bash
# GitHub Releases から JAR をダウンロード
curl -L https://github.com/opentripplanner/OpenTripPlanner/releases/download/v2.7.0/\
otp-2.7.0-shaded.jar -o otp.jar
```

### Step 2: データディレクトリの準備

```
/otp-data/
├── jreast-yamanote.zip      # TrainGTFSGenerator で生成（dist/ から）
├── jreast-chuo.zip          # 同上
├── tokyometro-ginza.zip     # 同上
├── toei-asakusa.zip         # 同上
│   ... （22事業者分）
└── kanto.osm.pbf            # Geofabrik から取得
```

**TrainGTFSGenerator を使う場合は ODPT API キーなしで上記の GTFS を一括生成できる（最も手軽）。**
ODPT から直接取得する場合は developer.odpt.org への登録が必要。

### Step 3: グラフのビルド

```bash
java -Xmx4G -jar otp.jar --build --save /otp-data/
```

（初回ビルドに数十分かかる。出力: `graph.obj`）

### Step 4: サーバー起動

```bash
java -Xmx4G -jar otp.jar --load /otp-data/
# → http://localhost:8080/graphiql で GraphQL Playground が開く
```

### Step 5: 住所 → 座標変換（Geocoding）

OTP2 は住所検索を行わないため、別途 Geocoder が必要。

```bash
# OSM Nominatim（Docker）
docker run -it \
  -e PBF_URL=https://download.geofabrik.de/asia/japan/kanto-latest.osm.pbf \
  -p 8888:8080 \
  mediagis/nominatim:4.4
```

```python
# 駅名 → 座標変換例
import httpx

async def geocode(station_name: str) -> tuple[float, float]:
    r = await httpx.get("http://localhost:8888/search", params={
        "q": station_name,
        "format": "json",
        "limit": 1
    })
    result = r.json()[0]
    return float(result["lat"]), float(result["lon"])
```

---

## 7. OTP2 vs 駅すぱあとAPI 比較表

| 項目 | OTP2 | 駅すぱあと（スタンダード） |
|------|------|--------------------------|
| **到着時刻指定** | ✅ `arriveBy` / `latestArrival` | ✅ |
| **乗換案内（路線名・駅名）** | ✅ `Leg.route` / `Leg.from` / `Leg.to` | ✅ |
| **発車時刻の精度** | ✅ GTFSデータ準拠 | ✅ 専用DB準拠 |
| **中間停車駅の発車時刻** | ✅ `stopCalls` | ✅ |
| **直通運転対応** | ✅ `block_id` | ✅ |
| **リアルタイム遅延情報** | ✅ GTFS-RT 対応 | 別途オプション |
| **APIコスト** | ゼロ（サーバー費のみ） | 約1円/リクエスト |
| **セットアップ難易度** | 高（Java/GTFS管理）| 低（APIキーのみ） |
| **日本での実績** | ほぼなし（海外では多数） | 高（日本専門） |
| **データ更新** | 手動/自動で GTFS 再取得 | サービス側が管理 |
| **Geocoding** | 別途必要 | 駅名→座標も対応 |
| **ライセンス** | LGPL（完全無料OOS）| 商用ライセンス |

---

## 8. 結論と推奨事項

### 結論：技術的には YES

**OTP2 で「目的地・到着希望時刻 → 乗換案内付き電車経路 → 最寄駅の出発時刻」は実現できる。**

- `arriveBy: true`（または `latestArrival`）により逆方向探索が可能
- `legs` / `stopCalls` から発着時刻・路線名・乗換情報を完全に取得可能
- 東京向け GTFS データは ODPT + TokyoGTFS で入手可能

### トレードオフ

| シナリオ | 推奨 |
|----------|------|
| 個人・ハッカソン・小規模 | 駅すぱあとスタンダード（90日無料評価→月額数千円） |
| 大規模・長期・コスト重視 | OTP2（初期構築コストを回収できる） |
| 日本で確実な品質が必要 | 駅すぱあと優位（日本専用DB） |
| 海外展開も視野 | OTP2（GTFS が世界標準） |

### 次のステップ（実際に動かすなら）

1. **TrainGTFSGenerator** をクローンして `poetry run python src/main.py` を実行（API キー不要、最速）
2. Geofabrik から関東 PBF ダウンロード
3. OTP2 JAR を取得してグラフビルド
4. サーバー起動 → GraphQL で `arriveBy: true` クエリを実行して動作検証
5. （任意）ODPT 開発者登録で最新 GTFS を取得してデータを更新
5. OTP2 グラフビルド → サーバー起動
6. GraphQL で `arriveBy: true` クエリを実行して動作検証

---

## 参考リンク

- OTP2 公式ドキュメント: https://docs.opentripplanner.org/
- GraphQL API リファレンス: https://docs.opentripplanner.org/api/dev-2.x/graphql-gtfs/
- `planConnection` クエリ: https://docs.opentripplanner.org/api/dev-2.x/graphql-gtfs/queries/planConnection
- ODPT 公式: https://www.odpt.org/
- Open Data Challenge 2025: https://challenge2025.odpt.org/
- TokyoGTFS GitHub: https://github.com/MKuranowski/TokyoGTFS
- Geofabrik Japan PBF: https://download.geofabrik.de/asia/japan.html
- OTP2 GitHub: https://github.com/opentripplanner/OpenTripPlanner
