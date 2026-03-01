variable "project_id" {
  description = "GCP プロジェクト ID"
  type        = string
}

variable "region" {
  description = "GCP リージョン"
  type        = string
  default     = "asia-northeast1"
}

variable "n8n_image" {
  description = "n8n Docker イメージ"
  type        = string
  default     = "n8nio/n8n:latest"
}

variable "n8n_webhook_url" {
  description = <<-EOT
    n8n の Webhook ベース URL（Cloud Run の URI）。
    初回 terraform apply 後に outputs.cloud_run_url の値を terraform.tfvars に追記し、
    もう一度 terraform apply することで Cloud Run に反映される。
  EOT
  type        = string
  default     = ""
}

variable "allowed_invoker_members" {
  description = "Cloud Run を呼び出せる追加の IAM メンバー一覧（例: [\"user:you@example.com\"]）"
  type        = list(string)
  default     = []
}
