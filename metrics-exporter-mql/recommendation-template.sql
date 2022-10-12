/*
# Copyright 2022 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
*/

############################
# NON-HPA WORKLOADS        #
############################
WITH hpa_workloads as (
  SELECT DISTINCT
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.project_id') as Project_id,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'container_name') as Container,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.location') as Location,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.cluster_name') as Cluster_name,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.namespace_name') as Namespace,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_type') as Controller_type,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') as Controller_name,
  FROM `${PROJECT_ID}.${BIGQUERY_DATASET}.${BIGQUERY_TABLE}`
  WHERE metricName LIKE '%hpa%' 
),
containers_without_hpa as (
SELECT * 
FROM `${PROJECT_ID}.${BIGQUERY_DATASET}.${BIGQUERY_TABLE}`
LEFT JOIN hpa_workloads 
ON (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') = hpa_workloads.Controller_name
WHERE hpa_workloads.Controller_name IS NULL
AND pointData.timeInterval.start_time  BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY) AND CURRENT_TIMESTAMP()
),
WITH hpa_workloads as (
  SELECT DISTINCT
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.project_id') as Project_id,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'container_name') as Container,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.location') as Location,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.cluster_name') as Cluster_name,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.namespace_name') as Namespace,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_type') as Controller_type,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') as Controller_name,
  FROM `root-alignment-365122.metric_export.mql_metrics` 
  WHERE metricName LIKE '%hpa%' 
),
containers_without_hpa as (
SELECT * 
FROM `root-alignment-365122.metric_export.mql_metrics` 
LEFT JOIN hpa_workloads 
ON (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') = hpa_workloads.Controller_name
WHERE hpa_workloads.Controller_name IS NULL
AND pointData.timeInterval.start_time  BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY) AND CURRENT_TIMESTAMP()
)
SELECT 
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.project_id') as Project_id,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'container_name') as Container,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.location') as Location,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.cluster_name') as Cluster_name,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.namespace_name') as Namespace,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_type' or key = 'resource.controller_kind') as Controller_type,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') as Controller_name,
  CAST(AVG(IF(metricName = "count", (pointData.values.int64_value), null)) AS INT64) AS container_count,
  CAST(MAX(IF(metricName = "memory_bytes_used", (pointData.values.int64_value/1024/1024), null)) AS INT64) AS mem_used,
  CAST(MAX(IF(metricName = "memory_request_bytes", (pointData.values.int64_value/1024/1024), null)) AS INT64) AS mem_requested,
  CAST(MAX(IF(metricName = "memory_limit_bytes", (pointData.values.int64_value/1024/1024), null)) AS INT64) AS mem_limit,
  CAST(MAX(IF(metricName = "memory_request_recommendations", (pointData.values.int64_value/1024/1024), NULL))  AS INT64) AS mem_recommendation,
  CAST(AVG(IF(metricName = "cpu_core_usage", (pointData.values.double_value * 1000), NULL)) AS INT64) AS avg_cpu_usage,
  CAST(MAX(IF(metricName = "cpu_core_usage", (pointData.values.double_value * 1000), NULL)) AS INT64) AS peak_cpu_usage,
  CAST(AVG(IF(metricName = "cpu_request_cores", (pointData.values.double_value * 1000), NULL)) AS INT64) AS cpu_requested,
  CAST(AVG(IF(metricName = "cpu_limit_cores", (pointData.values.double_value * 1000), NULL)) AS INT64) AS cpu_limit,
  CAST(APPROX_QUANTILES(((IF(metricName = "cpu_request_recommendation", (pointData.values.double_value * 1000), NULL))), 100)[OFFSET(75)] AS INT64)  AS cpu_recommendation,
  CAST(AVG(IF(metricName = "cpu_request_recommendation", (pointData.values.double_value * 1000), NULL)) AS INT64) AS cpu_recommendation
FROM containers_without_hpa 
group by 1,2,3,4,5,6,7