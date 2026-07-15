package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"
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

	// Clean up stale hook resources and pending releases left by previous
	// failed upgrades. This must run before the orphan fix so the Helm
	// reconciler starts with a clean slate on every operator restart.
	if err := cleanupStaleHooks(ctx, dynClient); err != nil {
		log.Printf("Warning: hook cleanup: %v", err)
	}

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

	// Fix stale CA in kubeconfig-cert secrets (after CA rotation / fresh install)
	if err := fixStaleCA(ctx, dynClient); err != nil {
		log.Printf("Warning: fix-stale-ca: %v", err)
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

// cleanupStaleHooks removes leftover Helm hook resources (Jobs, SAs, Roles,
// RoleBindings) and non-deployed release secrets (pending-upgrade, pending-install,
// failed) across all namespaces that contain Konk or Etcd CRs.
//
// This handles the transition from old chart templates (which had
// hook-delete-policy: hook-succeeded on RBAC resources, causing premature
// deletion) to the fixed templates. Without this cleanup, the first upgrade
// after deploying the new operator image can fail if stale hook resources or
// pending releases exist from a previous failed attempt.
func cleanupStaleHooks(ctx context.Context, dynClient dynamic.Interface) error {
	namespaces := map[string]bool{}

	konkGVR := schema.GroupVersionResource{Group: "konk.infoblox.com", Version: "v1alpha1", Resource: "konks"}
	konks, err := dynClient.Resource(konkGVR).Namespace("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Warning: cannot list Konk CRs for hook cleanup: %v", err)
	} else {
		for _, cr := range konks.Items {
			namespaces[cr.GetNamespace()] = true
		}
	}

	etcdGVR := schema.GroupVersionResource{Group: "konk.infoblox.com", Version: "v1alpha1", Resource: "etcds"}
	etcds, err := dynClient.Resource(etcdGVR).Namespace("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Warning: cannot list Etcd CRs for hook cleanup: %v", err)
	} else {
		for _, cr := range etcds.Items {
			namespaces[cr.GetNamespace()] = true
		}
	}

	if len(namespaces) == 0 {
		log.Printf("Hook cleanup: no Konk/Etcd namespaces found — skipping")
		return nil
	}

	totalDeleted := 0
	for ns := range namespaces {
		deleted, err := cleanupStaleHooksInNamespace(ctx, dynClient, ns)
		if err != nil {
			log.Printf("Warning: hook cleanup in %s: %v", ns, err)
			continue
		}
		totalDeleted += deleted
	}

	// Cluster-scoped hook resources (ClusterRoles, ClusterRoleBindings from konk chart)
	clusterGVRs := []schema.GroupVersionResource{
		{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "clusterroles"},
		{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "clusterrolebindings"},
	}
	for _, gvr := range clusterGVRs {
		deleted, err := deleteHookResources(ctx, dynClient, gvr, "")
		if err != nil {
			log.Printf("Warning: hook cleanup cluster-scoped %s: %v", gvr.Resource, err)
			continue
		}
		totalDeleted += deleted
	}

	if totalDeleted > 0 {
		log.Printf("Hook cleanup: deleted %d stale hook resource(s)", totalDeleted)
	} else {
		log.Printf("Hook cleanup: no stale hook resources found")
	}
	return nil
}

func cleanupStaleHooksInNamespace(ctx context.Context, dynClient dynamic.Interface, namespace string) (int, error) {
	totalDeleted := 0

	// Delete hook resources: Jobs, SAs, Roles, RoleBindings with helm.sh/hook annotation
	hookGVRs := []schema.GroupVersionResource{
		{Group: "batch", Version: "v1", Resource: "jobs"},
		{Group: "", Version: "v1", Resource: "serviceaccounts"},
		{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "roles"},
		{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "rolebindings"},
	}
	for _, gvr := range hookGVRs {
		deleted, err := deleteHookResources(ctx, dynClient, gvr, namespace)
		if err != nil {
			log.Printf("  Warning: listing %s in %s: %v", gvr.Resource, namespace, err)
			continue
		}
		totalDeleted += deleted
	}

	// Delete non-deployed release secrets (pending-upgrade, pending-install, failed)
	deleted, err := deleteNonDeployedReleases(ctx, dynClient, namespace)
	if err != nil {
		log.Printf("  Warning: cleaning release secrets in %s: %v", namespace, err)
	} else {
		totalDeleted += deleted
	}

	return totalDeleted, nil
}

// deleteHookResources deletes resources that have a helm.sh/hook annotation
// and belong to a konk-related release (name contains "konk" or "etcd").
// If namespace is empty, operates on cluster-scoped resources.
func deleteHookResources(ctx context.Context, dynClient dynamic.Interface, gvr schema.GroupVersionResource, namespace string) (int, error) {
	var rc dynamic.ResourceInterface
	if namespace != "" {
		rc = dynClient.Resource(gvr).Namespace(namespace)
	} else {
		rc = dynClient.Resource(gvr)
	}

	list, err := rc.List(ctx, metav1.ListOptions{})
	if err != nil {
		return 0, err
	}

	deleted := 0
	for _, item := range list.Items {
		annotations := item.GetAnnotations()
		if annotations == nil {
			continue
		}
		hookVal, isHook := annotations["helm.sh/hook"]
		if !isHook || hookVal == "" {
			continue
		}
		name := item.GetName()
		if !strings.Contains(name, "konk") && !strings.Contains(name, "etcd") {
			continue
		}

		scope := namespace
		if scope == "" {
			scope = "cluster-scoped"
		}
		log.Printf("  DELETE stale hook %s/%s %q (hook=%s)", gvr.Resource, scope, name, hookVal)

		if err := rc.Delete(ctx, name, metav1.DeleteOptions{}); err != nil {
			log.Printf("  Warning: failed to delete %s %q: %v", gvr.Resource, name, err)
			continue
		}
		deleted++
	}
	return deleted, nil
}

// deleteNonDeployedReleases removes Helm release secrets that are not in
// "deployed" or "superseded" status — these are leftovers from failed upgrades
// that block subsequent upgrade attempts.
func deleteNonDeployedReleases(ctx context.Context, dynClient dynamic.Interface, namespace string) (int, error) {
	secretGVR := schema.GroupVersionResource{Group: "", Version: "v1", Resource: "secrets"}
	list, err := dynClient.Resource(secretGVR).Namespace(namespace).List(ctx, metav1.ListOptions{
		LabelSelector: "owner=helm",
	})
	if err != nil {
		return 0, err
	}

	deleted := 0
	for _, item := range list.Items {
		labels := item.GetLabels()
		status := labels["status"]
		name := labels["name"]

		if !strings.Contains(name, "konk") && !strings.Contains(name, "etcd") {
			continue
		}

		if status == "deployed" || status == "superseded" {
			continue
		}

		log.Printf("  DELETE non-deployed release secret %s/%s (release=%s, status=%s)",
			namespace, item.GetName(), name, status)

		if err := dynClient.Resource(secretGVR).Namespace(namespace).Delete(
			ctx, item.GetName(), metav1.DeleteOptions{},
		); err != nil {
			log.Printf("  Warning: failed to delete release secret %q: %v", item.GetName(), err)
			continue
		}
		deleted++
	}
	return deleted, nil
}
