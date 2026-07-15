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
// Stale orphans: When deployment names change across chart versions (truncation, renames),
// old deployments remain live but aren't managed by the current Helm release.
//
// Environment variables:
//   NAMESPACE         - namespace to scan
//   RELEASE_NAME      - Helm release name (used for label selector)
//   VALID_DEPLOYMENTS - comma-separated list of exact deployment names the current chart creates
//   GHOST_CONTAINERS  - comma-separated list of old container names to detect (default: "kind")
func runPostUpgrade() error {
	namespace := os.Getenv("NAMESPACE")
	if namespace == "" {
		return fmt.Errorf("NAMESPACE environment variable is required")
	}
	releaseName := os.Getenv("RELEASE_NAME")
	if releaseName == "" {
		return fmt.Errorf("RELEASE_NAME environment variable is required")
	}
	validDeploymentsEnv := os.Getenv("VALID_DEPLOYMENTS")
	if validDeploymentsEnv == "" {
		return fmt.Errorf("VALID_DEPLOYMENTS environment variable is required")
	}

	validSet := make(map[string]bool)
	for _, name := range strings.Split(validDeploymentsEnv, ",") {
		name = strings.TrimSpace(name)
		if name != "" {
			validSet[name] = true
		}
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

	ghostDeleted, err := cleanupGhostDeployments(ctx, cs, namespace, releaseName, ghostNames)
	if err != nil {
		return err
	}

	staleDeleted, err := cleanupStaleDeployments(ctx, cs, namespace, releaseName, validSet)
	if err != nil {
		return err
	}

	log.Printf("Post-upgrade cleanup complete: %d ghost deployments deleted, %d stale deployments deleted", ghostDeleted, staleDeleted)
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
// whose names are NOT in the set of valid deployment names the current chart creates.
// These are orphans from previous chart versions that used different naming/truncation.
func cleanupStaleDeployments(ctx context.Context, cs *kubernetes.Clientset, namespace, releaseName string, validNames map[string]bool) (int, error) {
	// List all konk-service deployments for this release
	selector := fmt.Sprintf("app.kubernetes.io/name=konk-service,app.kubernetes.io/instance=%s", releaseName)
	deployments, err := cs.AppsV1().Deployments(namespace).List(ctx, metav1.ListOptions{
		LabelSelector: selector,
	})
	if err != nil {
		return 0, fmt.Errorf("listing deployments for stale check: %w", err)
	}

	deleted := 0
	for i := range deployments.Items {
		deploy := &deployments.Items[i]
		if !validNames[deploy.Name] {
			log.Printf("Deleting stale deployment %s/%s (not in valid set: %v)", namespace, deploy.Name, validNames)
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
