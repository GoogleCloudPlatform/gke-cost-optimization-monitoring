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
import io
import base64
import re
import logging
import json
import config
import requests
import subprocess
from datetime import date
from google.cloud import bigquery
from google.cloud import bigquery_storage_v1
from google.cloud.bigquery_storage_v1 import types
from google.cloud.bigquery_storage_v1 import writer
from google.protobuf import descriptor_pb2
import metric_record_pb2
from google.protobuf.json_format import Parse, ParseDict
# If you update the metric_record.proto protocol buffer definition, run:
#
#   protoc --python_out=. metric_record.proto
#
# from the samples/snippets directory to generate the metric_record_pb2.py module.
token = None
DISTRIBUTION = "DISTRIBUTION"

METADATA_URL = "http://metadata.google.internal/computeMetadata/v1/"
METADATA_HEADERS = {"Metadata-Flavor": "Google"}
SERVICE_ACCOUNT = "default"


def get_access_token_from_meta_data():
    url = '{}instance/service-accounts/{}/token'.format(
        METADATA_URL, SERVICE_ACCOUNT)

    # Request an access token from the metadata server.
    r = requests.get(url, headers=METADATA_HEADERS)
    r.raise_for_status()

    # Extract the access token from the response.
    token = r.json()['access_token']
    return token


def get_access_token_from_gcloud(force=False):
    global token
    if token is None or force:
        token = subprocess.check_output(
            ["/usr/bin/gcloud", "auth", "application-default", "print-access-token"],
            text=True,
        ).rstrip()
    return token


def get_mql_result(token, query, pageToken):
    q = f'{{"query":"{query}", "pageToken":"{pageToken}"}}' if pageToken else f'{{"query": "{query}"}}'

    headers = {"Content-Type": "application/json",
               "Authorization": f"Bearer {token}"}
    return requests.post(config.QUERY_URL, data=q, headers=headers).json()


def build_rows(metric, data):
    """ Build a list of JSON object rows to insert into BigQuery
        This function may fan out the input by writing 1 entry into BigQuery for every point,
        if there is more than 1 point in the timeseries
    """
    logging.debug("build_row")
    rows = []

    labelDescriptors = data["timeSeriesDescriptor"]["labelDescriptors"]

    for timeseries in data["timeSeriesData"]:
        labelValues = timeseries["labelValues"]
        pointData = timeseries["pointData"]
        details = {}
        for idx in range(len(labelDescriptors)):
            if labelDescriptors[idx]["key"] == "resource.project_id":
                details["project_id"] = labelValues[idx]["stringValue"]
            else:
                details[labelDescriptors[idx]["key"]] = labelValues[idx]["stringValue"]
        row = { "timeSeriesDescriptor": (details)}
        if "hpa" not in metric:
            interval = {
                    "start_time": pointData[0]["timeInterval"]["startTime"],
                    "end_time": pointData[0]["timeInterval"]["endTime"]
                }
            point = {
                    "timeInterval": interval,
                    "values": pointData[0]["values"][0],
            }
            row["pointData"] = point
        row["metricName"] = metric
        rows.append(row)
    return rows

def create_row_data(row):
    m = Parse(json.dumps(row), metric_record_pb2.MetricRecord()) 
    return m.SerializeToString()

def append_rows_proto(rows):
    """Create a write stream, write some sample data, and commit the stream."""
    write_client = bigquery_storage_v1.BigQueryWriteClient()
    parent = write_client.table_path(config.PROJECT_ID, config.BIGQUERY_DATASET, config.BIGQUERY_TABLE)
    write_stream = types.WriteStream()

    # When creating the stream, choose the type. Use the PENDING type to wait
    # until the stream is committed before it is visible. See:
    # https://cloud.google.com/bigquery/docs/reference/storage/rpc/google.cloud.bigquery.storage.v1#google.cloud.bigquery.storage.v1.WriteStream.Type
    write_stream.type_ = types.WriteStream.Type.PENDING
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
    metric_record_pb2.MetricRecord.DESCRIPTOR.CopyToProto(proto_descriptor)
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
        proto_rows.serialized_rows.append(create_row_data(row))
    
    request = types.AppendRowsRequest()
    request.offset = 0
    proto_data = types.AppendRowsRequest.ProtoData()
    proto_data.rows = proto_rows
    request.proto_rows = proto_data

    response_future_1 = append_rows_stream.send(request)

    print(response_future_1)

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

def save_to_bq(token):
    for metric, query in config.MQL_QUERY.items():
        pageToken = ""
        while (True):
            result = get_mql_result(token, query, pageToken)
            if result.get("timeSeriesDescriptor"):
                row = build_rows(metric, result)
                print(f"processing metric {metric} with {len(row)} rows")
                append_rows_proto(row)
            pageToken = result.get("nextPageToken")
            if not pageToken:
                print("No more data retrieved")
                break
    create_recommenation_table()
                
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
    
    token = get_access_token_from_meta_data()
    save_to_bq(token)
def purge_raw_metric_data():
    client = bigquery.Client()
        
    metric_table_id = f'{config.PROJECT_ID}.{config.BIGQUERY_DATASET}.{config.BIGQUERY_TABLE}'
    purge_raw_metric_query_job=client.query(
        f"""DELETE {metric_table_id} WHERE TRUE
        """
    )
    purge_raw_metric_query_job.result()
    print("Raw metric data pruged from  {}".format(metric_table_id))
    
def create_recommenation_table():
    """ Create recommenations table in BigQuery
    """
    client = bigquery.Client()
    
    table_id = f'{config.PROJECT_ID}.{config.BIGQUERY_DATASET}.{config.RECOMMENDATION_TABLE}'
    
    with open('./recommendation.sql','r') as file:
        sql = file.read()
    print("Query results loaded to the table {}".format(table_id))
    
    # Start the query, passing in the recommendation query.
    query_job = client.query(sql)  # Make an API request.
    query_job.result()  # Wait for the job to complete.
    

if __name__ == "__main__":
    purge_raw_metric_data()
    token = get_access_token_from_gcloud()
    save_to_bq(token)
    
    
  