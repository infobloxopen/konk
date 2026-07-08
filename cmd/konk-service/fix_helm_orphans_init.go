package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
)

// runFixHelmOrphansInit discovers Konk and Etcd CRs and fixes orphaned resources
// for each. Designed to run as an init container on the operator deployment —
// before the operator starts reconciling — using the operator's SA (full RBAC).
//
// This bypasses the Helm hook limitation where pre-install hooks can't run
// when resource conflicts exist (Helm validates before running hooks on fresh install).
func runFixHelmOrphansInit() error {
	rc, err := rest.InClusterConfig()
	if err != nil {
		return fmt.Errorf("in-cluster config: %w", err)
	}
	dynClient, err := dynamic.NewForConfig(rc)
	if err != nil {
		return fmt.Errorf("creating dynamic client: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	totalPatched := 0

	// Scan Konk CRs — these create SA, Service, Secret, Deployment, Certs, Issuers, ClusterRoles
	konkGVR := schema.GroupVersionResource{Group: "konk.infoblox.com", Version: "v1alpha1", Resource: "konks"}
	konks, err := dynClient.Resource(konkGVR).Namespace("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Warning: cannot list Konk CRs: %v", err)
	} else {
		for _, cr := range konks.Items {
			ns := cr.GetNamespace()
			name := cr.GetName()
			log.Printf("Checking Konk CR %s/%s for orphaned resources...", ns, name)
			patched, err := fixOrphansForRelease(ctx, dynClient, ns, name, true)
			if err != nil {
				log.Printf("Warning: error fixing orphans for Konk %s/%s: %v", ns, name, err)
				continue
			}
			totalPatched += patched
		}
	}

	// Scan Etcd CRs — these create SA, StatefulSet, Service, Certs
	etcdGVR := schema.GroupVersionResource{Group: "konk.infoblox.com", Version: "v1alpha1", Resource: "etcds"}
	etcds, err := dynClient.Resource(etcdGVR).Namespace("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Warning: cannot list Etcd CRs: %v", err)
	} else {
		for _, cr := range etcds.Items {
			ns := cr.GetNamespace()
			name := cr.GetName()
			log.Printf("Checking Etcd CR %s/%s for orphaned resources...", ns, name)
			patched, err := fixOrphansForRelease(ctx, dynClient, ns, name, false)
			if err != nil {
				log.Printf("Warning: error fixing orphans for Etcd %s/%s: %v", ns, name, err)
				continue
			}
			totalPatched += patched
		}
	}

	if totalPatched == 0 {
		log.Printf("No orphaned resources found across all CRs — nothing to fix")
	} else {
		log.Printf("Fixed %d total orphaned resource(s) across all CRs", totalPatched)
	}
	return nil
}

// fixOrphansForRelease scans namespaced (and optionally cluster-scoped) resources
// for a given release, patching any that have Helm labels but missing annotations.
func fixOrphansForRelease(ctx context.Context, dynClient dynamic.Interface, namespace, releaseName string, scanClusterScoped bool) (int, error) {
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
			log.Printf("  Warning: error checking %s in %s: %v", gvr.Resource, namespace, err)
			continue
		}
		totalPatched += patched
	}

	if scanClusterScoped {
		clusterResources := []schema.GroupVersionResource{
			{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "clusterroles"},
			{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "clusterrolebindings"},
			{Group: "cert-manager.io", Version: "v1", Resource: "clusterissuers"},
		}
		for _, gvr := range clusterResources {
			patched, err := fixOrphansClusterScoped(ctx, dynClient, gvr, namespace, releaseName)
			if err != nil {
				log.Printf("  Warning: error checking cluster-scoped %s: %v", gvr.Resource, err)
				continue
			}
			totalPatched += patched
		}
	}

	if totalPatched > 0 {
		log.Printf("  Patched %d orphaned resource(s) for release %s/%s", totalPatched, namespace, releaseName)
	}
	return totalPatched, nil
}

// skipInitOrphanFix checks if the init container should skip (e.g., on clusters
// where Konk CRDs aren't installed yet).
func skipInitOrphanFix() bool {
	return os.Getenv("SKIP_ORPHAN_FIX") == "true"
}
