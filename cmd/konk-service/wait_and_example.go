package main

import (
	"context"
	"log"
	"os"
	"strings"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// runWaitForResource waits until a given resource type is listable on the cluster.
// Used as an init container to block until CRDs are registered.
//
// Required env vars:
//   KUBECONFIG  - path to kubeconfig
//   RESOURCE    - the resource name (plural, e.g. "contacts")
//   GROUP       - (optional) the API group
//   VERSION     - (optional) the API version, defaults to v1alpha1
func runWaitForResource() error {
	kubeconfigPath := mustEnv("KUBECONFIG")
	resource := mustEnv("RESOURCE")
	group := getEnvDefault("GROUP", "")
	version := getEnvDefault("VERSION", "v1alpha1")

	gvr := schema.GroupVersionResource{
		Group:    group,
		Version:  version,
		Resource: resource,
	}

	ctx := context.Background()

	log.Printf("Waiting for resource %s.%s/%s to be available...", resource, group, version)
	for {
		_, dyn, close, err := newKubeconfigClient(kubeconfigPath)
		if err == nil {
			_, err = dyn.Resource(gvr).List(ctx, metav1.ListOptions{Limit: 1})
			close()
			if err == nil {
				log.Printf("Resource %s is available", resource)
				return nil
			}
		}
		log.Printf("Not ready: %v, retrying...", err)
		time.Sleep(1 * time.Second)
	}
}

// runExampleTest performs a smoke test by waiting for cluster-info,
// then creating, getting, and deleting a sample custom resource.
//
// Required env vars:
//   KUBECONFIG    - path to kubeconfig
//   GROUP         - the API group (e.g. example.infoblox.com)
//   VERSION       - the API version (e.g. v1alpha1)
//   KIND          - the resource kind (e.g. Contact)
//   RESOURCE      - the plural resource name (e.g. contacts)
//   SAMPLE_NAME   - the name for the sample object
//   NAMESPACE     - (optional) namespace, defaults to "default"
//   SAMPLE_JSON   - (optional) JSON body for the sample spec
func runExampleTest() error {
	kubeconfigPath := mustEnv("KUBECONFIG")
	group := mustEnv("GROUP")
	version := mustEnv("VERSION")
	resource := mustEnv("RESOURCE")
	kind := mustEnv("KIND")
	sampleName := mustEnv("SAMPLE_NAME")
	namespace := getEnvDefault("NAMESPACE", "default")

	ctx := context.Background()

	// Wait for cluster-info
	log.Println("Waiting for cluster to be reachable...")
	if err := waitForClusterInfo(ctx, kubeconfigPath); err != nil {
		return err
	}

	// Wait for resource type
	gvr := schema.GroupVersionResource{
		Group:    group,
		Version:  version,
		Resource: resource,
	}
	log.Printf("Waiting for resource %s to be available...", resource)
	for {
		_, dyn, close, err := newKubeconfigClient(kubeconfigPath)
		if err == nil {
			_, err = dyn.Resource(gvr).Namespace(namespace).List(ctx, metav1.ListOptions{Limit: 1})
			close()
			if err == nil {
				break
			}
		}
		log.Printf("Not ready: %v, retrying...", err)
		time.Sleep(1 * time.Second)
	}

	// Create sample resource
	_, dyn, close, err := newKubeconfigClient(kubeconfigPath)
	if err != nil {
		return err
	}
	defer close()

	sampleObj := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": group + "/" + version,
			"kind":       kind,
			"metadata": map[string]interface{}{
				"name": sampleName,
			},
			"spec": map[string]interface{}{},
		},
	}

	log.Printf("Creating %s/%s...", strings.ToLower(kind), sampleName)
	_, err = dyn.Resource(gvr).Namespace(namespace).Create(ctx, sampleObj, metav1.CreateOptions{})
	if err != nil {
		return err
	}

	// Get sample resource
	log.Printf("Getting %s/%s...", strings.ToLower(kind), sampleName)
	got, err := dyn.Resource(gvr).Namespace(namespace).Get(ctx, sampleName, metav1.GetOptions{})
	if err != nil {
		return err
	}
	log.Printf("Got %s/%s (uid=%s)", strings.ToLower(kind), sampleName, got.GetUID())

	// Delete sample resource
	log.Printf("Deleting %s/%s...", strings.ToLower(kind), sampleName)
	err = dyn.Resource(gvr).Namespace(namespace).Delete(ctx, sampleName, metav1.DeleteOptions{})
	if err != nil {
		return err
	}

	log.Println("Example test passed!")
	return nil
}

func getEnvDefault(key, defaultVal string) string {
	val := os.Getenv(key)
	if val == "" {
		return defaultVal
	}
	return val
}
