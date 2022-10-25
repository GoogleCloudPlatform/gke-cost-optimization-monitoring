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
INSERT 
INTO
  `${PROJECT_ID}.${BIGQUERY_DATASET}.${BIGQUERY_VPA_RECOMMENDATION_TABLE}`
    (
recommendation_timestamp,			
location,
project_id,
cluster_name,							
controller_type,			
controller_name,
container,			
namespace,			
container_count,						
mem_requested,			
mem_limit,								
cpu_requested,			
cpu_limit,
mem_qos,
cpu_qos,
recommendation_mem_request,
recommendation_mem_limit,			
recommendation_cpu_request,
recommendation_cpu_limit,		
mem_delta,
cpu_delta,			
priority,	
mem_provision_status,
mem_provision_risk,
cpu_provision_status,
cpu_provision_risk,
latest
)
###############################
# Gather all HPA workloads
##############################
WITH hpa_workloads AS (
  SELECT 
  location,
  project_id, 
  cluster_name,
  controller_name,
  controller_type,
  namespace_name,
  1 as flag
  FROM `${PROJECT_ID}.${BIGQUERY_DATASET}.${BIGQUERY_MQL_TABLE}`
  WHERE metric_name LIKE '%hpa%'
),
###############################
# Filter out HPA workloads
##############################
workloads_without_hpa AS (
SELECT  
c.location,
c.project_id, 
c.cluster_name,
c.controller_name,
c.controller_type,
c.namespace_name,
hpa_workloads.flag,
(MAX(IF(metric_name = "count", points, NULL))) AS container_count,
(MAX(IF(metric_name = "cpu_limit_cores", points, NULL))) AS cpu_limit_cores,
(MAX(IF(metric_name = "cpu_requested_cores", points, NULL))) AS cpu_requested_cores,
(MAX(IF(metric_name = "memory_limit_bytes", points, NULL))) AS memory_limit_bytes,
(MAX(IF(metric_name = "memory_requested_bytes", points, NULL))) AS memory_requested_bytes,
(MAX(IF(metric_name = "cpu_request_95th_percentile_recommendations", points, NULL))) AS cpu_request_95th_percentile_recommendations,
(MAX(IF(metric_name = "cpu_request_max_recommendations", points, NULL))) AS cpu_request_max_recommendations,
(MAX(IF(metric_name = "memory_request_max_recommendations", points, NULL))) AS memory_request_max_recommendations
FROM `${PROJECT_ID}.${BIGQUERY_DATASET}.${BIGQUERY_MQL_TABLE}` c
 LEFT JOIN
    hpa_workloads
  ON
    c.controller_name = hpa_workloads.controller_name
    AND c.project_id = hpa_workloads.project_id
    AND c.location = hpa_workloads.location
    AND c.cluster_name = hpa_workloads.cluster_name
  WHERE
   hpa_workloads.flag IS NULL
GROUP BY 1,2,3,4,5,6,7),
###############################
# Recommendations with QoS
##############################
  recommendation_with_qos AS (
  SELECT
    * EXCEPT (flag),
    CASE
      WHEN (memory_requested_bytes + memory_limit_bytes) = 0 THEN 'BestEffort'
      WHEN (memory_requested_bytes = memory_limit_bytes)
    AND (memory_requested_bytes> 0) THEN 'Guaranteed'
    ELSE
    'Burstable'
  END
    AS mem_qos,
    CASE
      WHEN (cpu_requested_cores + cpu_limit_cores) = 0 THEN 'BestEffort'
      WHEN (cpu_requested_cores = cpu_limit_cores)
    AND (cpu_requested_cores  > 0) THEN 'Guaranteed'
    ELSE
    'Burstable'
  END
    AS cpu_qos,
  FROM
    workloads_without_hpa
  WHERE
    memory_request_max_recommendations IS NOT NULL
    AND (cpu_request_max_recommendations IS NOT NULL OR cpu_request_95th_percentile_recommendations IS NOT NULL )),
##############################################################
# Use QoS to determine the CPU recommendations
##############################################################
recommendation AS (
SELECT * EXCEPT (cpu_request_95th_percentile_recommendations, cpu_request_max_recommendations),
IF(cpu_qos = "Guaranteed", cpu_request_max_recommendations,  cpu_request_95th_percentile_recommendations ) as cpu_request_recommendations,
FROM recommendation_with_qos
)
##############################################################
# Build file recommendation query with prority and advisory
##############################################################
SELECT * ,
( cpu_requested_cores - cpu_request_recommendations ) AS cpu_delta,
( memory_requested_bytes - memory_request_max_recommendations ) AS cpu_delta,
CAST(container_count * ((cpu_requested_cores - cpu_request_recommendations) + (memory_requested_bytes - memory_request_max_recommendations)/13.4) AS INT64) AS priority,
  CASE
    WHEN (memory_requested_bytes > memory_request_max_recommendations) THEN "over"
    WHEN (memory_requested_bytes < memory_request_max_recommendations) THEN "under"
    WHEN (memory_requested_bytes = 0) THEN "not set"
  ELSE
  "ok"
END
  AS mem_provision_status,
  CASE
    WHEN (memory_requested_bytes  > memory_request_max_recommendations) THEN "cost"
    WHEN (memory_requested_bytes  < memory_request_max_recommendations) THEN "reliability"
    WHEN (memory_requested_bytes  = 0) THEN "reliability"
  ELSE
  "ok"
END
  AS mem_provision_risk,
  CASE
    WHEN (cpu_requested_cores > cpu_request_recommendations) THEN "over"
    WHEN (cpu_requested_cores < cpu_request_recommendations) THEN "under"
    WHEN (cpu_requested_cores = 0) THEN "not set"
  ELSE
  "ok"
END
  AS cpu_provision_status,
  CASE
    WHEN (cpu_requested_cores > cpu_request_recommendations) THEN "cost"
    WHEN (cpu_requested_cores < cpu_request_recommendations) THEN "performance"
    WHEN (cpu_requested_cores = 0) THEN "reliability"
  ELSE
  "ok"
END
  AS cpu_provision_risk,
FROM recommendation

