# n8n Legal Review AI

バックオフィス業務（リーガル・人事・広報・総務）向けのAI自動化ワークフロー基盤。
第一弾として **契約書AIレビュー補助ワークフロー** を Google Cloud + n8n + Gemini API で実装。

---

## アーキテクチャ概要

```
[Cloud Scheduler]  5分ごと / OIDC 認証
  │
  ▼
[Cloud Run: n8n]  min=0（従量課金）
  │
  ├─▶ [Google Drive]      01_inbox を確認・ファイル移動
  ├─▶ [GAS WebApp]        PDF → テキスト抽出（OCR）
  ├─▶ [Gemini API]        契約書分析
  ├─▶ [Google Docs]       レビュー結果ドキュメント生成
  ├─▶ [Gmail]             完了通知メール
  └─▶ [Google Sheets]     処理ログ記録

[Secret Manager]        シークレット一元管理
[Neon Serverless PG]    n8n の DB（スケールゼロ対応）
```

詳細は [docs/architecture.md](docs/architecture.md) を参照。

---

## コスト概算（検証環境）

| コンポーネント | 設定 | 月額概算 |
|---|---|---|
| Cloud Run（n8n） | min=0、リクエスト時のみ課金 | ¥0〜300 |
| Cloud Scheduler | 5分ポーリング | ¥0（無料枠） |
| Neon PostgreSQL | Free tier（0.5GB） | ¥0 |
| Secret Manager | 〜10シークレット | ¥150 |
| **合計** | | **≈ ¥150/月** |

---

## クイックスタート

### 前提条件

- gcloud CLI（認証済み）
- Terraform >= 1.5
- GCP プロジェクト（課金有効化済み）

### Step 1: 外部サービス準備

```bash
# 1. Neon アカウント作成 → プロジェクト・DB 作成
#    https://console.neon.tech

# 2. Gemini API Key 取得
#    https://aistudio.google.com/app/apikey

# 3. GAS WebApp デプロイ（gas/pdf-extractor/Code.gs を GAS エディタに貼り付けてデプロイ）
```

### Step 2: インフラ構築

```bash
cd infra/

# terraform.tfvars を作成
cat > terraform.tfvars <<EOF
project_id              = "your-gcp-project-id"
allowed_invoker_members = ["user:your-email@example.com"]
EOF

terraform init
terraform plan
terraform apply

# outputs から Cloud Run URL を確認
terraform output cloud_run_url
```

### Step 3: Secret Manager に値をセット

```bash
PROJECT_ID="your-gcp-project-id"

gcloud secrets versions add n8n-db-host      --project=$PROJECT_ID --data-file=- <<< "your-neon-host"
gcloud secrets versions add n8n-db-password  --project=$PROJECT_ID --data-file=- <<< "your-neon-password"
gcloud secrets versions add n8n-encryption-key --project=$PROJECT_ID --data-file=- <<< "$(openssl rand -hex 16)"
gcloud secrets versions add gemini-api-key   --project=$PROJECT_ID --data-file=- <<< "your-api-key"
gcloud secrets versions add gas-webapp-url   --project=$PROJECT_ID --data-file=- <<< "your-gas-url"
gcloud secrets versions add notify-email     --project=$PROJECT_ID --data-file=- <<< "your@email.com"
gcloud secrets versions add n8n-webhook-url  --project=$PROJECT_ID --data-file=- <<< "$(terraform output -raw cloud_run_url)"
```

### Step 4: n8n セットアップ

```bash
# ローカルプロキシ経由でアクセス
gcloud run services proxy n8n --region=asia-northeast1 --port=8080

# ブラウザで http://localhost:8080 を開く
# → Google 認証情報を登録 → ワークフローをインポート → Variables を設定 → Activate
```

詳細は [docs/setup.md](docs/setup.md) を参照。

---

## ディレクトリ構成

```
n8n-legal-review-ai/
├── infra/                    # Terraform（GCP インフラ定義）
│   ├── main.tf               # プロバイダ・API 有効化
│   ├── variables.tf          # 変数定義
│   ├── outputs.tf            # 出力値
│   ├── cloud_run.tf          # n8n Cloud Run サービス
│   ├── scheduler.tf          # Cloud Scheduler（5分ポーリング）
│   ├── secret_manager.tf     # シークレット管理
│   └── iam.tf                # サービスアカウント・権限
├── n8n/workflows/
│   └── contract-review.json  # n8n ワークフロー（インポート用）
├── gas/pdf-extractor/
│   ├── Code.gs               # PDF → テキスト抽出 WebApp
│   └── appsscript.json       # GAS マニフェスト
├── prompts/
│   └── contract-review.md    # Gemini プロンプトテンプレート
└── docs/
    ├── architecture.md       # アーキテクチャ詳細
    ├── setup.md              # セットアップ手順詳細
    └── workflow-design.md    # ワークフロー設計詳細
```

---

## 注意事項

- AI 分析結果は**補助資料**です。最終判断は必ず法務担当者が行ってください
- 契約書データは機密情報のため、GCP プロジェクトのアクセス権限管理を徹底してください
- Gemini API に送信するテキストの取り扱いポリシーを社内で確認・合意してから本番運用してください

---

## 今後の拡張予定

| ユースケース | 担当部門 | 優先度 |
|---|---|---|
| 採用応募の自動トリアージ | 人事 | ★★★ |
| 社内問い合わせ自動一次回答 | 総務 | ★★☆ |
| プレスリリース下書き生成 | 広報 | ★★☆ |
| 入退社オンボーディング自動化 | 人事・総務 | ★☆☆ |
