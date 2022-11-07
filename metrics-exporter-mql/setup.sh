
echo "Setup starting, enable services please wait..."
gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    monitoring.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com


echo "Configuring region and zone"

gcloud config set compute/region $REGION
gcloud config set compute/zone $ZONE

echo "Creating a gke cluster"
gcloud container clusters create ${CLUSTER_NAME} \
    --project=${PROJECT_ID} --zone=${ZONE} \
    --machine-type=e2-standard-2 --num-nodes=5 \
    --workload-pool=${PROJECT_ID}.svc.id.goog

sleep 7 &
PID=$!
i=1
sp="/-\|"
echo -n ' '
while [ -d /proc/$PID ]
do
  printf "\b${sp:i++%${#sp}:1}"
done

echo "Get credentials for your cluster"
gcloud container clusters get-credentials ${CLUSTER_NAME}

echo "Create a new IAM service account"
gcloud iam service-accounts create ${SERVICE_ACCOUNT} \
    --project=${PROJECT_ID}

echo "Granting roles..."
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/monitoring.metricWriter"

gcloud projects add-iam-policy-binding  $PROJECT_ID \
    --member="serviceAccount:${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/compute.viewer"

gcloud iam service-accounts add-iam-policy-binding ${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT_ID}.svc.id.goog[custom-metrics/metrics-exporter-sa]"


echo "deploy the onlineshop"
kubectl apply -f kubernetes/online-shop.yaml
#kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/master/release/kubernetes-manifests.yaml

echo "To simulate a more realistic environment, create an HPA for Online Boutique deployments"
kubectl get deployments --field-selector='metadata.name==adservice' -o go-template-file=../k8s/templates/cpu-hpa.gtpl | kubectl apply -f -
kubectl get deployments --field-selector='metadata.name==redis-cart' -o go-template-file=../k8s/templates/memory-hpa.gtpl | kubectl apply -f -
kubectl get hpa

kubectl create ns custom-metrics





echo "SETUP COMPLETE"