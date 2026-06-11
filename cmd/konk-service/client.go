package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/yaml"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"

	"strings"
)

// closeFunc releases HTTP transport resources (idle connections, HTTP/2 goroutines).
// Must be called after each reconciliation iteration to prevent memory accumulation
// from long-lived HTTP/2 transports (known Go net/http2 issue).
type closeFunc func()

// newInClusterClient creates a kubernetes clientset using in-cluster config.
// Returns a closeFunc that must be called after use to release HTTP/2 transport resources.
func newInClusterClient() (*kubernetes.Clientset, closeFunc, error) {
	rc, err := rest.InClusterConfig()
	if err != nil {
		return nil, nil, fmt.Errorf("in-cluster config: %w", err)
	}
	httpClient, err := rest.HTTPClientFor(rc)
	if err != nil {
		return nil, nil, fmt.Errorf("creating http client: %w", err)
	}
	cs, err := kubernetes.NewForConfigAndClient(rc, httpClient)
	if err != nil {
		return nil, nil, fmt.Errorf("creating clientset: %w", err)
	}
	return cs, func() { httpClient.CloseIdleConnections() }, nil
}

// newKubeconfigClient creates kubernetes and dynamic clients from a kubeconfig file.
// Returns a closeFunc that must be called after use to release HTTP/2 transport resources.
func newKubeconfigClient(kubeconfigPath string) (*kubernetes.Clientset, dynamic.Interface, closeFunc, error) {
	cfg, err := clientcmd.BuildConfigFromFlags("", kubeconfigPath)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("loading kubeconfig %s: %w", kubeconfigPath, err)
	}
	httpClient, err := rest.HTTPClientFor(cfg)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("creating http client: %w", err)
	}
	cs, err := kubernetes.NewForConfigAndClient(cfg, httpClient)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("creating clientset: %w", err)
	}
	dyn, err := dynamic.NewForConfigAndClient(cfg, httpClient)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("creating dynamic client: %w", err)
	}
	return cs, dyn, func() { httpClient.CloseIdleConnections() }, nil
}

// newDynamicInClusterClient creates a dynamic client using in-cluster config.
// Returns a closeFunc that must be called after use to release HTTP/2 transport resources.
func newDynamicInClusterClient() (dynamic.Interface, closeFunc, error) {
	rc, err := rest.InClusterConfig()
	if err != nil {
		return nil, nil, fmt.Errorf("in-cluster config: %w", err)
	}
	httpClient, err := rest.HTTPClientFor(rc)
	if err != nil {
		return nil, nil, fmt.Errorf("creating http client: %w", err)
	}
	dyn, err := dynamic.NewForConfigAndClient(rc, httpClient)
	if err != nil {
		return nil, nil, fmt.Errorf("creating dynamic client: %w", err)
	}
	return dyn, func() { httpClient.CloseIdleConnections() }, nil
}

// applyUnstructured applies a single unstructured object using server-side apply.
func applyUnstructured(ctx context.Context, dyn dynamic.Interface, obj *unstructured.Unstructured) error {
	gvk := obj.GroupVersionKind()
	gvr := gvkToGVR(gvk)

	ns := obj.GetNamespace()
	name := obj.GetName()

	var resource dynamic.ResourceInterface
	if ns != "" {
		resource = dyn.Resource(gvr).Namespace(ns)
	} else {
		resource = dyn.Resource(gvr)
	}

	obj.SetManagedFields(nil)
	_, err := resource.Apply(ctx, name, obj, metav1.ApplyOptions{
		FieldManager: "konk-service",
		Force:        true,
	})
	if err != nil {
		return fmt.Errorf("applying %s %s/%s: %w", gvk.Kind, ns, name, err)
	}
	log.Printf("Applied %s %s/%s", gvk.Kind, ns, name)
	return nil
}

// deleteUnstructured deletes a single unstructured object, ignoring not-found.
func deleteUnstructured(ctx context.Context, dyn dynamic.Interface, obj *unstructured.Unstructured) error {
	gvk := obj.GroupVersionKind()
	gvr := gvkToGVR(gvk)

	ns := obj.GetNamespace()
	name := obj.GetName()

	var resource dynamic.ResourceInterface
	if ns != "" {
		resource = dyn.Resource(gvr).Namespace(ns)
	} else {
		resource = dyn.Resource(gvr)
	}

	err := resource.Delete(ctx, name, metav1.DeleteOptions{})
	if k8serrors.IsNotFound(err) {
		log.Printf("Already deleted %s %s/%s", gvk.Kind, ns, name)
		return nil
	}
	if err != nil {
		return fmt.Errorf("deleting %s %s/%s: %w", gvk.Kind, ns, name, err)
	}
	log.Printf("Deleted %s %s/%s", gvk.Kind, ns, name)
	return nil
}

// gvkToGVR converts a GroupVersionKind to a GroupVersionResource using simple pluralization.
func gvkToGVR(gvk schema.GroupVersionKind) schema.GroupVersionResource {
	// Simple pluralization: lowercase kind + "s"
	// Handles the common cases in this codebase.
	plural := strings.ToLower(gvk.Kind) + "s"
	switch strings.ToLower(gvk.Kind) {
	case "namespace":
		plural = "namespaces"
	case "service":
		plural = "services"
	case "apiservice":
		plural = "apiservices"
	case "clusterrole":
		plural = "clusterroles"
	case "customresourcedefinition":
		plural = "customresourcedefinitions"
	}
	return schema.GroupVersionResource{
		Group:    gvk.Group,
		Version:  gvk.Version,
		Resource: plural,
	}
}

// parseMultiDocYAML parses a multi-document YAML string into unstructured objects.
func parseMultiDocYAML(data string) ([]*unstructured.Unstructured, error) {
	var objects []*unstructured.Unstructured
	decoder := yaml.NewYAMLOrJSONDecoder(strings.NewReader(data), 4096)
	for {
		obj := &unstructured.Unstructured{}
		err := decoder.Decode(obj)
		if err != nil {
			if err.Error() == "EOF" {
				break
			}
			// Skip empty documents
			if len(obj.Object) == 0 {
				continue
			}
			return nil, fmt.Errorf("decoding YAML: %w", err)
		}
		if len(obj.Object) > 0 {
			objects = append(objects, obj)
		}
	}
	return objects, nil
}

// writeHealthFile writes a status value to a health file for readiness probes.
func writeHealthFile(path string, status int) error {
	return os.WriteFile(path, []byte(fmt.Sprintf("%d", status)), 0644)
}

// retryWithBackoff retries a function with exponential backoff.
func retryWithBackoff(ctx context.Context, maxDelay time.Duration, fn func() error) error {
	delay := 2 * time.Second
	for {
		err := fn()
		if err == nil {
			return nil
		}
		log.Printf("Retrying after error: %v (delay %s)", err, delay)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
		delay *= 2
		if delay > maxDelay {
			delay = maxDelay
		}
	}
}
