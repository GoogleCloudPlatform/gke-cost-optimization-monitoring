
echo "Setup starting, enable services necessary to run the pipeline. Please wait..."

gcloud services enable \
cloudfunctions.googleapis.com \
cloudbuild.googleapis.com \
cloudscheduler.googleapis.com

envsubst < recommendation-template.sql> recommendation.sql
envsubst < config-template.py > config.py

bq mk $BIGQUERY_DATASET
bq mk --table ${BIGQUERY_DATASET}.${BIGQUERY_MQL_TABLE}  bigquery_schema.json
bq mk --table ${BIGQUERY_DATASET}.${BIGQUERY_VPA_RECOMMENDATION_TABLE} bigquery_recommendation_schema.json

echo "Creating a service account for the export Cloud Function"
gcloud iam service-accounts create mql-export-metrics \
--display-name "MQL export metrics SA" \
--description "Used for the function that export monitoring metrics"

echo "Assigning IAM roles to the service account..."
gcloud projects add-iam-policy-binding  $PROJECT_ID --member="serviceAccount:$EXPORT_METRIC_SERVICE_ACCOUNT" --role="roles/monitoring.viewer"
gcloud projects add-iam-policy-binding  $PROJECT_ID --member="serviceAccount:$EXPORT_METRIC_SERVICE_ACCOUNT" --role="roles/bigquery.dataEditor"
gcloud projects add-iam-policy-binding  $PROJECT_ID --member="serviceAccount:$EXPORT_METRIC_SERVICE_ACCOUNT" --role="roles/bigquery.dataOwner"
gcloud projects add-iam-policy-binding  $PROJECT_ID --member="serviceAccount:$EXPORT_METRIC_SERVICE_ACCOUNT" --role="roles/bigquery.jobUser"

echo "Creating the Pub/Sub topic..."
gcloud pubsub topics create $PUBSUB_TOPIC

echo "Deploy the Cloud Function.."

gcloud functions deploy mql-export-metric \
--region $REGION \
--trigger-topic $PUBSUB_TOPIC \
--runtime python39 \
--entry-point export_metric_data \
--set-env-vars PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python \
--service-account=$EXPORT_METRIC_SERVICE_ACCOUNT

echo "Deploy the Cloud Scheduler job with a schedule to trigger the Cloud Function once a day.."
gcloud scheduler jobs create pubsub get_metric_mql \
--schedule "* 23 * * *" \
--topic $PUBSUB_TOPIC \
--location $REGION \
--message-body "Exporting metric..."

echo "Deployment complete"
