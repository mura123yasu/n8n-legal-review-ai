# アーキテクチャ詳細

## システム全体図

```
┌─────────────────────────────────────────────────────────────────┐
│                        Google Workspace                          │
│                                                                  │
│  📁 契約書レビュー/                                               │
│    ├── 01_inbox/      ← PDF を置くとフロー発動                   │
│    ├── 02_processing/ ← 処理中（二重処理防止）                   │
│    ├── 03_reviewed/   ← 処理完了済み原本                         │
│    └── 04_results/    ← AI レビュー結果ドキュメント              │
│                                                                  │
│  Google Docs / Sheets / Gmail                                    │
└────────────────────────────────────────────────────────────────-┘
          ▲ ファイル操作・ドキュメント生成・メール送信・ログ記録

┌───────────────────────────────┐
│  Cloud Scheduler              │
│  schedule: */5 * * * *        │─── OIDC トークン付き POST ───▶
│  timezone: Asia/Tokyo         │
└───────────────────────────────┘
                                          ▼

┌─────────────────────────────────────────────────────────────────┐
│  Cloud Run: n8n  (asia-northeast1)                               │
│  min=0  max=2  512Mi  ingress=ALL  no-allow-unauthenticated      │
│                                                                  │
│  [Webhook Trigger] → [Drive: List Files] → [IF: Files Found?]   │
│       ↓                                        ↓ true           │
│  [No Files: End]               [Split In Batches: 1件ずつ]       │
│                                        ↓                         │
│                          [Drive: Move → 02_processing]           │
│                                        ↓                         │
│                          [HTTP: GAS WebApp]────────────────────▶│
│                                        ↓              GAS WebApp │
│                          [HTTP: Gemini API]────────────────────▶│
│                                        ↓            Gemini API   │
│                          [Code: Parse Response]                  │
│                                        ↓                         │
│                          [Docs: Create Document]                 │
│                                        ↓                         │
│                          [Drive: Move → 03_reviewed]             │
│                                        ↓                         │
│                          [Gmail: Notification]                   │
│                                        ↓                         │
│                          [Sheets: Log]                           │
│                                        ↓                         │
│                          [Split: Next Item...]                   │
└─────────────────────────────────────────────────────────────────┘
          │                    │                    │
          ▼                    ▼                    ▼
┌──────────────┐   ┌──────────────────┐   ┌──────────────────┐
│    Neon      │   │  Secret Manager  │   │   GAS WebApp     │
│ Serverless   │   │  n8n DB接続情報  │   │  PDF → テキスト  │
│ PostgreSQL   │   │  API Keys 等     │   │  OCR 変換        │
└──────────────┘   └──────────────────┘   └──────────────────┘
```

---

## コンポーネント詳細

### Cloud Run（n8n ホスティング）

| 設定項目 | 値 | 理由 |
|---|---|---|
| イメージ | `n8nio/n8n:latest` | n8n 公式イメージ |
| min-instances | 0 | Cloud Scheduler が起こすので常時稼働不要 |
| max-instances | 2 | 並列処理の上限 |
| Memory | 512Mi | n8n の起動に十分。負荷が高い場合は 1Gi に変更 |
| CPU | 1 | cpu_idle=true でリクエスト時のみ課金 |
| Ingress | ALL | Cloud Scheduler から直接到達させるため |
| 認証 | Cloud Run IAM | `allUsers` なし = unauthenticated 拒否 |

#### 開発者のアクセス方法

Cloud Run IAM で `roles/run.invoker` を付与されたユーザーは、ローカルプロキシ経由でアクセスできます：

```bash
gcloud run services proxy n8n --region=asia-northeast1 --port=8080
# → http://localhost:8080 で n8n 管理 UI にアクセス
```

> **本番移行時**: IAP（Identity-Aware Proxy）を Cloud Load Balancer 経由で追加し、ブラウザから直接 Google 認証でアクセスできる構成に変更する。

### Cloud Scheduler

| 設定項目 | 値 |
|---|---|
| スケジュール | `*/5 * * * *`（5分ごと） |
| タイムゾーン | `Asia/Tokyo` |
| タイムアウト | 540秒（コールドスタート考慮） |
| 認証 | OIDC（Scheduler SA → Cloud Run Invoker） |
| リトライ | 1回（30秒後） |

#### コールドスタートについて

n8n（Node.js）のコールドスタートは約 20〜30 秒かかります。Cloud Scheduler のタイムアウトを 540 秒に設定しているため、コールドスタート後も問題なくリクエストが処理されます。

### Neon Serverless PostgreSQL

- n8n のワークフロー定義・実行履歴・認証情報を保存
- **スケールゼロ対応**: アイドル時はコンピュートが停止（課金なし）
- Free tier: 0.5GB ストレージ、1 プロジェクト
- 接続: `sslmode=require`（n8n の `DB_POSTGRESDB_SSL=true` で設定済み）

### Secret Manager

以下のシークレットを管理：

| シークレット名 | 用途 |
|---|---|
| `n8n-db-host` | Neon PG ホスト名 |
| `n8n-db-name` | DB 名 |
| `n8n-db-user` | DB ユーザー |
| `n8n-db-password` | DB パスワード |
| `n8n-encryption-key` | n8n 認証情報の暗号化キー（固定値・変更禁止） |
| `n8n-webhook-url` | Cloud Run URI（N8N_HOST・WEBHOOK_URL に使用） |
| `gemini-api-key` | Gemini API キー |
| `gas-webapp-url` | GAS WebApp URL |
| `notify-email` | 完了通知先メールアドレス |

### GAS WebApp（PDF → テキスト変換）

- Drive API v2 の OCR 機能で PDF → Google ドキュメント変換
- 変換後にテキストを抽出し、一時ドキュメントを削除
- n8n から HTTP POST で呼び出し（レスポンスは JSON）

---

## データフロー

```
1. ユーザーが PDF を Google Drive の 01_inbox フォルダにアップロード

2. Cloud Scheduler が 5分ごとに n8n webhook を呼び出す

3. n8n が 01_inbox を検索（PDF ファイルをリストアップ）

4. PDF が見つかった場合:
   a. ファイルを 02_processing に移動（二重処理防止）
   b. GAS WebApp に fileId を POST → テキスト抽出
   c. 抽出テキストを Gemini API に送信 → JSON 形式のリスク分析結果
   d. 分析結果を Google Docs にフォーマットして保存（04_results）
   e. ファイルを 03_reviewed に移動
   f. 担当者に完了メールを送信
   g. Google Sheets にログを記録
   h. 次のファイルがあれば繰り返し（Split In Batches）

5. PDF が見つからない場合: 即時終了（次のスケジュールまで待機）

エラー発生時:
   - ファイルを 02_processing → 01_inbox に戻す
   - 担当者にエラーメールを送信
```

---

## 認証・セキュリティ設計

### アクセス制御レイヤー

```
[Cloud Scheduler]
  認証: OIDC トークン（Scheduler SA）
  権限: roles/run.invoker on Cloud Run

[開発者]
  認証: gcloud CLI（Google アカウント）
  権限: roles/run.invoker on Cloud Run（Terraform の allowed_invoker_members で設定）
  アクセス方法: gcloud run services proxy（ローカルプロキシ）

[n8n → Secret Manager]
  認証: Cloud Run SA のワークロード ID
  権限: roles/secretmanager.secretAccessor（シークレット単位）

[n8n → Google Workspace]
  認証: OAuth 2.0（n8n UI から認証情報を設定）
```

### 本番移行時の追加セキュリティ

- Cloud Load Balancer + IAP の追加（ブラウザから直接 Google 認証）
- Ingress を `INTERNAL_AND_CLOUD_LOAD_BALANCING` に変更（直接 URL を閉鎖）
- Cloud Armor による GAS WebApp の IP 制限

---

## コスト構造

| コンポーネント | 課金形態 | 月額概算 |
|---|---|---|
| Cloud Run | リクエスト時間 × vCPU/メモリ（Free tier あり） | ¥0〜300 |
| Cloud Scheduler | ジョブ数（3ジョブまで無料） | ¥0 |
| Neon PostgreSQL | ストレージ + コンピュート（Free tier あり） | ¥0 |
| Secret Manager | シークレット数 + アクセス数 | ¥150 |
| GAS WebApp | 無料（Google Apps Script） | ¥0 |
| Gemini API | トークン数（Gemini 1.5 Pro） | 用量依存 |
| **合計** | | **¥150〜500** |

> Gemini API のコスト: Gemini 1.5 Pro は入力 $3.5/1M トークン（128K 以下）。
> 契約書 1 件あたり約 2,000〜10,000 トークンとすると、100 件処理で約 $0.35〜$1.75（¥50〜260）。
