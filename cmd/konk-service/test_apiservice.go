package main

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// runTestAPIService replaces apiservice-test-deployment.yaml.
// It polls the konk cluster to check that the APIService exists and
// the expected API group has resources, writing health status to /tmp/healthy.
//
// Required env vars:
//   KUBECONFIG  - path to konk kubeconfig
//   VERSION     - the API version (e.g. v1alpha1)
//   GROUP       - the API group name (e.g. example.infoblox.com)
func runTestAPIService() error {
	kubeconfigPath := mustEnv("KUBECONFIG")
	version := mustEnv("VERSION")
	group := mustEnv("GROUP")

	apiServiceName := version + "." + group

	for {
		status := testAPIServiceOnce(kubeconfigPath, apiServiceName, group)
		if err := writeHealthFile("/tmp/healthy", status); err != nil {
			log.Printf("Warning: failed to write health file: %v", err)
		}

		// 30s + up to 5s jitter (matching original shell)
		jitter := time.Duration(rand.Intn(5)) * time.Second
		time.Sleep(30*time.Second + jitter)
	}
}

func testAPIServiceOnce(kubeconfigPath, apiServiceName, group string) int {
	ctx := context.Background()

	konkClient, _, close1, err := newKubeconfigClient(kubeconfigPath)
	if err != nil {
		log.Printf("Error creating konk client: %v", err)
		return 1
	}
	defer close1()

	// Check APIService exists
	apiregGVR := schema.GroupVersionResource{
		Group:    "apiregistration.k8s.io",
		Version:  "v1",
		Resource: "apiservices",
	}
	_, dynClient, close2, err := newKubeconfigClient(kubeconfigPath)
	if err != nil {
		log.Printf("Error creating dynamic client: %v", err)
		return 1
	}
	defer close2()
	_, err = dynClient.Resource(apiregGVR).Get(ctx, apiServiceName, metav1.GetOptions{})
	if err != nil {
		log.Printf("APIService %s not found: %v", apiServiceName, err)
		return 1
	}
	log.Printf("APIService %s exists", apiServiceName)

	// List API resources for the group
	resourceList, err := konkClient.Discovery().ServerResourcesForGroupVersion(fmt.Sprintf("%s/%s", group, extractVersion(apiServiceName)))
	if err != nil {
		log.Printf("Error listing resources for group %s: %v", group, err)
		return 1
	}
	log.Printf("API resources for group %s:", group)
	for _, r := range resourceList.APIResources {
		log.Printf("  %s", r.Name)
	}

	return 0
}

func extractVersion(apiServiceName string) string {
	// APIService name format: v1alpha1.example.infoblox.com
	// Extract the version part before the first dot
	for i, c := range apiServiceName {
		if c == '.' {
			return apiServiceName[:i]
		}
	}
	return apiServiceName
}
