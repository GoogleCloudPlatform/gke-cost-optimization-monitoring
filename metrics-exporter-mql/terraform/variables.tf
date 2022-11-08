variable "org_id" {
  description = "Organization ID"
}

variable "folder_id" {
  description = "Folder ID, if desired"
  default = null
}

variable "billing_account" {
  description = "Billing account ID"
}

variable "scope_project_id" {
  description = "Project ID for your Metric Scope"
}

variable "scope_project_list" {
  #type = list(string)
  description = "Set of [\"project1\",\"project2\"] of project_ids for projects within the Metric Scope"
}

variable "exporter_project_id" {
  description = "Project ID for your Metric Export Pipeline Resources"
}

variable "region" {
  description = "Region for exporter resources (ie Scheduler)"
}

variable "bq_dataset_name" {
  default = "gke_optimization"
}

variable "bq_dataset_region" {
  default = "US"
}

variable "bq_mql_table" {
  default = "mql_export"
}

variable "bq_vpa_recommendation_table" {
  default = "vpa_recs_export"
}

variable "create_service_account" {
  type = bool
  default = true
}

variable "scheduler_timezone" {
  default = "Etc/UTC"
  description = "The value of this field must be a time zone name from the tz database. Default is Etc/UTC"
}
