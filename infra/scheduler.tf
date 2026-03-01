# Cloud Scheduler: n8n polling ジョブ
# 5分ごとに n8n の webhook を呼び出し、Drive 01_inbox を確認させる
resource "google_cloud_scheduler_job" "n8n_contract_review_poller" {
  name      = "n8n-contract-review-poller"
  region    = var.region
  schedule  = "*/5 * * * *"
  time_zone = "Asia/Tokyo"

  # コールドスタート（20〜30秒）を考慮した十分なタイムアウト
  attempt_deadline = "540s"

  retry_config {
    retry_count          = 1
    min_backoff_duration = "5s"
    max_backoff_duration = "30s"
  }

  http_target {
    uri         = "${google_cloud_run_v2_service.n8n.uri}/webhook/contract-review-poller"
    http_method = "POST"

    headers = {
      "Content-Type" = "application/json"
    }

    # Cloud Run が理解できる JSON ボディ
    body = base64encode(jsonencode({
      source  = "cloud-scheduler"
      trigger = "contract-review-poll"
    }))

    # Cloud Run IAM 認証（OIDC トークン）
    oidc_token {
      service_account_email = google_service_account.scheduler_sa.email
      # audience は Cloud Run の URI（Cloud Run IAM 検証に使用）
      audience = google_cloud_run_v2_service.n8n.uri
    }
  }

  depends_on = [
    google_project_service.cloud_scheduler,
    google_cloud_run_v2_service.n8n,
  ]
}
