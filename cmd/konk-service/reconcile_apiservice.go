package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"k8s.io/client-go/tools/clientcmd"
)

// runReconcileAPIService replaces apiservice-deployment.yaml + deploy-api-service.sh.
// It reads a CA cert, templates the APIService manifests, and applies them
// to the konk cluster. Runs in a loop every 30s.
//
// Required env vars:
//
//	SERVICENAME  - the service name to register
//	NAMESPACE    - the namespace
//	KUBECONFIG   - path to konk kubeconfig
//	CERT_DIR     - path to CA cert directory (ca.crt)
//	CRDS         - if set to "install", also apply CRDs
//	MANIFESTS    - multi-document YAML template with {{ SERVICENAME }}, {{ NAMESPACE }}, {{ CERT }} placeholders
//	CRD_MANIFESTS - (optional) CRD YAML to apply when CRDS=install
func runReconcileAPIService() error {
	serviceName := mustEnv("SERVICENAME")
	namespace := mustEnv("NAMESPACE")
	kubeconfigPath := mustEnv("KUBECONFIG")
	certDir := mustEnv("CERT_DIR")
	manifests := mustEnv("MANIFESTS")
	crds := os.Getenv("CRDS")
	crdManifests := os.Getenv("CRD_MANIFESTS")

	ctx := context.Background()

	const maxConsecutiveErrors = 10
	consecutiveErrors := 0

	for {
		err := reconcileAPIServiceOnce(ctx, kubeconfigPath, certDir, serviceName, namespace, manifests, crds, crdManifests)
		if err != nil {
			consecutiveErrors++
			log.Printf("Error reconciling APIService (%d/%d consecutive): %v",
				consecutiveErrors, maxConsecutiveErrors, err)
			if consecutiveErrors >= maxConsecutiveErrors {
				// Remove health file so readiness probe fails immediately
				os.Remove("/tmp/healthy")
				log.Fatalf("FATAL: %d consecutive reconciliation failures — exiting so pod restarts with fresh certs. Last error: %v",
					maxConsecutiveErrors, err)
			}
		} else {
			if consecutiveErrors > 0 {
				log.Printf("Reconciliation recovered after %d consecutive errors", consecutiveErrors)
			}
			consecutiveErrors = 0
			if err := writeHealthFile("/tmp/healthy", 0); err != nil {
				log.Printf("Warning: failed to write health file: %v", err)
			}
		}
		log.Printf("Sleeping 30s...")
		time.Sleep(30 * time.Second)
	}
}

func reconcileAPIServiceOnce(ctx context.Context, kubeconfigPath, certDir, serviceName, namespace, manifests, crds, crdManifests string) error {
	// Read and base64-encode the CA cert
	caCertRaw, err := os.ReadFile(certDir + "/ca.crt")
	if err != nil {
		return fmt.Errorf("reading ca.crt: %w", err)
	}
	certB64 := base64.StdEncoding.EncodeToString(caCertRaw)

	// Read the kubeconfig to check client cert expiry
	kubeconfigData, err := os.ReadFile(kubeconfigPath)
	if err != nil {
		return fmt.Errorf("reading kubeconfig for cert check: %w", err)
	}
	kubeconfig, err := clientcmd.Load(kubeconfigData)
	if err != nil {
		log.Printf("WARNING: could not parse kubeconfig for cert check: %v", err)
	} else {
		for _, authInfo := range kubeconfig.AuthInfos {
			if len(authInfo.ClientCertificateData) > 0 {
				if err := checkCertExpiry("apiservice client", authInfo.ClientCertificateData); err != nil {
					log.Printf("CRITICAL: kubeconfig client cert is expired — requests to konk will fail with x509 errors")
				}
				break
			}
		}
	}

	// Template the manifests
	// The Helm backtick-escaped placeholders (e.g. {{` {{ SERVICENAME }} `}})
	// produce literals with surrounding spaces: " {{ SERVICENAME }} ".
	// We replace both the spaced and unspaced variants so that fields like
	// externalName: {{ SERVICENAME }}.{{ NAMESPACE }}  resolve correctly
	// (without stray spaces around the dot).
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

	// Parse and apply
	_, dyn, err := newKubeconfigClient(kubeconfigPath)
	if err != nil {
		return fmt.Errorf("creating konk client: %w", err)
	}

	objects, err := parseMultiDocYAML(rendered)
	if err != nil {
		return fmt.Errorf("parsing manifests: %w", err)
	}

	err = retryWithBackoff(ctx, 60*time.Second, func() error {
		for _, obj := range objects {
			if err := applyUnstructured(ctx, dyn, obj); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("applying manifests: %w", err)
	}

	// Optionally apply CRDs
	if crds == "install" && crdManifests != "" {
		crdObjects, err := parseMultiDocYAML(crdManifests)
		if err != nil {
			return fmt.Errorf("parsing CRD manifests: %w", err)
		}
		for _, obj := range crdObjects {
			if err := applyUnstructured(ctx, dyn, obj); err != nil {
				return fmt.Errorf("applying CRD: %w", err)
			}
		}
	}

	log.Println("APIService reconciliation complete")
	return nil
}
