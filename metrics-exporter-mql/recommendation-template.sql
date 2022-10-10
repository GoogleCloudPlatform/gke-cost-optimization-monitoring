CREATE MATERIALIZED VIEW project-id.my_dataset.my_mv_table
AS
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
############################
# Number of Containers     #
############################
container_count as (
  SELECT AS VALUE ARRAY_AGG(t ORDER BY `End_time` DESC LIMIT 1)[OFFSET(0)] 
  FROM(
  SELECT 
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.project_id') as Project_id,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'container_name') as Container,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.location') as Location,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.cluster_name') as Cluster_name,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.namespace_name') as Namespace,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') as Controller_name,
  (pointData.values.int64_value) as Num_of_containers,
  (pointData.timeInterval.start_time) as Start_time,
  (pointData.timeInterval.end_time) as End_time,
FROM  containers_without_hpa
WHERE metricName = 'pmemory_request_bytes'
AND pointData.timeInterval.start_time  BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY) AND CURRENT_TIMESTAMP()
ORDER BY Controller_name desc
  ) as t
  group by Project_id, Container, Location, Cluster_name, Namespace, Controller_name
),
############################
# CPU Recommendation Query #
############################
cpu_request_recommendation AS (
SELECT APPROX_QUANTILES(value, 100)[OFFSET(95)] * 1000  AS value, Project_id, Container, Controller_name, Controller_type, Cluster_name, Location, Namespace
FROM
(
  SELECT  
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.project_id') as Project_id,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'container_name') as Container,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.location') as Location,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.cluster_name') as Cluster_name,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.namespace_name') as Namespace,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.controller_kind') as Controller_type,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') as Controller_name,
  (pointData.values.double_value) as value,
  (pointData.timeInterval.start_time) as Start_time,
(pointData.timeInterval.end_time) as End_time,
FROM  containers_without_hpa 
WHERE metricName = 'pcpu_request_recommendation'
AND pointData.timeInterval.start_time  BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY) AND CURRENT_TIMESTAMP() 
GROUP BY 1,2,3,4,5,6,7,8,9,10
)
GROUP BY 2,3,4,5,6,7,8
),
###############################
# Memory Recommendation Query #
###############################
memory_request_recommendations AS(
SELECT MAX(value) as value, Project_id, Container, Controller_name, Controller_type, Cluster_name, Location, Namespace
FROM (
  SELECT 
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.project_id') as Project_id,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'container_name') as Container,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.location') as Location,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.cluster_name') as Cluster_name,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.namespace_name') as Namespace,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.controller_kind') as Controller_type,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') as Controller_name,
 (pointData.values.int64_value/1024/1024) as value,
  (pointData.timeInterval.start_time) as Start_time,
 (pointData.timeInterval.end_time) as End_time,
FROM  containers_without_hpa
WHERE metricName = 'pmemory_request_recommendations' 
AND pointData.timeInterval.start_time  BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY) AND CURRENT_TIMESTAMP()
GROUP BY 1,2,3,4,5,6,7,8,9,10
)
GROUP BY 2,3,4,5,6,7,8
),
###################################
# Current CPU Request Cores Query #
###################################
cpu_request_cores AS(
SELECT  Project_id, Container, Controller_name, Controller_type, Cluster_name, Location, Namespace, MAX(value) as value
FROM (
  SELECT 
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.project_id') as Project_id,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'container_name') as Container,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.location') as Location,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.cluster_name') as Cluster_name,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.namespace_name') as Namespace,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_type') as Controller_type,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') as Controller_name,
  CAST((pointData.values.double_value * 1000) AS int64)  as value,
  (pointData.timeInterval.start_time) as Start_time,
  (pointData.timeInterval.end_time) as End_time,
  FROM containers_without_hpa
  WHERE metricName = 'pcpu_request_cores' 
AND pointData.timeInterval.start_time  BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY) AND CURRENT_TIMESTAMP()
  GROUP BY 1,2,3,4,5,6,7,8,9,10
) 
GROUP BY  1,2,3,4,5,6,7 
),
###################################
# Current CPU Limit Cores Query   #
###################################
cpu_limit_cores AS(
  SELECT Project_id, Container, Controller_name, Controller_type, Cluster_name, Location, Namespace, MAX(value) as value
FROM (
  SELECT 
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.project_id') as Project_id,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'container_name') as Container,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.location') as Location,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.cluster_name') as Cluster_name,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.namespace_name') as Namespace,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_type') as Controller_type,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') as Controller_name,
  CAST((pointData.values.double_value * 1000) AS int64)  as value ,
  (pointData.timeInterval.start_time) as Start_time,
 (pointData.timeInterval.end_time) as End_time,
  FROM  containers_without_hpa 
  WHERE metricName = 'pcpu_limit_cores'
  AND pointData.timeInterval.start_time  BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY) AND CURRENT_TIMESTAMP() 
  GROUP BY 1,2,3,4,5,6,7,8,9,10
) 
GROUP BY  1,2,3,4,5,6,7
) ,
###################################
# Current CPU Usage time.        #
###################################
cpu_usage_time AS(
  SELECT Project_id, Container, Controller_name, Controller_type, Cluster_name, Location, Namespace, MAX(value) as value
FROM (
  SELECT 
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.project_id') as Project_id,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'container_name') as Container,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.location') as Location,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.cluster_name') as Cluster_name,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.namespace_name') as Namespace,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_type') as Controller_type,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') as Controller_name,
  CAST((pointData.values.double_value * 1000) AS int64)  as value ,
  (pointData.timeInterval.start_time) as Start_time,
 (pointData.timeInterval.end_time) as End_time,
  FROM  containers_without_hpa 
  WHERE metricName = 'pcpu_core_usage' 
  AND pointData.timeInterval.start_time  BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY) AND CURRENT_TIMESTAMP()
  GROUP BY 1,2,3,4,5,6,7,8,9,10
) 
GROUP BY  1,2,3,4,5,6,7
) ,
########################################
# Current Memory Requested Bytes Query #
########################################
memory_request_bytes AS(
SELECT Project_id, Container, Controller_name, Controller_type, Cluster_name, Location, Namespace, MAX(value) as value
FROM (
  SELECT 
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.project_id') as Project_id,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'container_name') as Container,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.location') as Location,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.cluster_name') as Cluster_name,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.namespace_name') as Namespace,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_type') as Controller_type,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') as Controller_name,
  CAST((SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'value_request_bytes_max') as INT64)/1024/1024 as value,
  (pointData.timeInterval.start_time) as Start_time,
 (pointData.timeInterval.end_time) as End_time,
FROM  containers_without_hpa 
WHERE metricName = 'pmemory_request_bytes'
AND pointData.timeInterval.start_time  BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY) AND CURRENT_TIMESTAMP()
  GROUP BY 1,2,3,4,5,6,7,8,9,10
) 
GROUP BY  1,2,3,4,5,6,7
) , 
########################################
# Current Memory Limit Bytes Query     #
########################################
memory_limit_bytes AS(
SELECT Project_id, Container, Controller_name, Controller_type, Cluster_name, Location, Namespace,  MAX(value) as value
FROM (
  SELECT 
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.project_id') as Project_id,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'container_name') as Container,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.location') as Location,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.cluster_name') as Cluster_name,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.namespace_name') as Namespace,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_type') as Controller_type,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') as Controller_name,
 CEIL(pointData.values.int64_value/1024/1024) as value,
  (pointData.timeInterval.start_time) as Start_time,
 (pointData.timeInterval.end_time) as End_time,
FROM  containers_without_hpa
WHERE metricName = 'pmemory_limit_bytes' 
AND pointData.timeInterval.start_time  BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY) AND CURRENT_TIMESTAMP()
  GROUP BY 1,2,3,4,5,6,7,8,9,10
) 
GROUP BY  1,2,3,4,5,6,7
),
########################################
# Current Memory Used Bytes Query      #
########################################
memory_bytes_used AS(
SELECT Project_id, Container, Controller_name, Controller_type, Cluster_name, Location, Namespace,  MAX(value) as value
FROM (
  SELECT 
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.project_id') as Project_id,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'container_name') as Container,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.location') as Location,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.cluster_name') as Cluster_name,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'resource.namespace_name') as Namespace,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_type') as Controller_type,
  (SELECT value FROM UNNEST(timeSeriesDescriptor.labels) WHERE key = 'controller_name') as Controller_name,
 CEIL(pointData.values.int64_value/1024/1024) as value,
  (pointData.timeInterval.start_time) as Start_time,
 (pointData.timeInterval.end_time) as End_time,
FROM  containers_without_hpa
WHERE metricName = 'pmemory_bytes_used' 
AND pointData.timeInterval.start_time  BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 DAY) AND CURRENT_TIMESTAMP()
GROUP BY 1,2,3,4,5,6,7,8,9,10
) 
GROUP BY  1,2,3,4,5,6,7
),
#############################
# Container Recommendations #
#############################
recommendations as (
SELECT
cpu_request_cores.Project_id,
cpu_request_cores.Location,
cpu_request_cores.Cluster_name,
cpu_request_cores.Namespace,
cpu_request_cores.Controller_type,
cpu_request_cores.Controller_name,
cpu_request_cores.Container,
container_count.Num_of_containers,
cpu_request_cores.value as CPU_requested_cores,
CAST(cpu_request_recommendation.value as INT64) as CPU_recommended_cores,
cpu_usage_time.value as CPU_usage_time,
CAST((container_count.Num_of_containers * cpu_request_cores.value) - (container_count.Num_of_containers * cpu_request_recommendation.value ) as INT64) as CPU_diff,
memory_request_bytes.value as Memory_requested_bytes,
memory_bytes_used.value as Memory_usage_bytes,
CAST(memory_request_recommendations.value as INT64) as Memory_recommended_bytes,
CAST((container_count.Num_of_containers * memory_request_bytes.value) - (container_count.Num_of_containers * memory_request_recommendations.value ) as INT64) as MEM_diff, 
CAST(
  (
    (container_count.Num_of_containers * cpu_request_cores.value) - (container_count.Num_of_containers * cpu_request_recommendation.value )
  ) 
    + 
  (
    (container_count.Num_of_containers * memory_request_bytes.value )  - (container_count.Num_of_containers * memory_request_recommendations.value)
  ) as INT64) AS Slack_to_prioritize ,
CASE
    WHEN (cpu_request_cores.value + cpu_limit_cores.value + memory_request_bytes.value + memory_limit_bytes.value ) = 0 THEN 'Best Effort'
    WHEN (cpu_request_cores.value = cpu_limit_cores.value) AND (memory_request_bytes.value = memory_limit_bytes.value) AND (cpu_request_cores.value > 0)  THEN 'Guaranteed'
    ELSE 'Burstable'
    END
    AS QoS,
FROM cpu_request_cores 
JOIN container_count ON cpu_request_cores.Controller_name = container_count.Controller_name AND cpu_request_cores.Project_id = container_count.Project_id AND cpu_request_cores.Cluster_name = container_count.Cluster_name
JOIN cpu_limit_cores ON cpu_request_cores.Controller_name = cpu_limit_cores.Controller_name AND cpu_request_cores.Project_id = cpu_limit_cores.Project_id AND cpu_request_cores.Cluster_name = cpu_limit_cores.Cluster_name
JOIN cpu_usage_time ON cpu_request_cores.Controller_name = cpu_usage_time.Controller_name AND cpu_request_cores.Project_id = cpu_usage_time.Project_id AND cpu_request_cores.Cluster_name = cpu_usage_time.Cluster_name 
JOIN memory_request_bytes ON cpu_request_cores.Controller_name = memory_request_bytes.Controller_name AND cpu_request_cores.Project_id = memory_request_bytes.Project_id AND cpu_request_cores.Cluster_name = memory_request_bytes.Cluster
JOIN memory_limit_bytes ON cpu_request_cores.Controller_name = memory_limit_bytes.Controller_name AND cpu_request_cores.Project_id = memory_limit_bytes.Project_id AND cpu_request_cores.Cluster_name = memory_limit_bytes.Cluster_name 
JOIN memory_bytes_used ON cpu_request_cores.Controller_name = memory_bytes_used.Controller_name AND cpu_request_cores.Project_id = memory_bytes_used.Project_id AND cpu_request_cores.Project_id = memory_bytes_used.Project_id 
JOIN memory_request_recommendations ON cpu_request_cores.Controller_name = memory_request_recommendations.Controller_name AND cpu_request_cores.Project_id = memory_request_recommendations.Project_id 
JOIN cpu_request_recommendation ON cpu_request_cores.Controller_name = cpu_request_recommendation.Controller_name AND cpu_request_cores.Project_id = cpu_request_recommendation.Project_id
)
SELECT * FROM recommendations 
ORDER BY recommendations.CPU_diff DESC
