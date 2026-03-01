# Cloud Run サービス: n8n ワークフローエンジン
resource "google_cloud_run_v2_service" "n8n" {
  name     = "n8n"
  location = var.region

  # ingress: ALL = Cloud Scheduler からの直接アクセスを許可
  # 認証は Cloud Run IAM（no-allow-unauthenticated）で制御
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.cloud_run_sa.email

    scaling {
      min_instance_count = 0 # コールドスタート許容（検証用）
      max_instance_count = 2
    }

    containers {
      image = var.n8n_image

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        # リクエスト処理中のみ CPU を確保（アイドル時課金なし）
        cpu_idle = true
      }

      # ============================================================
      # 通常の環境変数
      # ============================================================
      env {
        name  = "N8N_PROTOCOL"
        value = "https"
      }

      env {
        name  = "N8N_BASIC_AUTH_ACTIVE"
        value = "false"
      }

      env {
        name  = "DB_TYPE"
        value = "postgresdb"
      }

      env {
        name  = "DB_POSTGRESDB_PORT"
        value = "5432"
      }

      env {
        name  = "DB_POSTGRESDB_SSL"
        value = "true"
      }

      env {
        name  = "EXECUTIONS_DATA_PRUNE"
        value = "true"
      }

      # 7日以上前の実行履歴を自動削除
      env {
        name  = "EXECUTIONS_DATA_MAX_AGE"
        value = "168"
      }

      # ============================================================
      # Secret Manager から取得する環境変数
      # ============================================================
      env {
        name = "DB_POSTGRESDB_HOST"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["n8n-db-host"].secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "DB_POSTGRESDB_DATABASE"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["n8n-db-name"].secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "DB_POSTGRESDB_USER"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["n8n-db-user"].secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "DB_POSTGRESDB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["n8n-db-password"].secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "N8N_ENCRYPTION_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["n8n-encryption-key"].secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "N8N_HOST"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["n8n-webhook-url"].secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "WEBHOOK_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["n8n-webhook-url"].secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "GEMINI_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["gemini-api-key"].secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "GAS_WEBAPP_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["gas-webapp-url"].secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "NOTIFY_EMAIL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["notify-email"].secret_id
            version = "latest"
          }
        }
      }

      # n8n の起動確認用ヘルスチェック
      startup_probe {
        http_get {
          path = "/healthz"
        }
        initial_delay_seconds = 30
        timeout_seconds       = 5
        period_seconds        = 10
        failure_threshold     = 5
      }

      liveness_probe {
        http_get {
          path = "/healthz"
        }
        initial_delay_seconds = 60
        timeout_seconds       = 5
        period_seconds        = 30
        failure_threshold     = 3
      }
    }
  }

  depends_on = [
    google_project_service.cloud_run,
    google_secret_manager_secret_iam_binding.cloud_run_secret_access,
  ]
}

# ============================================================
# Cloud Run IAM: 認証済みユーザー・SA のみ呼び出し可能
# allUsers を含めないことで unauthenticated アクセスを拒否
# ============================================================
resource "google_cloud_run_v2_service_iam_binding" "invoker" {
  location = google_cloud_run_v2_service.n8n.location
  name     = google_cloud_run_v2_service.n8n.name
  role     = "roles/run.invoker"

  members = concat(
    # Cloud Scheduler SA は常に許可
    ["serviceAccount:${google_service_account.scheduler_sa.email}"],
    # 追加の開発者・管理者（variables.tf の allowed_invoker_members で指定）
    var.allowed_invoker_members,
  )
}
