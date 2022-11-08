locals {
  projectservices = toset(
    ["cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudscheduler.googleapis.com",
    "monitoring.googleapis.com",
    "bigquery.googleapis.com"])
  templatevars = tomap({
    "PROJECT_ID" = var.exporter_project_id,
    "PUBSUB_TOPIC" = "mql_metric_export",
    "BIGQUERY_DATASET" = var.bq_dataset_name,
    "BIGQUERY_MQL_TABLE" = var.bq_mql_table,
    "BIGQUERY_VPA_RECOMMENDATION_TABLE" = var.bq_vpa_recommendation_table}
    )
}


## Set up Scope Project
resource "google_project" "scope" {
    name = var.scope_project_id
    project_id = var.scope_project_id
    org_id = var.org_id
    billing_account = var.billing_account
    #folder_id = var.folder_id
}

resource "google_project_service" "project_services" {
  for_each = local.projectservices
  service = each.key
  project = var.scope_project_id
}

resource "google_monitoring_monitored_project" "monitoring_projects" {
  for_each = toset(var.scope_project_list)
  metrics_scope = var.scope_project_id
  name = each.value
}

#Bucket for CF files
resource "google_storage_bucket" "cf_files" {
  project = var.exporter_project_id
  name = "${google_project.scope.project_id}-functionfiles"
  location = var.bq_dataset_region
  force_destroy = true
  #argolis
  uniform_bucket_level_access = true
}

## Set up BQ
resource "google_bigquery_dataset" "metric_exports" {
  project = var.scope_project_id
  location = var.bq_dataset_region
  dataset_id = var.bq_dataset_name
}

resource "google_bigquery_table" "mql_table" {
  project = var.exporter_project_id
  dataset_id = google_bigquery_dataset.metric_exports.dataset_id
  table_id = var.bq_mql_table
  time_partitioning {
    type = "DAY"
  }
  schema = file("${path.module}/bigquery_schema.json")
}

resource "google_bigquery_table" "vpa_recommendation_table" {
  project = var.exporter_project_id
  dataset_id = google_bigquery_dataset.metric_exports.dataset_id
  table_id = var.bq_vpa_recommendation_table
  time_partitioning {
    type = "DAY"
    }
  schema = file("${path.module}/bigquery_recommendation_schema.json")
}

## Set up SA/IAM
resource "google_service_account" "mql-export-metrics" {
  account_id = "mql-export-metrics"
  description =  "Used for the function that export monitoring metrics"
  project = var.scope_project_id
}

#resource "google_project_iam_member" "gce_service_account" {
#  count = length(var.gce_service_account_roles)
# project = element(
#   split("=>", element(var.gce_service_account_roles, count.index)),
#   0,
#  )
# role = element(
#   split("=>", element(var.gce_service_account_roles, count.index)),
#    1,
#  )
#  member = "serviceAccount:${google_service_account.mql-export-metrics.email}"
#}


resource "google_project_iam_member" "metric_exporter-monitoringViewer" {
  for_each = toset(var.scope_project_list)
  project = each.value
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.mql-export-metrics.email}"
}

resource "google_project_iam_member" "metric_exporter-dataEditor" {
  project = var.exporter_project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.mql-export-metrics.email}"
}

resource "google_project_iam_member" "metric_exporter-dataOwner" {
  project = var.exporter_project_id
  role    = "roles/bigquery.dataOwner"
  member  = "serviceAccount:${google_service_account.mql-export-metrics.email}"
}

resource "google_project_iam_member" "metric_exporter-jobUser" {
  project = var.exporter_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.mql-export-metrics.email}"
}

## Set up Exporter Pipeline
resource "google_pubsub_topic" "mql_metric_export" {
  project = var.exporter_project_id
  name = "mql_metric_export"
}

## Templatize CF file(s)
## TODO figure out sources - helpful if it were a zip or own folder to zip->upload
resource "local_file" "recommendation_template" {
  content = templatefile("${path.module}/recommendation-template.sql", local.templatevars)
  filename = "./function/recommendation.sql"
}

resource "local_file" "config" {
  content = templatefile("${path.module}/config-template.py", local.templatevars)
  filename = "./function/config.py"
}

data "archive_file" "cf_file_zip" {
  output_path = "./function/exporter_cf.zip"
  source_dir  = "./function/"
  type        = "zip"
  depends_on = [
    local_file.config,
    local_file.recommendation_template
  ]
}

resource "google_storage_bucket_object" "cfzip" {
  bucket = google_storage_bucket.cf_files.id
  name = "exporter_cf.zip"
  source = data.archive_file.cf_file_zip.output_path
}

resource "google_cloudfunctions_function" "mql-export-metric" {
  project = var.exporter_project_id
  name = "mql-export-metric"
  region = var.region
  runtime = "python39"
  available_memory_mb = 512
  timeout = 540
  entry_point = "export_metric_data"
  service_account_email = google_service_account.mql-export-metrics.email
  environment_variables = {PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION = "python"}
  source_archive_bucket = google_storage_bucket.cf_files.name
  source_archive_object = google_storage_bucket_object.cfzip.name
  #Just for Argolis
  ingress_settings = "ALLOW_INTERNAL_AND_GCLB"

  event_trigger {
    event_type = "providers/cloud.pubsub/eventTypes/topic.publish"
    resource = google_pubsub_topic.mql_metric_export.name
  }
}
resource "google_cloud_scheduler_job" "get_metric_mql" {
  project = var.exporter_project_id
  region = var.region
  name = "get_metric_mql"
  schedule = "* 23 * * *"
  time_zone = var.scheduler_timezone
  pubsub_target {
    topic_name = google_pubsub_topic.mql_metric_export.id
    data = base64encode("Exporting metric...")
  }
}

