echo "Setup starting, enable services"
gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    monitoring.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    cloudscheduler.googleapis.com \
    eventarc.googleapis.com \
    run.googleapis.com \
    cloudfunctions.googleapis.com

echo "Configuring region and zone"

gcloud config set compute/region $REGION
gcloud config set compute/zone $ZONE

echo "Creating a gke cluster"
gcloud container clusters create online-boutique \
    --project=${PROJECT_ID} --zone=${ZONE} \
    --machine-type=e2-standard-2 --num-nodes=4

echo "waiting for cluster"

kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/master/release/kubernetes-manifests.yaml

echo "To simulate a more realistic environment, create an HPA for Online Boutique deployments"

kubectl get deployments --field-selector='metadata.name!=recommendationservice,metadata.name!=cartservice,metadata.name!=emailservice,metadata.name!=shippingservice' -o go-template-file=k8s/templates/cpu-hpa.gtpl | kubectl apply -f -
kubectl get deployments --field-selector='metadata.name==adservice' -o go-template-file=k8s/templates/memory-hpa.gtpl | kubectl apply -f -
kubectl get hpa

echo "Building the custom metric exporter image"
docker build . -t gcr.io/$PROJECT_ID/metrics-exporter

echo "Pushing the custom metric exporter image"
sleep 30s
docker push gcr.io/$PROJECT_ID/metrics-exporter

sleep 30s
sed "s/PROJECT_ID/$PROJECT_ID/g" ./k8s/templates/hpa-metrics-exporter.yaml > ./k8s/metrics-exporter.yaml
kubectl create ns custom-metrics
kubectl apply -f k8s/metrics-exporter.yaml

echo "SETUP COMPLETE"