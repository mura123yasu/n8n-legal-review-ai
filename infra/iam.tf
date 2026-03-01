# Cloud Run 用サービスアカウント
resource "google_service_account" "cloud_run_sa" {
  account_id   = "n8n-cloud-run"
  display_name = "n8n Cloud Run Service Account"
  description  = "n8n Cloud Run サービスが使用するサービスアカウント"
}

# Cloud Scheduler 用サービスアカウント
resource "google_service_account" "scheduler_sa" {
  account_id   = "n8n-scheduler"
  display_name = "n8n Cloud Scheduler Service Account"
  description  = "Cloud Scheduler が n8n webhook を呼び出すためのサービスアカウント"
}

# Scheduler SA に Cloud Scheduler の実行権限を付与
resource "google_project_iam_member" "scheduler_job_runner" {
  project = var.project_id
  role    = "roles/cloudscheduler.jobRunner"
  member  = "serviceAccount:${google_service_account.scheduler_sa.email}"
}
