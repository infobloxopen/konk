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

// newInClusterClient creates a kubernetes clientset using in-cluster config.
func newInClusterClient() (*kubernetes.Clientset, error) {
	rc, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("in-cluster config: %w", err)
	}
	cs, err := kubernetes.NewForConfig(rc)
	if err != nil {
		return nil, fmt.Errorf("creating clientset: %w", err)
	}
	return cs, nil
}

// newKubeconfigClient creates kubernetes and dynamic clients from a kubeconfig file.
func newKubeconfigClient(kubeconfigPath string) (*kubernetes.Clientset, dynamic.Interface, error) {
	cfg, err := clientcmd.BuildConfigFromFlags("", kubeconfigPath)
	if err != nil {
		return nil, nil, fmt.Errorf("loading kubeconfig %s: %w", kubeconfigPath, err)
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, nil, fmt.Errorf("creating clientset: %w", err)
	}
	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return nil, nil, fmt.Errorf("creating dynamic client: %w", err)
	}
	return cs, dyn, nil
}

// newDynamicInClusterClient creates a dynamic client using in-cluster config.
func newDynamicInClusterClient() (dynamic.Interface, error) {
	rc, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("in-cluster config: %w", err)
	}
	dyn, err := dynamic.NewForConfig(rc)
	if err != nil {
		return nil, fmt.Errorf("creating dynamic client: %w", err)
	}
	return dyn, nil
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
