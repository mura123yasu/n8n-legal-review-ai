output "cloud_run_url" {
  description = <<-EOT
    Cloud Run サービスの URI。
    この値を terraform.tfvars の n8n_webhook_url に設定し、
    Secret Manager の n8n-webhook-url にも設定してから再度 terraform apply を実行すること。
  EOT
  value = google_cloud_run_v2_service.n8n.uri
}

output "n8n_webhook_poller_url" {
  description = "Cloud Scheduler が呼ぶ n8n Webhook の完全 URL"
  value       = "${google_cloud_run_v2_service.n8n.uri}/webhook/contract-review-poller"
}

output "cloud_run_service_account_email" {
  description = "Cloud Run サービスアカウントのメールアドレス"
  value       = google_service_account.cloud_run_sa.email
}

output "scheduler_service_account_email" {
  description = "Cloud Scheduler サービスアカウントのメールアドレス"
  value       = google_service_account.scheduler_sa.email
}

output "setup_next_steps" {
  description = "terraform apply 後に実施すること"
  value       = <<-EOT

    ======================================================
    セットアップ 次のステップ
    ======================================================

    【Step 1】Secret Manager に実際の値をセット
    （以下コマンドを実行 or Cloud Console から設定）

      gcloud secrets versions add n8n-db-host \
        --data-file=- <<< "your-project.ap-southeast-1.aws.neon.tech"

      gcloud secrets versions add n8n-db-password \
        --data-file=- <<< "your-neon-password"

      gcloud secrets versions add n8n-encryption-key \
        --data-file=- <<< "$(openssl rand -hex 16)"

      gcloud secrets versions add gemini-api-key \
        --data-file=- <<< "your-gemini-api-key"

      gcloud secrets versions add gas-webapp-url \
        --data-file=- <<< "https://script.google.com/macros/s/xxxx/exec"

      gcloud secrets versions add notify-email \
        --data-file=- <<< "your@email.com"

      gcloud secrets versions add n8n-webhook-url \
        --data-file=- <<< "${google_cloud_run_v2_service.n8n.uri}"

    【Step 2】n8n 管理 UI へのアクセス（ローカルプロキシ経由）

      gcloud run services proxy n8n \
        --region=${google_cloud_run_v2_service.n8n.location} \
        --port=8080

      → ブラウザで http://localhost:8080 を開く

    【Step 3】n8n UI でワークフローをセットアップ
      詳細は docs/setup.md を参照

    ======================================================
  EOT
}
