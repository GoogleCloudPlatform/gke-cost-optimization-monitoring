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
controller_name,							
controller_type,						
namespace_name,			
container_count,
cpu_limit_cores,
cpu_requested_cores,	
memory_limit_bytes,					
memory_requested_bytes,			
memory_request_max_recommendations,								
mem_qos,
cpu_qos,
memory_limit_recommendations,
cpu_request_recommendations,
cpu_limit_recommendations,
cpu_delta,
mem_delta,
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
WITH
  hpa_workloads AS (
  SELECT
    location,
    project_id,
    cluster_name,
    controller_name,
    controller_type,
    namespace_name,
    1 AS flag
  FROM
    `${PROJECT_ID}.${BIGQUERY_DATASET}.${BIGQUERY_MQL_TABLE}`
  WHERE
    metric_name LIKE '%hpa%' ),
###################################################
# Filter out HPA workloads, convert rows to columns
###################################################
  workloads_without_hpa AS (
  SELECT
    *,
    TIMESTAMP(TIMESTAMP_SECONDS(CAST(tstamp AS INT64))) AS recommendation_timestamp,
  FROM (
    SELECT
      DISTINCT(metric_name),
      c.location,
      c.project_id,
      c.cluster_name,
      c.controller_name,
      c.controller_type,
      c.namespace_name, 
      IF((c.points IS NULL), 0, c.points) AS points,
      LAST_VALUE(c.tstamp) OVER (PARTITION BY c.controller_name, c.project_id, c.cluster_name, c.location ORDER BY c.tstamp DESC ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS tstamp,
    FROM
      `${PROJECT_ID}.${BIGQUERY_DATASET}.${BIGQUERY_MQL_TABLE}` AS c
    LEFT JOIN
      hpa_workloads
    ON
      c.controller_name = hpa_workloads.controller_name
      AND c.project_id = hpa_workloads.project_id
      AND c.location = hpa_workloads.location
      AND c.cluster_name = hpa_workloads.cluster_name
    WHERE
      hpa_workloads.flag IS NULL
    ORDER BY
      metric_name) PIVOT(AVG(points) FOR metric_name IN ( 'container_count',
        'memory_requested_bytes',
        'memory_limit_bytes',
        'memory_request_recommendations',
        'cpu_requested_cores',
        'cpu_limit_cores',
        'cpu_request_95th_percentile_recommendations',
        'cpu_request_max_recommendations'))),
###############################
#  QoS
##############################
qos AS (
  SELECT
    * EXCEPT (tstamp),
    CASE
      WHEN (memory_requested_bytes = 0 AND memory_limit_bytes = 0) THEN 'BestEffort'
      WHEN (memory_requested_bytes = memory_limit_bytes)
    AND (memory_requested_bytes> 0) THEN 'Guaranteed'
    ELSE
    'Burstable'
  END
    AS mem_qos,
    CASE
      WHEN (cpu_requested_cores = 0 AND cpu_limit_cores = 0) THEN 'BestEffort'
      WHEN (cpu_requested_cores = cpu_limit_cores)
    AND (cpu_requested_cores > 0) THEN 'Guaranteed'
    ELSE
    'Burstable'
  END
    AS cpu_qos,
  FROM
    workloads_without_hpa
  WHERE
    memory_request_recommendations IS NOT NULL
    AND (cpu_request_max_recommendations IS NOT NULL
      OR cpu_request_95th_percentile_recommendations IS NOT NULL ) ),
##############################################################
# Use QoS to determine the CPU recommendations
##############################################################
recommendation AS (
SELECT * EXCEPT (cpu_request_95th_percentile_recommendations, cpu_request_max_recommendations),
memory_request_recommendations AS memory_limit_recommendation,
IF(cpu_qos = "Guaranteed", cpu_request_max_recommendations,  cpu_request_95th_percentile_recommendations )  as cpu_request_recommendations,
CASE
  WHEN (cpu_limit_cores = 0  or cpu_requested_cores = 0 ) THEN cpu_request_max_recommendations
  WHEN (cpu_qos = "Guaranteed" ) THEN cpu_request_max_recommendations
  ELSE
    CAST(cpu_request_95th_percentile_recommendations * (cpu_limit_cores/cpu_requested_cores)  AS INT64)
  END
  AS cpu_limit_recommendation
FROM qos
),
##############################################################
# Build final recommendation query with prority and advisory
##############################################################
final_recommendation AS (
  SELECT * ,
( IF(cpu_requested_cores IS NULL, 0, cpu_requested_cores) - cpu_request_recommendations ) AS cpu_delta,
( memory_requested_bytes - memory_request_recommendations ) AS mem_delta,
CAST(container_count * ((cpu_requested_cores - cpu_request_recommendations) + (memory_requested_bytes - memory_request_recommendations)/13.4) AS INT64) AS priority,
  CASE
    WHEN (memory_requested_bytes > memory_request_recommendations) THEN "over"
    WHEN (memory_requested_bytes < memory_request_recommendations) THEN "under"
    WHEN (memory_requested_bytes = 0) THEN "not set"
  ELSE
  "ok"
END
  AS mem_provision_status,
  CASE
    WHEN (memory_requested_bytes  > memory_request_recommendations) THEN "cost"
    WHEN (memory_requested_bytes  < memory_request_recommendations) THEN "reliability"
    WHEN (memory_requested_bytes = 0) THEN "reliability"
  ELSE
  "ok"
END
  AS mem_provision_risk,
  CASE
    WHEN (cpu_requested_cores > cpu_request_recommendations) THEN "over"
    WHEN (cpu_requested_cores < cpu_request_recommendations) THEN "under"
    WHEN (cpu_requested_cores = 0 ) THEN "not set"
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
TRUE as latest
FROM recommendation
WHERE cpu_request_recommendations != 0 AND memory_request_recommendations != 0
)

SELECT 
recommendation_timestamp,			
location,
project_id,
cluster_name,
controller_name,							
controller_type,						
namespace_name,			
CAST(container_count AS INT64),
CAST(cpu_limit_cores AS INT64),
CAST(cpu_requested_cores AS INT64),	
CAST(memory_limit_bytes AS INT64),					
CAST(memory_requested_bytes AS INT64),			
CAST(memory_request_recommendations AS INT64) as memory_request_max_recommendations,								
mem_qos,
cpu_qos,
CAST(memory_limit_recommendation AS INT64),
CAST(cpu_request_recommendations AS INT64),
CAST(cpu_limit_recommendation AS INT64),
CAST(cpu_delta AS INT64),
CAST(mem_delta AS INT64),
CAST(priority AS INT64),	
mem_provision_status,
mem_provision_risk,
cpu_provision_status,
cpu_provision_risk,
latest FROM final_recommendation
ORDER BY priority DESC