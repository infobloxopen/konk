package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"log"
	"os"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// runDeleteAPIService replaces delete-apiservice-deployment.yaml + delete-api-service.sh.
// It connects to the konk cluster and deletes the APIService, Service, and ClusterRole.
//
// Required env vars:
//
//	SERVICENAME  - the service name to delete
//	NAMESPACE    - the namespace
//	KUBECONFIG   - path to konk kubeconfig
//	CERT_DIR     - path to CA cert directory (ca.crt)
//	MANIFESTS    - multi-document YAML template with {{ SERVICENAME }}, {{ NAMESPACE }}, {{ CERT }} placeholders
func runDeleteAPIService() error {
	serviceName := mustEnv("SERVICENAME")
	namespace := mustEnv("NAMESPACE")
	kubeconfigPath := mustEnv("KUBECONFIG")
	certDir := mustEnv("CERT_DIR")
	manifests := mustEnv("MANIFESTS")

	ctx := context.Background()

	// Verify konk is reachable
	konkClient, dyn, cleanup, err := newKubeconfigClient(kubeconfigPath)
	if err != nil {
		return fmt.Errorf("creating konk client: %w", err)
	}
	defer cleanup()

	// Quick health check — list nodes (like the original script)
	_, err = konkClient.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Konk cluster not reachable, skipping delete: %v", err)
		if err := writeHealthFile("/tmp/healthy", 0); err != nil {
			log.Printf("Warning: failed to write health file: %v", err)
		}
		return nil
	}

	// Read and base64-encode the CA cert
	caCertRaw, err := os.ReadFile(certDir + "/ca.crt")
	if err != nil {
		return fmt.Errorf("reading ca.crt: %w", err)
	}
	certB64 := base64.StdEncoding.EncodeToString(caCertRaw)

	// Template the manifests (handle Helm backtick-escaped spacing)
	rendered := manifests
	for _, old := range []string{" {{ SERVICENAME }} ", "{{ SERVICENAME }}"} {
		rendered = strings.ReplaceAll(rendered, old, serviceName)
	}
	for _, old := range []string{" {{ NAMESPACE }} ", "{{ NAMESPACE }}"} {
		rendered = strings.ReplaceAll(rendered, old, namespace)
	}
	for _, old := range []string{" {{ CERT }} ", "{{ CERT }}"} {
		rendered = strings.ReplaceAll(rendered, old, certB64)
	}

	objects, err := parseMultiDocYAML(rendered)
	if err != nil {
		return fmt.Errorf("parsing manifests: %w", err)
	}

	for _, obj := range objects {
		if err := deleteUnstructured(ctx, dyn, obj); err != nil {
			log.Printf("Warning: failed to delete %s: %v", obj.GetName(), err)
		}
	}

	if err := writeHealthFile("/tmp/healthy", 0); err != nil {
		log.Printf("Warning: failed to write health file: %v", err)
	}
	log.Println("Delete APIService complete")
	return nil
}
