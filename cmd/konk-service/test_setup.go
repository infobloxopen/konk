package main

import (
	"context"
	"fmt"
	"log"
	"strings"
	"time"

	authv1 "k8s.io/api/authorization/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
)

// runTestSetup replaces konk-service/templates/tests/test-setup.yaml shell script.
// It verifies RBAC permissions and waits for custom resources to be available.
//
// Required env vars:
//   KUBECONFIG  - path to konk kubeconfig
//   GROUP       - the API group name (e.g. example.infoblox.com)
//   KINDS       - comma-separated list of resource kinds to wait for
//   VERSION     - the API version (e.g. v1alpha1)
func runTestSetup() error {
	kubeconfigPath := mustEnv("KUBECONFIG")
	group := mustEnv("GROUP")
	kindsStr := mustEnv("KINDS")
	version := mustEnv("VERSION")

	kinds := strings.Split(kindsStr, ",")
	for i := range kinds {
		kinds[i] = strings.TrimSpace(kinds[i])
	}

	ctx := context.Background()

	konkClient, dynClient, cleanup, err := newKubeconfigClient(kubeconfigPath)
	if err != nil {
		return fmt.Errorf("creating konk client: %w", err)
	}
	defer cleanup()

	// Check RBAC: can-i create apiservice
	log.Println("Checking RBAC: can create apiservice...")
	canCreate, err := konkClient.AuthorizationV1().SelfSubjectAccessReviews().Create(ctx,
		&authv1.SelfSubjectAccessReview{
			Spec: authv1.SelfSubjectAccessReviewSpec{
				ResourceAttributes: &authv1.ResourceAttributes{
					Verb:     "create",
					Group:    "apiregistration.k8s.io",
					Resource: "apiservices",
				},
			},
		}, metav1.CreateOptions{})
	if err != nil {
		return fmt.Errorf("checking apiservice RBAC: %w", err)
	}
	if !canCreate.Status.Allowed {
		return fmt.Errorf("not allowed to create apiservices")
	}
	log.Println("RBAC OK: can create apiservice")

	// Check RBAC: can-i create crd
	log.Println("Checking RBAC: can create crd...")
	canCreateCRD, err := konkClient.AuthorizationV1().SelfSubjectAccessReviews().Create(ctx,
		&authv1.SelfSubjectAccessReview{
			Spec: authv1.SelfSubjectAccessReviewSpec{
				ResourceAttributes: &authv1.ResourceAttributes{
					Verb:     "create",
					Group:    "apiextensions.k8s.io",
					Resource: "customresourcedefinitions",
				},
			},
		}, metav1.CreateOptions{})
	if err != nil {
		return fmt.Errorf("checking CRD RBAC: %w", err)
	}
	if !canCreateCRD.Status.Allowed {
		return fmt.Errorf("not allowed to create CRDs")
	}
	log.Println("RBAC OK: can create crd")

	// Wait for each kind to be available
	for _, kind := range kinds {
		if kind == "*" {
			log.Println("Wildcard kind specified, skipping resource wait")
			continue
		}
		log.Printf("Waiting for resource %s.%s to be available...", kind, group)
		if err := waitForResource(ctx, dynClient, group, version, kind); err != nil {
			return fmt.Errorf("waiting for %s.%s: %w", kind, group, err)
		}
		log.Printf("Resource %s.%s is available", kind, group)
	}

	log.Println("All setup tests passed!")
	return nil
}

func waitForResource(ctx context.Context, dynClient dynamic.Interface, group, version, kind string) error {
	gvr := schema.GroupVersionResource{
		Group:    group,
		Version:  version,
		Resource: strings.ToLower(kind) + "s",
	}

	for {
		_, err := dynClient.Resource(gvr).List(ctx, metav1.ListOptions{Limit: 1})
		if err == nil {
			return nil
		}
		log.Printf("Resource %s not ready: %v, retrying...", kind, err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
}
