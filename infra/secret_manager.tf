# ============================================================
# Secret Manager: シークレット定義
# ------------------------------------------------------------
# terraform apply 後、以下コマンドで実際の値をセットしてください:
#   gcloud secrets versions add <SECRET_ID> --data-file=- <<< "実際の値"
# ============================================================

locals {
  secrets = {
    "n8n-db-host"        = "Neon PostgreSQL ホスト名"
    "n8n-db-name"        = "Neon データベース名"
    "n8n-db-user"        = "Neon データベースユーザー名"
    "n8n-db-password"    = "Neon データベースパスワード"
    "n8n-encryption-key" = "n8n 認証情報の暗号化キー（32文字以上のランダム文字列）"
    "n8n-webhook-url"    = "Cloud Run の URI（初回 apply 後に outputs.cloud_run_url の値を設定）"
    "gemini-api-key"     = "Gemini API キー"
    "gas-webapp-url"     = "GAS WebApp の URL"
    "notify-email"       = "レビュー完了通知先メールアドレス"
  }
}

# シークレットリソース（for_each でまとめて作成）
resource "google_secret_manager_secret" "secrets" {
  for_each  = local.secrets
  secret_id = each.key

  labels = {
    app = "n8n"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.secret_manager]
}

# 初期バージョン: placeholder 値で作成（実際の値は apply 後に手動設定）
# 注意: 以下のダミー値を実際の値に必ず上書きすること
resource "google_secret_manager_secret_version" "n8n_db_host" {
  secret      = google_secret_manager_secret.secrets["n8n-db-host"].id
  secret_data = "REPLACE_WITH_NEON_HOST"

  lifecycle {
    # terraform apply で上書きされないよう、手動設定後は ignore_changes を検討
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret_version" "n8n_db_name" {
  secret      = google_secret_manager_secret.secrets["n8n-db-name"].id
  secret_data = "n8ndb"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret_version" "n8n_db_user" {
  secret      = google_secret_manager_secret.secrets["n8n-db-user"].id
  secret_data = "n8n"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret_version" "n8n_db_password" {
  secret      = google_secret_manager_secret.secrets["n8n-db-password"].id
  secret_data = "REPLACE_WITH_NEON_PASSWORD"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret_version" "n8n_encryption_key" {
  secret      = google_secret_manager_secret.secrets["n8n-encryption-key"].id
  secret_data = "REPLACE_WITH_RANDOM_32CHAR_KEY"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret_version" "n8n_webhook_url" {
  secret      = google_secret_manager_secret.secrets["n8n-webhook-url"].id
  secret_data = "REPLACE_WITH_CLOUD_RUN_URI_AFTER_FIRST_APPLY"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret_version" "gemini_api_key" {
  secret      = google_secret_manager_secret.secrets["gemini-api-key"].id
  secret_data = "REPLACE_WITH_GEMINI_API_KEY"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret_version" "gas_webapp_url" {
  secret      = google_secret_manager_secret.secrets["gas-webapp-url"].id
  secret_data = "REPLACE_WITH_GAS_WEBAPP_URL"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret_version" "notify_email" {
  secret      = google_secret_manager_secret.secrets["notify-email"].id
  secret_data = "REPLACE_WITH_NOTIFY_EMAIL"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

# Cloud Run SA にシークレットへのアクセス権を付与
resource "google_secret_manager_secret_iam_binding" "cloud_run_secret_access" {
  for_each  = local.secrets
  secret_id = google_secret_manager_secret.secrets[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"

  members = [
    "serviceAccount:${google_service_account.cloud_run_sa.email}",
  ]
}
