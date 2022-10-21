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

PROJECT_ID = "${PROJECT_ID}"
PUBSUB_TOPIC = "${PUBSUB_TOPIC}"
BIGQUERY_DATASET = "${BIGQUERY_DATASET}"
BIGQUERY_TABLE = "${BIGQUERY_MQL_TABLE}"
RECOMMENDATION_TABLE = "${BIGQUERY_VPA_RECOMMENDATION_TABLE}"
WITHIN_QUERY = "1h"
POINTS_EVERY = "15m"
RECOMMENDATION_POINTS_EVERY = "15m"
RECOMMENDATION_WINDOW = "15d"
# IMPORTANT: to guarantee successfully retriving data, please use a time window greater than 5 minutes

MQL_QUERY = {
    "count":
    f"""
fetch k8s_container::kubernetes.io/container/cpu/request_cores
  | filter
    (metadata.system_labels.top_level_controller_type != 'DaemonSet')
    && (resource.namespace_name != 'kube-system') 
  | every 1d
| group_by 
    [container_name: resource.container_name, 
    resource.project_id, 
    location: resource.location, 
    cluster_name: resource.cluster_name,
    namespace_name: resource.namespace_name, 
       controller_name: metadata.system_labels.top_level_controller_name,
       controller_type: metadata.system_labels.top_level_controller_type],[row_count: row_count()]
| within {WITHIN_QUERY}
""",
    # CPU Metrics
    "cpu_request_cores":
    f"""
fetch k8s_container::kubernetes.io/container/cpu/request_cores
  | filter
    (metadata.system_labels.top_level_controller_type != 'DaemonSet')
    && (resource.namespace_name != 'kube-system') 

  | every {POINTS_EVERY}
| group_by 
    [container_name: resource.container_name, 
    resource.project_id, 
    location: resource.location, 
    cluster_name: resource.cluster_name,
    namespace_name: resource.namespace_name, 
       controller_name: metadata.system_labels.top_level_controller_name,
       controller_type: metadata.system_labels.top_level_controller_type]
| within {WITHIN_QUERY}
""",
    "cpu_limit_cores":
    f"""
fetch k8s_container::kubernetes.io/container/cpu/limit_cores
| filter
    (metadata.system_labels.top_level_controller_type != 'DaemonSet')
    && (resource.namespace_name != 'kube-system')
| every {POINTS_EVERY}
| group_by 
        [container_name: resource.container_name, 
    resource.project_id, 
    location: resource.location, 
    cluster_name: resource.cluster_name,
    namespace_name: resource.namespace_name, 
       controller_name: metadata.system_labels.top_level_controller_name,
       controller_type: metadata.system_labels.top_level_controller_type]
| within {WITHIN_QUERY}
""",
    # Memory metrics
    "memory_request_bytes":
    f"""
    fetch k8s_container::kubernetes.io/container/memory/request_bytes
    | filter
        (metadata.system_labels.top_level_controller_type != 'DaemonSet')
        && (resource.namespace_name != 'kube-system')
    | every {POINTS_EVERY}
    | group_by [container_name: resource.container_name, 
        resource.project_id, 
        location: resource.location, 
        cluster_name: resource.cluster_name,
        namespace_name: resource.namespace_name, 
        controller_name: metadata.system_labels.top_level_controller_name,
        controller_type: metadata.system_labels.top_level_controller_type]
    | within {WITHIN_QUERY}
    """,
    "memory_limit_bytes":
    f"""
fetch k8s_container::kubernetes.io/container/memory/limit_bytes
| filter
    (metadata.system_labels.top_level_controller_type != 'DaemonSet')
    && (resource.namespace_name != 'kube-system')
| every {POINTS_EVERY}
| group_by [container_name: resource.container_name, 
    resource.project_id, 
    location: resource.location, 
    cluster_name: resource.cluster_name,
    namespace_name: resource.namespace_name, 
       controller_name: metadata.system_labels.top_level_controller_name,
       controller_type: metadata.system_labels.top_level_controller_type]
| within {WITHIN_QUERY}
""",
    "memory_request_recommendations":
    f"""
fetch k8s_scale :: kubernetes.io/autoscaler/container/memory/per_replica_recommended_request_bytes
| every {RECOMMENDATION_POINTS_EVERY}
| group_by  
      [container_name: metric.container_name, 
      resource.project_id, 
    location: resource.location, 
    cluster_name: resource.cluster_name,
    namespace_name: resource.namespace_name, 
       controller_type: resource.controller_kind, controller_name: resource.controller_name]
| within {RECOMMENDATION_WINDOW}
""",
    "cpu_request_recommendation":
    f"""
fetch k8s_scale :: kubernetes.io/autoscaler/container/cpu/per_replica_recommended_request_cores
| every {RECOMMENDATION_POINTS_EVERY}
| group_by
    [container_name: metric.container_name, 
    resource.project_id, 
    location: resource.location, 
    cluster_name: resource.cluster_name,
    namespace_name: resource.namespace_name, 
       controller_type: resource.controller_kind, 
       controller_name: resource.controller_name]
| within {RECOMMENDATION_WINDOW}
""",
    # HPA workloads
    "hpa_cpu":
    f"""
 fetch k8s_pod :: custom.googleapis.com/podautoscaler/hpa/cpu/target_utilization
   | every 1d
      | group_by
      [container_name: resource.pod_name, 
    resource.project_id, 
    location: resource.location, 
    cluster_name: resource.cluster_name,
    namespace_name: resource.namespace_name, 
       controller_type: metric.targetref_kind, 
       controller_name: metric.targetref_name]
| within {WITHIN_QUERY}
""",
    "hpa_memory":
    f"""
fetch k8s_pod :: custom.googleapis.com/podautoscaler/hpa/memory/target_utilization
      | every 1d
      | group_by
          [container_name: resource.pod_name, 
    resource.project_id, 
    location: resource.location, 
    cluster_name: resource.cluster_name,
    namespace_name: resource.namespace_name, 
       controller_type: metric.targetref_kind, 
       controller_name: metric.targetref_name]
| within {WITHIN_QUERY}
"""
}

BASE_URL = "https://monitoring.googleapis.com/v3/projects"
QUERY_URL = f"{BASE_URL}/{PROJECT_ID}/timeSeries:query"


BQ_VALUE_MAP = {
    "INT64": "int64_value",
    "BOOL": "boolean_value",
    "DOUBLE": "double_value",
    "STRING": "string_value",
    "DISTRIBUTION": "distribution_value"
}

API_VALUE_MAP = {
    "INT64": "int64Value",
    "BOOL": "booleanValue",
    "DOUBLE": "doubleValue",
    "STRING": "stringValue",
    "DISTRIBUTION": "distributionValue"
}
