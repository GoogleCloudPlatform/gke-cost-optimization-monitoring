// Copyright 2021 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package mon

import (
	"fmt"
	"metrics-exporter/apis/k8s"
	"strconv"
	"strings"

	gce "cloud.google.com/go/compute/metadata"
	log "github.com/sirupsen/logrus"
	"google.golang.org/api/monitoring/v3"
)

const (
	hpaCPUMetricType    = "custom.googleapis.com/podautoscaler/hpa/cpu/target_utilization"
	hpaMemoryMetricType = "custom.googleapis.com/podautoscaler/hpa/memory/target_utilization"
)

// BuildHPATargetUtilizationTimeSeries buid Timeseries objects for HPA target CPU
func BuildHPATargetUtilizationTimeSeries(hpas []k8s.HPA, now string) []*monitoring.TimeSeries {
	var hpaMap map[string]k8s.HPA = make(map[string]k8s.HPA)
	tsList := []*monitoring.TimeSeries{}
	for _, hpa := range hpas {
		if hpa.TargetCPUPercentage > 0 || hpa.TargetMemoryPercentage > 0 {
			if hpa.TargetCPUPercentage > 0 {
				targetKey := fmt.Sprintf("%s|%s|%s|cpu", hpa.TargetRef.Kind, hpa.Namespace, hpa.TargetRef.Name)
				if _, found := hpaMap[targetKey]; !found {
					hpaMap[targetKey] = hpa
					tsList = append(tsList, buildHPACPUTargetUtilization(hpa, now))
				} else {
					// Skip HPA object once we alreay had one in the list with the same target object
					log.Infof("Skipping HPA cpu '%s.%s' once '%s.%s' was already loaded",
						hpa.Namespace, hpa.Name, hpaMap[targetKey].Namespace, hpaMap[targetKey].Name)
				}
			}
			if hpa.TargetMemoryPercentage > 0 {
				targetKey := fmt.Sprintf("%s|%s|%s|memory", hpa.TargetRef.Kind, hpa.Namespace, hpa.TargetRef.Name)
				if _, found := hpaMap[targetKey]; !found {
					hpaMap[targetKey] = hpa
					tsList = append(tsList, buildHPAMemoryTargetUtilization(hpa, now))
				} else {
					// Skip HPA object once we alreay had one in the list with the same target object
					log.Infof("Skipping HPA memory '%s.%s' once '%s.%s' was already loaded",
						hpa.Namespace, hpa.Name, hpaMap[targetKey].Namespace, hpaMap[targetKey].Name)
				}
			}
		} else {
			log.Infof("Skipping HPA '%s.%s' once it doesn't configure either Target CPU or Target Memory", hpa.Namespace, hpa.Name)
		}
	}
	return tsList
}

func buildHPACPUTargetUtilization(hpa k8s.HPA, now string) *monitoring.TimeSeries {
	metric := hpaCPUMetricType
	value := int64(hpa.TargetCPUPercentage)
	return buildHPATargetUtilization(metric, value, hpa, now)
}

func buildHPAMemoryTargetUtilization(hpa k8s.HPA, now string) *monitoring.TimeSeries {
	metric := hpaMemoryMetricType
	value := int64(hpa.TargetMemoryPercentage)
	return buildHPATargetUtilization(metric, value, hpa, now)
}

func buildHPATargetUtilization(metric string, value int64, hpa k8s.HPA, now string) *monitoring.TimeSeries {
	return &monitoring.TimeSeries{
		Resource: &monitoring.MonitoredResource{
			Type:   "k8s_pod",
			Labels: buildHPAResourceLabels(hpa),
		},
		Metric: &monitoring.Metric{
			Type: metric,
			Labels: map[string]string{
				"targetef_apiversion": hpa.TargetRef.APIVersion,
				"targetref_kind":      hpa.TargetRef.Kind,
				"targetref_name":      hpa.TargetRef.Name,
				"minReplicas":         strconv.Itoa(int(hpa.MinReplicas)),
				"maxReplicas":         strconv.Itoa(int(hpa.MaxReplicas)),
				"object_name":         hpa.Name,
			},
		},
		Points: []*monitoring.Point{{
			Interval: &monitoring.TimeInterval{
				EndTime: now,
			},
			Value: &monitoring.TypedValue{
				Int64Value: &value,
			},
		}},
	}
}

func buildHPAResourceLabels(hpa k8s.HPA) map[string]string {
	projectID, _ := gce.ProjectID()
	location, _ := gce.InstanceAttributeValue("cluster-location")
	location = strings.TrimSpace(location)
	clusterName, _ := gce.InstanceAttributeValue("cluster-name")
	clusterName = strings.TrimSpace(clusterName)
	return map[string]string{
		"project_id":     projectID,
		"location":       location,
		"cluster_name":   clusterName,
		"namespace_name": hpa.Namespace,
		"pod_name":       hpa.TargetRef.Name,
	}
}
