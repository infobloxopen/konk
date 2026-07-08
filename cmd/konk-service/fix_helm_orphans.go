package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
)

// runFixHelmOrphans finds resources in the namespace that have Helm managed-by
// labels but are missing the meta.helm.sh/release-name annotation. These are
// leftovers from a previously failed Helm install that prevent re-installation.
//
// The fix: patch the missing annotations so Helm can adopt the resources on
// the next install/upgrade attempt.
//
// Environment variables:
//
//	NAMESPACE    - namespace to scan
//	RELEASE_NAME - expected Helm release name to set in annotations
func runFixHelmOrphans() error {
	namespace := os.Getenv("NAMESPACE")
	if namespace == "" {
		return fmt.Errorf("NAMESPACE environment variable is required")
	}
	releaseName := os.Getenv("RELEASE_NAME")
	if releaseName == "" {
		return fmt.Errorf("RELEASE_NAME environment variable is required")
	}

	rc, err := rest.InClusterConfig()
	if err != nil {
		return fmt.Errorf("in-cluster config: %w", err)
	}
	dynClient, err := dynamic.NewForConfig(rc)
	if err != nil {
		return fmt.Errorf("creating dynamic client: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Wait for RBAC to propagate — the ClusterRole/Binding are created at hook
	// weight -10 and this Job at -5, but the API server's authorizer cache may
	// not have the new bindings yet.
	saGVR := schema.GroupVersionResource{Group: "", Version: "v1", Resource: "serviceaccounts"}
	log.Printf("Waiting for RBAC propagation (listing serviceaccounts in %s)...", namespace)
	for attempts := 0; attempts < 15; attempts++ {
		_, err = dynClient.Resource(saGVR).Namespace(namespace).List(ctx, metav1.ListOptions{Limit: 1})
		if err == nil {
			log.Printf("RBAC ready after %d attempts", attempts+1)
			break
		}
		if attempts == 14 {
			return fmt.Errorf("RBAC not ready after 15 attempts (last error: %w)", err)
		}
		time.Sleep(2 * time.Second)
	}

	// Resource types created by the konk/konk-service charts that could become orphans.
	// Covers: ServiceAccount, ConfigMap, Service, Deployment, StatefulSet, Job,
	// Role, RoleBinding, Certificate, Issuer (cert-manager), Ingress, Space, Etcd, HPA.
	resources := []schema.GroupVersionResource{
		{Group: "", Version: "v1", Resource: "serviceaccounts"},
		{Group: "", Version: "v1", Resource: "configmaps"},
		{Group: "", Version: "v1", Resource: "services"},
		{Group: "", Version: "v1", Resource: "secrets"},
		{Group: "apps", Version: "v1", Resource: "deployments"},
		{Group: "apps", Version: "v1", Resource: "statefulsets"},
		{Group: "batch", Version: "v1", Resource: "jobs"},
		{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "roles"},
		{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "rolebindings"},
		{Group: "cert-manager.io", Version: "v1", Resource: "certificates"},
		{Group: "cert-manager.io", Version: "v1", Resource: "issuers"},
		{Group: "networking.k8s.io", Version: "v1", Resource: "ingresses"},
		{Group: "spacecontroller.infoblox-cto.github.com", Version: "v1alpha1", Resource: "spaces"},
		{Group: "konk.infoblox.com", Version: "v1alpha1", Resource: "etcds"},
		{Group: "autoscaling", Version: "v2", Resource: "horizontalpodautoscalers"},
	}

	totalPatched := 0
	for _, gvr := range resources {
		patched, err := fixOrphansForResource(ctx, dynClient, gvr, namespace, releaseName)
		if err != nil {
			// Log but continue — some CRDs may not exist on all clusters
			log.Printf("Warning: error checking %s: %v", gvr.Resource, err)
			continue
		}
		totalPatched += patched
	}

	// Scan cluster-scoped resources if requested (konk chart with scope=cluster)
	if os.Getenv("SCAN_CLUSTER_SCOPED") == "true" {
		clusterResources := []schema.GroupVersionResource{
			{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "clusterroles"},
			{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "clusterrolebindings"},
			{Group: "cert-manager.io", Version: "v1", Resource: "clusterissuers"},
		}
		for _, gvr := range clusterResources {
			patched, err := fixOrphansClusterScoped(ctx, dynClient, gvr, namespace, releaseName)
			if err != nil {
				log.Printf("Warning: error checking cluster-scoped %s: %v", gvr.Resource, err)
				continue
			}
			totalPatched += patched
		}
	}

	if totalPatched == 0 {
		log.Printf("No orphaned resources found — nothing to fix")
	} else {
		log.Printf("Fixed %d orphaned resource(s) with Helm ownership annotations", totalPatched)
	}
	return nil
}

// fixOrphansForResource lists resources of a given type that have the Helm
// managed-by label but are missing the release-name annotation, and patches them.
func fixOrphansForResource(
	ctx context.Context,
	dynClient dynamic.Interface,
	gvr schema.GroupVersionResource,
	namespace, releaseName string,
) (int, error) {
	// Only look at resources with the Helm managed-by label for this release instance
	labelSelector := fmt.Sprintf("app.kubernetes.io/managed-by=Helm,app.kubernetes.io/instance=%s", releaseName)

	list, err := dynClient.Resource(gvr).Namespace(namespace).List(ctx, metav1.ListOptions{
		LabelSelector: labelSelector,
	})
	if err != nil {
		return 0, err
	}

	patched := 0
	for _, item := range list.Items {
		annotations := item.GetAnnotations()
		if annotations == nil {
			annotations = map[string]string{}
		}

		// Check if annotations are already correct
		if annotations["meta.helm.sh/release-name"] == releaseName &&
			annotations["meta.helm.sh/release-namespace"] == namespace {
			continue
		}

		// Patch the missing annotations
		log.Printf("Patching orphaned %s/%s %q — adding meta.helm.sh annotations (release=%s, namespace=%s)",
			gvr.Resource, namespace, item.GetName(), releaseName, namespace)

		patch, err := json.Marshal(map[string]interface{}{
			"metadata": map[string]interface{}{
				"annotations": map[string]string{
					"meta.helm.sh/release-name":      releaseName,
					"meta.helm.sh/release-namespace": namespace,
				},
			},
		})
		if err != nil {
			log.Printf("Error marshaling patch for %s/%s: %v", gvr.Resource, item.GetName(), err)
			continue
		}

		_, err = dynClient.Resource(gvr).Namespace(namespace).Patch(
			ctx, item.GetName(), types.MergePatchType, patch, metav1.PatchOptions{},
		)
		if err != nil {
			log.Printf("Error patching %s/%s: %v", gvr.Resource, item.GetName(), err)
			continue
		}
		patched++
	}

	return patched, nil
}

// fixOrphansClusterScoped patches cluster-scoped resources (ClusterRoles,
// ClusterRoleBindings, ClusterIssuers) that have Helm labels but are missing
// ownership annotations.
func fixOrphansClusterScoped(
	ctx context.Context,
	dynClient dynamic.Interface,
	gvr schema.GroupVersionResource,
	namespace, releaseName string,
) (int, error) {
	labelSelector := fmt.Sprintf("app.kubernetes.io/managed-by=Helm,app.kubernetes.io/instance=%s", releaseName)

	list, err := dynClient.Resource(gvr).List(ctx, metav1.ListOptions{
		LabelSelector: labelSelector,
	})
	if err != nil {
		return 0, err
	}

	patched := 0
	for _, item := range list.Items {
		annotations := item.GetAnnotations()
		if annotations == nil {
			annotations = map[string]string{}
		}

		if annotations["meta.helm.sh/release-name"] == releaseName &&
			annotations["meta.helm.sh/release-namespace"] == namespace {
			continue
		}

		log.Printf("Patching orphaned cluster-scoped %s %q — adding meta.helm.sh annotations (release=%s, namespace=%s)",
			gvr.Resource, item.GetName(), releaseName, namespace)

		patch, err := json.Marshal(map[string]interface{}{
			"metadata": map[string]interface{}{
				"annotations": map[string]string{
					"meta.helm.sh/release-name":      releaseName,
					"meta.helm.sh/release-namespace": namespace,
				},
			},
		})
		if err != nil {
			log.Printf("Error marshaling patch for %s/%s: %v", gvr.Resource, item.GetName(), err)
			continue
		}

		_, err = dynClient.Resource(gvr).Patch(
			ctx, item.GetName(), types.MergePatchType, patch, metav1.PatchOptions{},
		)
		if err != nil {
			log.Printf("Error patching cluster-scoped %s/%s: %v", gvr.Resource, item.GetName(), err)
			continue
		}
		patched++
	}

	return patched, nil
}
