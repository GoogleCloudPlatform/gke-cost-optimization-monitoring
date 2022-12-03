# Right-sizing your GKE workloads at scale using GKE built-in Vertical Pod Autoscaler recommendations 

This guide is for developers and operators who wish to right-size their GKE applications to make them cost-effective while retaining good performance and reliability. The lesson assumes you are already familiar with Linux, [Docker](https://www.docker.com/), [Kubernetes](https://kubernetes.io/), [GKE](https://cloud.google.com/kubernetes-engine), [Cloud Monitoring](https://cloud.google.com/monitoring/docs).


## Overview

Google Cloud provides out-of-the-box [Vertical Pod Autoscaler (VPA)](https://cloud.google.com/kubernetes-engine/docs/concepts/verticalpodautoscaler) recommendations intelligence in [Cloud Monitoring](https://cloud.google.com/monitoring) and the [Cost Optimization tab](https://cloud.google.com/kubernetes-engine/docs/how-to/cost-optimization-metrics) in the GKE console without the need to deploy any VPA objects for all [Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) workloads. 

This tutorial goal is to teach you how to pull VPA recommendations at scale from multiple projects and GKE Clusters. In the current GKE UI, you can only see one workload recommendation at a time, and the VPA recommendations in Cloud Monitoring require MQL or PromQL knowledge. This tutorial exports VPA recommendations from Cloud Monitoring into [BigQuery](https://cloud.google.com/bigquery).. In BigQuery, standard SQL queries are used to build a VPA container recommendation table to view and analyze:



* Top over-provisioned GKE workloads between all your projects
* Top under-provisioned GKE workloads between all your projects
* GKE workloads at reliability or performance risk


## Understanding why resource rightsizing is important

![Alt text](/metrics-exporter-mql/images/1.png?raw=true)


Improper resource provisioning causes issues if not done properly. Under-provisioning can starve your containers of the necessary resources to run your application, making them slow and unreliable. Over-provisioning won’t impact the performance of your application but will increase your monthly bills.

The table below describes the implications of under-provisioning and over-provisioning CPU and memory from the perspective of the workload functioning as expected.


<table>
  <tr>
   <td><strong>Resource</strong>
   </td>
   <td><strong>Provisioning status</strong>
   </td>
   <td><strong>Risk</strong>
   </td>
   <td><strong>Explanation</strong>
   </td>
  </tr>
  <tr>
   <td rowspan="3" ><strong>CPU</strong>
   </td>
   <td>over
   </td>
   <td>cost
   </td>
   <td>Increases the cost of your workloads by reserving unnecessary resources.
   </td>
  </tr>
  <tr>
   <td>under
   </td>
   <td>performance
   </td>
   <td>Can cause workloads to slow down or become unresponsive. 
   </td>
  </tr>
  <tr>
   <td>not set 
   </td>
   <td>reliability
   </td>
   <td>CPU can be throttled to 0 causing your workloads to become unresponsive. 
   </td>
  </tr>
  <tr>
   <td rowspan="3" ><strong>Memory</strong>
   </td>
   <td>over
   </td>
   <td>cost
   </td>
   <td>Increases the cost of your workloads by reserving unnecessary resources.
   </td>
  </tr>
  <tr>
   <td>under
   </td>
   <td>reliability
   </td>
   <td>Can cause applications to terminate with an out of memory (OOM) error.
   </td>
  </tr>
  <tr>
   <td>not set
   </td>
   <td>reliability
   </td>
   <td><code>kubelet</code> can kill your Pods, at any time, and mark it as failed.
   </td>
  </tr>
</table>



## Objectives 



* Deploy a sample application.
* Export GKE recommendations metrics from Cloud Monitoring to BigQuery.
* Use BigQuery and Looker Studio to view GKE container recommendations across projects.


## Costs

This tutorial uses billable components of Google Cloud, including:



* [Cloud Monitoring](https://cloud.google.com/monitoring/pricing)
* [Google Kubernetes Engine](https://cloud.google.com/kubernetes-engine/pricing)
* [BigQuery](https://cloud.google.com/bigquery/pricing)
* [Cloud Functions](https://cloud.google.com/functions/pricing)
* [Cloud Build](https://cloud.google.com/build/pricing)

Use the [Pricing Calculator](https://cloud.google.com/products/calculator) to generate a cost estimate based on your projected usage. 


## Before you begin



1. Create a Google Cloud project

    [GO TO THE MANAGE RESOURCES PAGE](https://console.cloud.google.com/cloud-resource-manager)

2. Enable billing for your project.

    [ENABLE BILLING](https://support.google.com/cloud/answer/6293499#enable-billing)

3. In Cloud Console, open [Cloud Shell](https://cloud.google.com/shell/docs/how-cloud-shell-works) to execute the commands listed in this tutorial.

    At the bottom of the Cloud Console, a [Cloud Shell](https://cloud.google.com/shell/docs/how-cloud-shell-works) session opens and displays a command-line prompt. Cloud Shell is a shell environment with the Cloud SDK already installed, including the [gcloud command-line tool](https://cloud.google.com/sdk/gcloud), and with values already set for your current project. It can take a few seconds for the session to initialize.


When you finish this tutorial, you can avoid continued billing by deleting the resources you created. See 


[Cleaning up](#heading=h.3cd5qfyytayd) for more detail.


## Preparing your environment

To simulate a realistic environment, you will deploy a sample application to illustrate the lesson you will learn in this tutorial. You will use a setup script to deploy [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo). The Online Boutique sample app is composed of 11 microservices diagrammed below. 


    Note: If you are running this in your own environment you can skip this section once the goal of this section is to simulate a real environment with many different workloads setup



![Alt text](/metrics-exporter-mql/images/2.png?raw=true)


The steps below install the boutique sample application and tweak a few configurations to simulate a more realistic scenario. For example, it adds [horizontal Pod autoscaler](https://cloud.google.com/kubernetes-engine/docs/concepts/horizontalpodautoscaler) (HPA)  for some workloads and changes resource requests and limits.



4. Set the current project as the development environment

    ```
    export PROJECT_ID=[PROJECT_ID]
    export REGION=us-central1
    export ZONE=us-central1-f
    export CLUSTER_NAME=online-boutique
    export SERVICE_ACCOUNT=svc-metric-exporter
    export PUBSUB_TOPIC=mql_metric_export
    export BIGQUERY_DATASET=metric_export
    export BIGQUERY_MQL_TABLE=mql_metrics

    export BIGQUERY_VPA_RECOMMENDATION_TABLE=vpa_container_recommendations
    export EXPORT_METRIC_SERVICE_ACCOUNT=mql-export-metrics@$PROJECT_ID.iam.gserviceaccount.com
    ```


	Replace [PROJECT_ID] with your project ID



5. Set the project id:

    ```
    gcloud config set project $PROJECT_ID
    ```


6. Clone the repository:

    ```
    git clone https://github.com/aburhan/gke-cost-optimization-monitoring && cd gke-cost-optimization-monitoring/metrics-exporter-mql
    ```


7. Run the setup script:


```
      ./setup.sh
```



    The setup script will:



* Create a GKE cluster
* Deploy the Online Boutique app
* Update pod CPU and memory resources 
* Configure a HorizontalPodAutoscaler on the adservice and redis-cart workloads to simulate a realistic environment.

setup.sh will deploy the sample application and takes ~8-10 minutes to complete.



8. Verify online boutique deployments are `READY`

    ```
    kubectl get deployment

    ```


The output similar to the following:


```
    NAME                    READY   UP-TO-DATE   AVAILABLE   AGE
    adservice               2/2     2            2           4m54s
    cartservice             1/1     1            1           4m55s
    checkoutservice         1/1     1            1           4m56s
    currencyservice         1/1     1            1           4m55s
    emailservice            1/1     1            1           4m56s
    frontend                1/1     1            1           4m55s
    loadgenerator           1/1     1            1           4m55s
    paymentservice          1/1     1            1           4m55s
    productcatalogservice   1/1     1            1           4m55s
    recommendationservice   1/1     1            1           4m56s
    redis-cart              1/1     1            1           4m54s
    shippingservice         1/1     1            1           4m54s
```
9. Change working directory

    ```
    cd ../
    ```


## Deploy cron job to export HorizontalPodAutoscaler metrics to Cloud Monitoring

HPA scales the number of pods, while VPA scales by increasing or decreasing CPU and memory resources within the existing pod container. VPA and HPA scale based on the same resource metrics, such as CPU and MEMORY usage. When a scaling event happens, both VPA and HPA will attempt to scale resources which may have unforeseen side effects. To avoid such a thing, the solution proposed in this tutorial doesn't provide VPA recommendations for HPA-enabled workloads. The steps described in this session are required to later filter out all HP- enabled workloads.


    Note: if you understand how VPA and HPA work, and you also would like to see recommendations for HPA-enabled workloads, you can skip this session

Deploy a cron job to export metrics to Cloud Monitoring to identify workloads with HPA configured. 



1. Run the following command to create a new Docker repository 

    ```
    gcloud artifacts repositories create metric-exporter-repo --repository-format=docker \
    --location=$REGION --description="Docker repository"
    ```
2. Configure access to the repository
    ```
     gcloud auth configure-docker $REGION-docker.pkg.dev
    ```

3. Submit the Cloud Build job to deploy the metric exporter to create custom HPA metrics in Cloud Monitoring

    ```
    gcloud builds submit --region=${REGION} --tag ${REGION}-docker.pkg.dev/${PROJECT_ID}/metric-exporter-repo/metric-exporter:latest
    ```


4. Update metric exporter yaml

    ```
    sed "s/PROJECT_ID/$PROJECT_ID/g" ./k8s/templates/hpa-metrics-exporter.yaml > ./k8s/metrics-exporter.yaml
    kubectl apply -f k8s/metrics-exporter.yaml
    ```



    This job is responsible for querying HPA objects in your cluster and sending custom metrics based on data to Cloud Monitoring. This implementation exports HPA resource target utilization—CPU and memory defined in percentage form.


    **Important: **If you are running this tutorial in your own cluster and it has workload identity enabled, make sure you follow the steps in [Using Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) to export metrics to Cloud Monitoring.

5. Verify the cron job ran and completed successfully

    ```
    kubectl describe -n custom-metrics cronjob metrics-exporter 
    ```



    It may take a couple of minutes to complete. Wait until the status is complete before moving forward or run the job by clicking RUN NOW on the [Cron Job details](https://console.cloud.google.com/kubernetes/cronjob/us-central1-f/online-boutique/custom-metrics/metrics-exporter/details) page.


The output similar to the following:


    …


```
    Events:
      Type     Reason            Age              From                Message
      ----     ------            ----             ----                -------
     …
      Normal   SawCompletedJob   72s              cronjob-controller  Saw completed job: metrics-exporter-27772443, status: Complete
```



### Verify the custom metrics export is sending HPA metrics to Cloud Monitor



1. In the Google Cloud console, go to the **Monitoring** page. \
[Go to Metric explorer](https://console.cloud.google.com/monitoring/metrics-explorer)
2. Enter “hpa” in the select metrics field. You should see two custom metrics as the image below


### 

![Alt text](/metrics-exporter-mql/images/3.png?raw=true)



## View the container recommendation in GKE UI

GKE provides out-of-the-box VPA container recommendations in the Workloads UI under the COST Optimization tab for each project as shown above. To view project specific recommendation:



1. In the Google Cloud console, go to the COST OPTIMIZATION tab on **GKE Workloads **page. \
[Go to Workloads Cost Optimization](https://console.cloud.google.com/kubernetes/workload/cost)

![Alt text](/metrics-exporter-mql/images/4.png?raw=true)

2. Select any workload listed
3. Select ACTIONS > Scale > Edit resource request 

![Alt text](/metrics-exporter-mql/images/5.png?raw=true)



    The Scale compute resources page provides the latest recommendations based on usage patterns. Take note of the gray information box before applying the latest changes. The values provided are for the current point and time and may not reflect your workload’s needs.


![Alt text](/metrics-exporter-mql/images/6.png?raw=true)


As you can see in the information box above, VPA recommendation provides a recommendation at a point in time, which means it can provide different recommendations depending on the day/hour you view it. This is important to note, for workloads with constant load and may spike throughout the month. Setting resources too low can cause reliability or performance issues, while resources set too high increase cost. 

Instead of using the point-in-time value, this tutorial teaches you how to export VPA metrics over the last 30 days. This will account for workloads burstable throughout the month to be accounted for in the VPA recommendation.


## Exporting metrics from Cloud Monitoring to BigQuery

Now all required metrics from Cloud Monitoring, you deploy a pipeline to export 30 days of VPA recommendations and GKE resources metrics within the last hours to BigQuery. The pipeline will use opinionated SQL queries to build a VPA container recommendation table to view and analyze the top under-provisioned and over-provisioned workloads and workloads with reliability risk. The pipeline runs once a day at the 23rd hour.

	Note: you can customize the opinionated SQL queries in file . 


![Alt text](/metrics-exporter-mql/images/7.png?raw=true)



* Create a [Cloud Scheduler](https://cloud.google.com/scheduler/docs/?utm_source=ext&utm_medium=partner&utm_campaign=CDR_pve_gcp_4words_4words_&utm_content=-) job to run once a day (`cron schedule ('* 23 * * *')`) and publish an event to [Pub/Sub](https://cloud.google.com/pubsub). 
* Deploy [Cloud Function](https://cloud.google.com/functions) to query Cloud Monitoring then write the results to BigQuery. The Cloud Function is triggered by events published to Pub/Sub by Cloud Scheduler.
* Create a BigQuery table `mql_metrics` to temporarily store 30 days of VPA recommendations and the last hour of GKE resource metrics from Cloud monitoring used to create container recommendations. 
* Create a BigQuery table `vpa_container_recommendations` and store VPA container recommendations aggregated over a 30 day window period.
1. Create a BigQuery table to store the VPA container recommendations

    ```
    cd metrics-exporter-mql
    envsubst < recommendation-template.sql> recommendation.sql
    bq mk ${BIGQUERY_DATASET}
    bq mk --table ${BIGQUERY_DATASET}.${BIGQUERY_VPA_RECOMMENDATION_TABLE} bigquery_recommendation_schema.json
    ```


2. Run the deploy_pipeline script 

    ```
    ./deploy_pipeline.sh
    ```


3. View the Cloud Function logs [Go to Cloud Functions console](https://console.cloud.google.com/functions/details/us-central1/mql-export-metric)

Note: If you don’t see logs in the Cloud Function console. Run the schedule using `gcloud scheduler jobs run get_metric_mql --location $REGION.  `



4. Select the LOGS tab on the mql-export-metric details page
5. Verify metrics logs are being processed

The output similar to the following:


```
    mql-export-metriceg5fe9df8l8r processing metric cpu_request_cores with 12 rows

```



6. In the console, verify the GKE metric data is written to BigQuery by running the following query:

    ```
    bq query \
    --use_legacy_sql=false \
    "SELECT DISTINCT metric_name FROM ${PROJECT_ID}.${BIGQUERY_DATASET}.${BIGQUERY_MQL_TABLE} ORDER BY metric_name"

    ```


The output similar to the following. Depending on the number of workloads this may take a few minutes to write all metrics to BigQuery, if output differs from what is below wait then re-run the command:


```
    +---------------------------------------------+
    |                 metric_name                 |
    +---------------------------------------------+
    | count                                       |
    | cpu_limit_cores                             |
    | cpu_request_95th_percentile_recommendations |
    | cpu_request_max_recommendations             |
    | cpu_requested_cores                         |
    | hpa_cpu                                     |
    | hpa_memory                                  |
    | memory_limit_bytes                          |
    | memory_request_recommendations              |
    | memory_requested_bytes                      |
    +---------------------------------------------+
```



## Query GKE Container Recommendations

This section will review the opinionated logic used to create the SQL queries which generated the `vpa_container_recommendations` table with recommendations for the last 30 days. 


### Filtering out HPA workloads

The recommendations are VPA recommendations exclusively. Cloud Monitoring is unaware of workloads with HPA-enabled and provides VPA recommendations. To omit workloads with HPA-enabled, the following query uses the custom metric deployed earlier to select any metric with "hpa" in the metric name.


Next, use the left join operation to filter out all of the HPA-enabled workloads from the recommendation table. 


### CPU requested and limit container recommendation

If the workload's CPU requested and limit values are equal, the QoS is considered Guaranteed, and the CPU recommendation is set to the maximum within the window period of 30 days. Otherwise, the 95th percentile of the VPA CPU requested recommendation within 30 days will be used.

When the CPU request and limit values are equal, the recommendation for CPU limit is set to the maximum CPU VPA recommendation. If the request and limit of the workload are not identical, the existing limit ratio is used.




### Memory requested and limit container recommendation

Memory recommendations use the maximum VPA recommendation to ensure the workload's reliability. It is [best practice to use the same amount of memory for requests and limits ](https://cloud.google.com/architecture/best-practices-for-running-cost-effective-kubernetes-applications-on-gke#set_appropriate_resource_requests_and_limits)because memory is an incompressible resource. When memory is exhausted, the Pod needs to be taken down. To avoid having Pods taken down—and consequently, destabilizing your environment—you must set the requested memory to the memory limit.


### Prioritizing recommendations

A priority value is assigned to each row to surface workloads which require immediate attention based on the VPA recommendations. The units of CPU and memory are different. To normalize the units, the [E2 machine type on-demand price](https://cloud.google.com/compute/all-pricing) ratio between predefined CPU and memory is used as an approximation to convert memory units to CPU units.

Example:



    priority = (CPU requested - CPU recommendation) + ((memory requested - memory recommendation) / (vCPUs on-demand pricing /memory on-demand pricing ))



## View the container recommendation in BigQuery



1. In the Google Cloud console, go to the [BigQuery SQL Workspace](https://console.cloud.google.com/bigquery)
2. In the query editor,  select all rows in the recommendation table:

    ```
    SELECT * FROM `[PROJECT_ID].metric_export.vpa_container_recommendations` where latest = TRUE
    ```



    Replace [PROJECT_ID] with your project ID.


The recommendation_date is the date the function created the recommendation. All workloads may not be visible on the recommendation table after the first run. For production environments, allow 24 hours for non-HPA workloads to appear in the VPA recommendation table. 


## Visualize recommendations in Looker Studio

Looker Studio is a free, self-service business intelligence platform that lets users build and consume data visualizations, dashboards, and reports. With Looker Studio, you can connect to your data, create visualizations, and share your insights with others.

Next you use Looker Studio to visualize data in the BigQuery vpa_container_recommendation table.


![Alt text](/metrics-exporter-mql/images/8.png?raw=true)



1. Open the [VPA container recommendations dashboard template](https://datastudio.google.com/c/u/0/reporting/b99a3b05-06da-44e1-946e-70f37ce5d5a1/page/tEnnC/preview)
2. Click “Use my own data”

    



3. Select your project
4. Select metric_export as the Dataset
5. Select vpa_container_recommendations as the Table

    Example: 


![Alt text](/metrics-exporter-mql/images/9.png?raw=true)



### VPA container recommendations detailed view

The Details page allows you to see additional information not included on the overview page. This section will go over the major sections of this view.


![Alt text](/metrics-exporter-mql/images/10.png?raw=true)

Project details such as location, project ID, cluster name, controller name, controller type and count are shown in the first few columns of the table. These metrics are standard GKE metrics from Cloud Monitoring based on your workloads.

![Alt text](/metrics-exporter-mql/images/11.png?raw=true)


The section below shows the CPU cores requested and the current CPU cores limit for each workload. QoS is calculated based on the current CPU requested and limit values, and the logic used to calculate this value is detailed in the table below. The last two rows contain the CPU recommendations for CPU requests and limits based on VPA. Details on how the CPU recommendations are calculated can be found in the table below.


![Alt text](/metrics-exporter-mql/images/12.png?raw=true)



<table>
  <tr>
   <td><strong>Column</strong>
   </td>
   <td><strong>Description</strong>
   </td>
  </tr>
  <tr>
   <td>cpu requested cores
   </td>
   <td>The current workload’s requested CPU
   </td>
  </tr>
  <tr>
   <td>cpu limit cores
   </td>
   <td>The current workload’s CPU limit
   </td>
  </tr>
  <tr>
   <td>QoS CPU
   </td>
   <td>Is set based on the resource and limits set within each deployment or stateful set. However, this guide recommends using either the maximum VPA recommendation or the 95th percentile for CPU. The following list describes how the QoS CPU field is calculated:
<ul>

<li>If the requested CPU = CPU limit, the QoS CPU QoS* value is set to Guaranteed. 

<li>If the requested CPU and limits are set, and the limit is greater than the requested, the value is set to Burstable

<li>If both values are unset, the value is set to BestEffort
</li>
</ul>
   </td>
  </tr>
  <tr>
   <td>cpu request recommendation
   </td>
   <td>
<ul>

<li>If the QoS column == <code>Guaranteed</code> or <code>BestEffort</code>, the maximum VPA recommendations over the 30-day window is displayed

<li>If the QoS column == Burstable, the CPU request recommendation is the 95th percentile over the 30-day window
</li>
</ul>
   </td>
  </tr>
  <tr>
   <td>cpu limit recommendation
   </td>
   <td>
<ul>

<li>If the QoS column == <code>Guaranteed</code> or <code>BestEffort</code>, the maximum VPA recommendations over the 30-day window is displayed

<li>If the QoS column == Burstable, the CPU request recommendation is equal to the CPU recommendation multiplied by the CPU requested/CPU limit
</li>
</ul>
   </td>
  </tr>
</table>


The third group of columns represent the current memory request,  limits and the memory recommendations. Detailed information about how these values are set can be found in the table below.



![Alt text](/metrics-exporter-mql/images/13.png?raw=true)



<table>
  <tr>
   <td><strong>Column</strong>
   </td>
   <td><strong>Description</strong>
   </td>
  </tr>
  <tr>
   <td>memory requested bytes
   </td>
   <td>The current workload’s requested memory
   </td>
  </tr>
  <tr>
   <td>memory limit bytes
   </td>
   <td>The current workload’s memory limit
   </td>
  </tr>
  <tr>
   <td>QoS memory
   </td>
   <td>QoS memory is set with the same logic as the QoS CPU field mentioned above. However, unlike CPU this value does not determine the value of the memory recommendation or limit
   </td>
  </tr>
  <tr>
   <td>memory request recommendation and memory limits
   </td>
   <td>This guide recommends using either the maximum VPA recommendation for both request and limit as part of the <a href="https://cloud.google.com/architecture/best-practices-for-running-cost-effective-kubernetes-applications-on-gke#set_appropriate_resource_requests_and_limits">best practice</a> mentioned earlier
   </td>
  </tr>
</table>


The last column in the table is priority. The priority column calculates a priority rating for each workload based on the difference between what is set as the request and limit for both CPU and memory. 

The formula used to calculate priority:

 priority = (CPU requested - CPU recommendation) + ((memory requested - memory recommendation) / (Predefined vCPUs/Predefined Memory))

![Alt text](/metrics-exporter-mql/images/14.png?raw=true)


The last page of the dashboard summarizes how the effort to right-size is going. The dashboard is split into CPU and memory, respectively. The bar signifies the total value of requested resources. The line shows where the values should be based on a 30-day window. The top of the bar should aligned with the recommendation line. 

![Alt text](/metrics-exporter-mql/images/15.png?raw=true)



## Viewing VPA recommendations for multiple projects

The recommended approach to view VPA container recommendations across multiple projects is to use a new[ Cloud project as a scoping project](https://cloud.google.com/monitoring/settings#create-multi). When deploying this in your production environment, add all projects you want to analyze to the new project's metrics scope. 


## Cleaning up

To avoid incurring charges to your Google Cloud Platform account for the resources used in this tutorial:


### Delete the project

The easiest way to eliminate billing is to delete the project you created for the tutorial.


    **Caution**: Deleting a project has the following effects:



    * **Everything in the project is deleted.** If you used an existing project for this tutorial, when you delete it, you also delete any other work you've done in the project.
    * **Custom project IDs are lost.** When you created this project, you might have created a custom project ID that you want to use in the future. To preserve the URLs that use the project ID, such as an **<code>appspot.com</code></strong> URL, delete selected resources inside the project instead of deleting the whole project.

    If you plan to explore multiple tutorials and quickstarts, reusing projects can help you avoid exceeding project quota limits.

1. In the Cloud Console, go to the **Manage resources** page. \
[Go to the Manage resources page](https://console.cloud.google.com/iam-admin/projects)
2. In the project list, select the project that you want to delete and then click **Delete **
3. In the dialog, type the project ID and then click **Shut down** to delete the project.


## What's next



* Learn more about GKE cost optimization in [Best practices for running cost-optimized Kubernetes applications on GKE](https://cloud.google.com/solutions/best-practices-for-running-cost-effective-kubernetes-applications-on-gke).
* Find more tips and best practices for optimizing GKE costs in [Cost optimization on Google Cloud for developers and operators](https://cloud.google.com/solutions/cost-efficiency-on-google-cloud#gke).
* Learn more about cost-optimizing your cluster at low-demand periods in [Reducing costs by scaling down GKE clusters during off-peak hours](https://cloud.google.com/architecture/reducing-costs-by-scaling-down-gke-off-hours).
* Learn more about GKE cost optimization in [Monitoring GKE clusters for cost optimization using Cloud Monitoring](https://cloud.google.com/architecture/monitoring-gke-clusters-for-cost-optimization-using-cloud-monitoring)
* Try out other Google Cloud features for yourself. Have a look at our [tutorials](https://cloud.google.com/docs/tutorials).
