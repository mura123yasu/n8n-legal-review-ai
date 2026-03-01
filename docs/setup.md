# セットアップ手順

## 前提条件

- [ ] [gcloud CLI](https://cloud.google.com/sdk/docs/install) インストール済み・ログイン済み
- [ ] [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5 インストール済み
- [ ] GCP プロジェクト作成済み・課金有効化済み
- [ ] Google Workspace アカウント（Drive, Docs, Sheets, Gmail 利用可能）

---

## Phase 1: 外部サービス準備

### 1-1. Neon Serverless PostgreSQL

1. [https://console.neon.tech](https://console.neon.tech) でアカウント作成
2. 新規プロジェクトを作成（リージョン: `Asia Pacific (Singapore)` 推奨）
3. データベース名: `n8ndb`、ユーザー名: `n8n` で作成
4. 接続情報（Host, Password）をメモしておく

### 1-2. Gemini API Key

1. [https://aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey) にアクセス
2. 「API キーを作成」→ キーをメモ

### 1-3. GAS WebApp デプロイ

1. [https://script.google.com](https://script.google.com) で新規プロジェクトを作成
2. `gas/pdf-extractor/Code.gs` の内容をエディタに貼り付け
3. 「サービス」→「Drive API」→ v2 を追加（appsscript.json と一致させる）
4. 「デプロイ」→「新しいデプロイ」→「ウェブアプリ」
   - 実行者: 自分
   - アクセス: 全員
5. 発行された URL をメモ

### 1-4. Google Drive フォルダ作成

Google Drive で以下の構成を作成し、各フォルダの ID（URL の `folders/` 以降）をメモ：

```
📁 契約書レビュー/
  ├── 📁 01_inbox        ← ID をメモ: DRIVE_INBOX_FOLDER_ID
  ├── 📁 02_processing   ← ID をメモ: DRIVE_PROCESSING_FOLDER_ID
  ├── 📁 03_reviewed     ← ID をメモ: DRIVE_REVIEWED_FOLDER_ID
  └── 📁 04_results      ← ID をメモ: DRIVE_RESULTS_FOLDER_ID
```

### 1-5. Google Sheets ログシート作成

1. Google Sheets で新規スプレッドシートを作成
2. シート名を「ログ」に変更
3. 1行目に以下のヘッダーを入力:
   ```
   処理日時 | ファイル名 | 高リスク数 | 中リスク数 | 低リスク数 | 総合リスク | ステータス | DocsURL
   ```
4. スプレッドシートの ID（URL の `/d/` と `/edit` の間の文字列）をメモ: `SHEETS_LOG_ID`

---

## Phase 2: GCP インフラ構築（Terraform）

```bash
cd infra/

# terraform.tfvars を作成（.gitignore で除外済み）
cat > terraform.tfvars <<EOF
project_id              = "your-gcp-project-id"
allowed_invoker_members = ["user:your-email@example.com"]
EOF

# 初期化
terraform init

# 差分確認
terraform plan

# 適用
terraform apply
```

### terraform apply 後: Secret Manager に値をセット

```bash
PROJECT_ID="your-gcp-project-id"  # terraform.tfvars の project_id と同じ値

# Neon 接続情報
gcloud secrets versions add n8n-db-host \
  --project=$PROJECT_ID --data-file=- <<< "ep-xxxx.ap-southeast-1.aws.neon.tech"

gcloud secrets versions add n8n-db-password \
  --project=$PROJECT_ID --data-file=- <<< "your-neon-password"

# n8n 暗号化キー（一度設定したら変更禁止）
gcloud secrets versions add n8n-encryption-key \
  --project=$PROJECT_ID --data-file=- <<< "$(openssl rand -hex 16)"

# API キー
gcloud secrets versions add gemini-api-key \
  --project=$PROJECT_ID --data-file=- <<< "your-gemini-api-key"

# GAS WebApp URL
gcloud secrets versions add gas-webapp-url \
  --project=$PROJECT_ID --data-file=- <<< "https://script.google.com/macros/s/xxxx/exec"

# 通知先メール
gcloud secrets versions add notify-email \
  --project=$PROJECT_ID --data-file=- <<< "your@email.com"

# Cloud Run URL（terraform output から取得）
CLOUD_RUN_URL=$(cd infra && terraform output -raw cloud_run_url)
gcloud secrets versions add n8n-webhook-url \
  --project=$PROJECT_ID --data-file=- <<< "$CLOUD_RUN_URL"
```

### Terraform 再 apply（WEBHOOK_URL を反映）

シークレット値を設定後、Cloud Run を再デプロイして N8N_HOST / WEBHOOK_URL を反映：

```bash
# Cloud Run サービスを強制再デプロイ
gcloud run services update n8n \
  --region=asia-northeast1 \
  --project=$PROJECT_ID
```

---

## Phase 3: n8n 初期セットアップ

### 3-1. n8n 管理 UI へのアクセス

```bash
# ローカルプロキシを起動（Google アカウントで自動認証）
gcloud run services proxy n8n \
  --region=asia-northeast1 \
  --project=your-gcp-project-id \
  --port=8080

# ブラウザで開く
open http://localhost:8080
```

### 3-2. n8n 初期アカウント作成

初回アクセス時にメールアドレス・パスワードの設定を求められます（n8n 内部の管理者アカウント）。

### 3-3. 認証情報の登録

「Settings」→「Credentials」から以下を追加：

| 認証情報名 | 種類 | 設定内容 |
|---|---|---|
| Google Drive account | OAuth2 | Drive API のスコープを許可 |
| Google Docs account | OAuth2 | Docs API のスコープを許可 |
| Gmail account | OAuth2 | Gmail の送信スコープを許可 |
| Google Sheets account | OAuth2 | Sheets API のスコープを許可 |

### 3-4. ワークフローのインポート

1. 「Workflows」→「Import from file」
2. `n8n/workflows/contract-review.json` を選択
3. インポート後、認証情報名が一致していることを確認（上記の名前で統一）

### 3-5. n8n Variables の設定

「Settings」→「Variables」から以下を追加（Phase 1 でメモした値を使用）：

| 変数名 | 値 |
|---|---|
| `DRIVE_INBOX_FOLDER_ID` | Google Drive 01_inbox フォルダの ID |
| `DRIVE_PROCESSING_FOLDER_ID` | Google Drive 02_processing フォルダの ID |
| `DRIVE_REVIEWED_FOLDER_ID` | Google Drive 03_reviewed フォルダの ID |
| `DRIVE_RESULTS_FOLDER_ID` | Google Drive 04_results フォルダの ID |
| `SHEETS_LOG_ID` | Google Sheets スプレッドシートの ID |

### 3-6. ワークフローを Activate

ワークフロー画面右上のトグルを「Active」にする。

---

## Phase 4: 動作確認

### 4-1. 手動テスト

```bash
# Cloud Scheduler を手動で今すぐ実行
gcloud scheduler jobs run n8n-contract-review-poller \
  --location=asia-northeast1 \
  --project=your-gcp-project-id
```

または、01_inbox に PDF を投入して最大 5 分待つ。

### 4-2. 確認ポイント

- [ ] 04_results に「[レビュー済]_ファイル名_日付」のドキュメントが生成される
- [ ] 完了通知メールが届く
- [ ] Google Sheets の「ログ」シートに行が追加される
- [ ] PDF が 03_reviewed に移動している
- [ ] n8n の「Executions」画面でエラーが出ていない

### 4-3. ログ確認

```bash
# Cloud Run のログ確認
gcloud run services logs read n8n \
  --region=asia-northeast1 \
  --project=your-gcp-project-id \
  --limit=50
```

---

## トラブルシューティング

### Cloud Run が起動しない

- Secret Manager の値が正しく設定されているか確認
- `gcloud run services describe n8n --region=asia-northeast1` でエラーを確認

### Neon に接続できない

- `n8n-db-host`, `n8n-db-password` の値を確認
- Neon のダッシュボードで IP 許可リストの設定を確認（デフォルトは全許可）

### GAS WebApp がエラーを返す

- Drive API v2 が有効化されているか確認（GAS エディタの「サービス」を確認）
- ファイルへのアクセス権限を確認

### Gemini API がエラーを返す

- `n8n-encryption-key` の値を確認
- Gemini API の利用制限・課金設定を確認
