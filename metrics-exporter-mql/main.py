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
import time
import config
import logging
import numpy as np
from google.cloud import bigquery
from google.cloud import bigquery_storage_v1
from google.cloud.bigquery_storage_v1 import types
from google.cloud.bigquery_storage_v1 import writer
from google.protobuf import descriptor_pb2
import metric_record_flat_pb2

# If you update the metric_record.proto protocol buffer definition, run:
#
#   protoc --python_out=. metric_record_flat.proto
#
# from the samples/snippets directory to generate the metric_record_pb2.py module.

# Fetch GKE metrics - cpu requested cores, cpu limit cores, memory requested bytes, memory limit bytes, count and all workloads with hpa
def get_gke_metrics(metric_name, metric, window):
    # [START get_gke_metrics]
    from google.cloud import monitoring_v3

    client = monitoring_v3.MetricServiceClient()
    project_name = f"projects/{config.PROJECT_ID}"

    now = time.time()
    seconds = int(now)
    nanos = int((now - seconds) * 10 ** 9)
    gke_group_by_fields = [ 'resource.label."location"','resource.label."project_id"','resource.label."cluster_name"','resource.label."controller_name"','resource.label."namespace_name"','metadata.system_labels."top_level_controller_name"','metadata.system_labels."top_level_controller_type"']
    hpa_group_by_fields = ['resource.label."location"','resource.label."project_id"','resource.label."cluster_name"','resource.label."namespace_name"','metric.label."targetref_kind"','metric.label."targetref_name"']
    
    interval = monitoring_v3.TimeInterval(
        {
            "end_time": {"seconds": seconds, "nanos": nanos},
            "start_time": {"seconds": (seconds - window), "nanos": nanos},
        }
    )
    aggregation = monitoring_v3.Aggregation(
        {
            "alignment_period": {"seconds": window},  
            "per_series_aligner": monitoring_v3.Aggregation.Aligner.ALIGN_MAX,
            "cross_series_reducer": monitoring_v3.Aggregation.Reducer.REDUCE_COUNT if metric_name == "count" else monitoring_v3.Aggregation.Reducer.REDUCE_MAX ,
            "group_by_fields": gke_group_by_fields if "hpa" not in metric_name else hpa_group_by_fields,
        }
    )
    results = client.list_time_series(
        request={
            "name": project_name,
            "filter": f'metric.type = "{metric}" AND resource.label.namespace_name != "kube-system"',
            "interval": interval,
            "view": monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL,
            "aggregation": aggregation,
        }
    )
    output = []
    for result in results:
        row = metric_record_flat_pb2.MetricFlatRecord ()
        label = result.resource.labels
        metadata = result.metadata.system_labels.fields
        metricdata = result.metric.labels
        row.metric_name = metric_name
        row.location = label['location']
        row.project_id = label['project_id']
        row.cluster_name = label['cluster_name']
        row.controller_name =  metricdata['targetref_name'] if "hpa" in metric_name else metadata['top_level_controller_name'].string_value 
        row.controller_type= metricdata['targetref_kind'] if "hpa" in metric_name else metadata['top_level_controller_type'].string_value
        row.namespace_name = label['namespace_name']
        row.tstamp = time.time()
        points = result.points
        for point in points:
            if "cpu" in metric_name:
                row.points = (int(point.value.double_value * 1000))
                
            elif "memory" in metric_name:
                row.points = (int(point.value.int64_value/1024/1024))
                
            else:
                row.points = (point.value.int64_value)
            break
        output.append(row.SerializeToString())
    return output

    # [END gke_get_metrics]

# Build VPA recommendations, memory: get max value over 30 days, cpu: get max and 95th percentile
def get_vpa_recommenation_metrics(metric_name, metric, window):

    # [START get_vpa_recommenation_metrics]
    from google.cloud import monitoring_v3
    client = monitoring_v3.MetricServiceClient()
    project_name = f"projects/{config.PROJECT_ID}"
    interval = monitoring_v3.TimeInterval()

    now = time.time()
    seconds = int(now)
    nanos = int((now - seconds) * 10 ** 9)
    
    interval = monitoring_v3.TimeInterval(
        {
            "end_time": {"seconds": seconds, "nanos": nanos},
            "start_time": {"seconds": (seconds - window), "nanos": nanos},
        }
    )
    
    results = client.list_time_series(
        request={
            "name": project_name,
            "filter": f'metric.type = "{metric}" AND resource.label.namespace_name != "kube-system"',
            "interval": interval,
            "view": monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL,
       
        }
    )
    output = []
    
    for result in results:
        points_array = []
        row = metric_record_flat_pb2.MetricFlatRecord ()
        label = result.resource.labels
        row.location = label['location']
        row.project_id = label['project_id']
        row.cluster_name = label['cluster_name']
        row.controller_name = label['controller_name']
        row.controller_type= label['controller_kind']
        row.namespace_name = label['namespace_name']
        row.tstamp = time.time()
        for point in result.points:
            if((point.value.double_value) != 0):
                points_array.append(int(point.value.double_value * 1000))
            else:
                points_array.append(int(point.value.int64_value/1024/1024)) 
        if "cpu" in metric_name :
            row.metric_name = "cpu_request_95th_percentile_recommendations"
            row.points = int(np.percentile(points_array, 95))
            output.append(row.SerializeToString())
            row.metric_name = "cpu_request_max_recommendations"
            row.points = (max(points_array))
            output.append(row.SerializeToString())
        else:
            row.metric_name = metric_name
            row.points = (max(points_array))
            output.append(row.SerializeToString())
    return output
    # [END get_vpa_recommenation_metrics]   
 

# Write rows to BigQuery    
def append_rows_proto(rows):

    """Create a write stream, write some sample data, and commit the stream."""
    write_client = bigquery_storage_v1.BigQueryWriteClient()
    parent = write_client.table_path(config.PROJECT_ID, config.BIGQUERY_DATASET, config.BIGQUERY_TABLE)
    write_stream = types.WriteStream()
    
    # When creating the stream, choose the type. Use the PENDING type to wait
    # until the stream is committed before it is visible. See:
    # https://cloud.google.com/bigquery/docs/reference/storage/rpc/google.cloud.bigquery.storage.v1#google.cloud.bigquery.storage.v1.WriteStream.Type
    write_stream.type_ = types.WriteStream.Type.COMMITTED
    write_stream = write_client.create_write_stream(
        parent=parent, write_stream=write_stream
    )
    stream_name = write_stream.name

    # Create a template with fields needed for the first request.
    request_template = types.AppendRowsRequest()

    # The initial request must contain the stream name.
    request_template.write_stream = stream_name

    # So that BigQuery knows how to parse the serialized_rows, generate a
    # protocol buffer representation of your message descriptor.
    proto_schema = types.ProtoSchema()
    proto_descriptor = descriptor_pb2.DescriptorProto()
    metric_record_flat_pb2.MetricFlatRecord.DESCRIPTOR.CopyToProto(proto_descriptor)
    proto_schema.proto_descriptor = proto_descriptor
    proto_data = types.AppendRowsRequest.ProtoData()
    proto_data.writer_schema = proto_schema
    request_template.proto_rows = proto_data
    
    # Some stream types support an unbounded number of requests. Construct an
    # AppendRowsStream to send an arbitrary number of requests to a stream.
    append_rows_stream = writer.AppendRowsStream(write_client, request_template)

    # Create a batch of row data by appending proto2 serialized bytes to the
    # serialized_rows repeated field.
    proto_rows = types.ProtoRows()
    for row in rows:
        proto_rows.serialized_rows.append(row)
    request = types.AppendRowsRequest()
    request.offset = 0
    proto_data = types.AppendRowsRequest.ProtoData()
    proto_data.rows = proto_rows
    request.proto_rows = proto_data

    append_rows_stream.send(request)

    # Shutdown background threads and close the streaming connection.
    append_rows_stream.close()

    # A PENDING type stream must be "finalized" before being committed. No new
    # records can be written to the stream after this method has been called.
    write_client.finalize_write_stream(name=write_stream.name)

    # Commit the stream you created earlier.
    batch_commit_write_streams_request = types.BatchCommitWriteStreamsRequest()
    batch_commit_write_streams_request.parent = parent
    batch_commit_write_streams_request.write_streams = [write_stream.name]
    write_client.batch_commit_write_streams(batch_commit_write_streams_request)

    print(f"Writes to stream: '{write_stream.name}' have been committed.")

# Purge all data from metrics table. mql_metrics table is used as a staging table and must be purged to avoid duplicate metrics                
def purge_raw_metric_data():
    t = time.time() - 5400
    client = bigquery.Client()   
    metric_table_id = f'{config.PROJECT_ID}.{config.BIGQUERY_DATASET}.{config.BIGQUERY_TABLE}'

    purge_raw_metric_query_job=client.query(
        f"""DELETE {metric_table_id} WHERE TRUE AND tstamp < {t}
        """
    )
    print("Raw metric data purged from  {}".format(metric_table_id))
    purge_raw_metric_query_job.result()

# Use recommendation.sql to build vpa container recommendations    
def build_recommenation_table():
    """ Create recommenations table in BigQuery
    """
    metric_count = 0
    client = bigquery.Client()

    metric_table_id = f'{config.PROJECT_ID}.{config.BIGQUERY_DATASET}.{config.BIGQUERY_TABLE}'
    
    #wait until we have all metrics
    while metric_count != 10 :
        query_metrics = f"""SELECT COUNT(DISTINCT(metric_name)) AS metric_count FROM {metric_table_id}"""
        query_job = client.query(query_metrics)
        results = query_job.result()  # Waits for job to complete.
        
        for row in results:
            metric_count=int("{}".format(row.metric_count))
  
    table_id = f'{config.PROJECT_ID}.{config.BIGQUERY_DATASET}.{config.RECOMMENDATION_TABLE}'
    update_query = f"""UPDATE {table_id}
        SET latest = FALSE
        WHERE latest = TRUE
    """
    query_job = client.query(update_query)
    query_job.result()

    with open('./recommendation.sql','r') as file:
        sql = file.read()
    print("Query results loaded to the table {}".format(table_id))
    
    # Start the query, passing in the recommendation query.
    query_job = client.query(sql)  # Make an API request.
    query_job.result()  # Wait for the job to complete.

def run_pipeline():

    for metric, query in config.MQL_QUERY.items():
        if query[2] == "gke_metric":
            append_rows_proto(get_gke_metrics(metric, query[0], query[1]))
        else:
            append_rows_proto(get_vpa_recommenation_metrics(metric, query[0], query[1]))
    build_recommenation_table()
    purge_raw_metric_data()
    
def export_metric_data(event, context):
    """Background Cloud Function to be triggered by Pub/Sub.
    Args:
         event (dict):  The dictionary with data specific to this type of
         event. The `data` field contains the PubsubMessage message. The
         `attributes` field will contain custom attributes if there are any.
         context (google.cloud.functions.Context): The Cloud Functions event
         metadata. The `event_id` field contains the Pub/Sub message ID. The
         `timestamp` field contains the publish time.
    """
    print("""This Function was triggered by messageId {} published at {}
    """.format(context.event_id, context.timestamp))
    run_pipeline()
         

if __name__ == "__main__":
    run_pipeline()

  
    