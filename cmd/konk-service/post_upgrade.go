package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// runPostUpgrade detects and deletes deployments with ghost containers or stale
// orphaned names left over from Helm strategic merge issues during upgrades.
//
// Ghost containers: When a container is renamed in a Helm chart (e.g., "kind" → "kubeconfig"),
// Kubernetes strategic merge patch adds the new container without removing the old one.
// The only fix is to delete the deployment so the operator recreates it cleanly.
//
// Stale orphans: When deployment names are truncated in a chart update, the old longer-named
// deployments remain unmanaged. They use old name patterns that don't match current chart output.
//
// Environment variables:
//   NAMESPACE        - namespace to scan
//   RELEASE_NAME     - Helm release name (used for label selector)
//   FULLNAME_PREFIX  - expected deployment name prefix from current chart (e.g., "release-konk-service")
//   GHOST_CONTAINERS - comma-separated list of old container names to detect (default: "kind")
func runPostUpgrade() error {
	namespace := os.Getenv("NAMESPACE")
	if namespace == "" {
		return fmt.Errorf("NAMESPACE environment variable is required")
	}
	releaseName := os.Getenv("RELEASE_NAME")
	if releaseName == "" {
		return fmt.Errorf("RELEASE_NAME environment variable is required")
	}
	fullnamePrefix := os.Getenv("FULLNAME_PREFIX")
	if fullnamePrefix == "" {
		return fmt.Errorf("FULLNAME_PREFIX environment variable is required")
	}

	ghostNames := []string{"kind"}
	if env := os.Getenv("GHOST_CONTAINERS"); env != "" {
		ghostNames = strings.Split(env, ",")
	}

	cs, closeFn, err := newInClusterClient()
	if err != nil {
		return fmt.Errorf("creating client: %w", err)
	}
	defer closeFn()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	deleted, err := cleanupGhostDeployments(ctx, cs, namespace, releaseName, ghostNames)
	if err != nil {
		return err
	}

	stale, err := cleanupStaleDeployments(ctx, cs, namespace, releaseName, fullnamePrefix)
	if err != nil {
		return err
	}

	log.Printf("Post-upgrade cleanup complete: %d ghost deployments deleted, %d stale deployments deleted", deleted, stale)
	return nil
}

// cleanupGhostDeployments finds deployments managed by this release that have
// containers with old names (ghost containers from strategic merge) and deletes them.
func cleanupGhostDeployments(ctx context.Context, cs *kubernetes.Clientset, namespace, releaseName string, ghostNames []string) (int, error) {
	selector := fmt.Sprintf("app.kubernetes.io/name=konk-service,app.kubernetes.io/instance=%s", releaseName)
	deployments, err := cs.AppsV1().Deployments(namespace).List(ctx, metav1.ListOptions{
		LabelSelector: selector,
	})
	if err != nil {
		return 0, fmt.Errorf("listing deployments: %w", err)
	}

	ghostSet := make(map[string]bool, len(ghostNames))
	for _, name := range ghostNames {
		ghostSet[strings.TrimSpace(name)] = true
	}

	deleted := 0
	for i := range deployments.Items {
		deploy := &deployments.Items[i]
		if hasGhostContainer(deploy, ghostSet) {
			log.Printf("Deleting ghost deployment %s/%s (has old container name)", namespace, deploy.Name)
			if err := deleteDeployment(ctx, cs, namespace, deploy.Name); err != nil {
				log.Printf("WARNING: failed to delete %s/%s: %v", namespace, deploy.Name, err)
				continue
			}
			deleted++
		}
	}
	return deleted, nil
}

// cleanupStaleDeployments finds deployments that match konk-service labels but
// have names that don't match the current chart's naming pattern. These are
// orphans from previous chart versions that used different name truncation.
//
// The current chart generates names like: <fullnamePrefix>-kubeconfig,
// <fullnamePrefix>-kubectl-apiservice, etc. Any deployment with the right
// instance label but a name NOT starting with fullnamePrefix is stale.
func cleanupStaleDeployments(ctx context.Context, cs *kubernetes.Clientset, namespace, releaseName, fullnamePrefix string) (int, error) {
	// List all konk-service deployments for this release
	selector := fmt.Sprintf("app.kubernetes.io/name=konk-service,app.kubernetes.io/instance=%s", releaseName)
	deployments, err := cs.AppsV1().Deployments(namespace).List(ctx, metav1.ListOptions{
		LabelSelector: selector,
	})
	if err != nil {
		return 0, fmt.Errorf("listing deployments for stale check: %w", err)
	}

	// The expected prefix for all current deployment names
	expectedPrefix := fullnamePrefix + "-"

	deleted := 0
	for i := range deployments.Items {
		deploy := &deployments.Items[i]
		// A stale deployment is one whose name doesn't start with the current
		// chart's fullname prefix. This catches deployments from all previous
		// naming schemes (different truncation lengths, missing suffixes, etc.)
		if !strings.HasPrefix(deploy.Name, expectedPrefix) {
			log.Printf("Deleting stale deployment %s/%s (name doesn't match current prefix %q)", namespace, deploy.Name, expectedPrefix)
			if err := deleteDeployment(ctx, cs, namespace, deploy.Name); err != nil {
				log.Printf("WARNING: failed to delete %s/%s: %v", namespace, deploy.Name, err)
				continue
			}
			deleted++
		}
	}
	return deleted, nil
}

func hasGhostContainer(deploy *appsv1.Deployment, ghostNames map[string]bool) bool {
	for _, c := range deploy.Spec.Template.Spec.Containers {
		if ghostNames[c.Name] {
			return true
		}
	}
	for _, c := range deploy.Spec.Template.Spec.InitContainers {
		if ghostNames[c.Name] {
			return true
		}
	}
	return false
}

func deleteDeployment(ctx context.Context, cs *kubernetes.Clientset, namespace, name string) error {
	propagation := metav1.DeletePropagationForeground
	return cs.AppsV1().Deployments(namespace).Delete(ctx, name, metav1.DeleteOptions{
		PropagationPolicy: &propagation,
	})
}
