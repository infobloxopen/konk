package main

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"log"
	"strings"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
)

// fixStaleCA checks all KonkService kubeconfig-cert secrets and deletes any
// that have a stale ca.crt (different from the current bulk-konk CA).
// cert-manager will re-issue them with the correct CA.
// After deletion, it retries up to 5 times (with delay) to verify all secrets
// have been re-issued with the correct CA.
func fixStaleCA(ctx context.Context, dynClient dynamic.Interface) error {
	// Step 1: Read current CA fingerprint from aggregate/bulk-konk-ca
	currentCAFP, err := getCAFingerprint(ctx, dynClient, "aggregate", "bulk-konk-ca")
	if err != nil {
		return fmt.Errorf("reading bulk-konk CA: %w", err)
	}
	if currentCAFP == "" {
		log.Printf("fix-stale-ca: could not read bulk-konk CA fingerprint, skipping")
		return nil
	}
	log.Printf("fix-stale-ca: current bulk-konk CA: %s", currentCAFP[:40])

	// Step 2: Discover KonkService namespaces
	ksGVR := schema.GroupVersionResource{Group: "konk.infoblox.com", Version: "v1alpha1", Resource: "konkservices"}
	ksList, err := dynClient.Resource(ksGVR).Namespace("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("fix-stale-ca: cannot list KonkServices: %v", err)
		return nil
	}
	if len(ksList.Items) == 0 {
		log.Printf("fix-stale-ca: no KonkServices found, skipping")
		return nil
	}

	// Step 3: Find and delete stale kubeconfig-cert secrets
	secretGVR := schema.GroupVersionResource{Group: "", Version: "v1", Resource: "secrets"}
	staleSecrets := []struct{ ns, name string }{}

	for _, ks := range ksList.Items {
		ns := ks.GetNamespace()
		name := ks.GetName()

		// Convention: kubeconfig-cert secret name is <name>-konk-service-kubeconfig-cert
		secretName := name + "-konk-service-kubeconfig-cert"
		secret, err := dynClient.Resource(secretGVR).Namespace(ns).Get(ctx, secretName, metav1.GetOptions{})
		if err != nil {
			// Secret doesn't exist — cert-manager will create it
			continue
		}

		data := secret.Object["data"]
		if data == nil {
			continue
		}
		dataMap, ok := data.(map[string]interface{})
		if !ok {
			continue
		}
		caCrtB64, ok := dataMap["ca.crt"].(string)
		if !ok || caCrtB64 == "" {
			continue
		}

		fp, err := fingerprintFromBase64(caCrtB64)
		if err != nil {
			log.Printf("fix-stale-ca: error parsing ca.crt from %s/%s: %v", ns, secretName, err)
			continue
		}

		if fp != currentCAFP {
			log.Printf("fix-stale-ca: STALE %s/%s (ca: %s)", ns, secretName, fp[:40])
			staleSecrets = append(staleSecrets, struct{ ns, name string }{ns, secretName})
		}
	}

	if len(staleSecrets) == 0 {
		log.Printf("fix-stale-ca: all kubeconfig-cert secrets have correct CA — nothing to fix")
		return nil
	}

	// Step 4: Delete stale secrets
	log.Printf("fix-stale-ca: deleting %d stale kubeconfig-cert secret(s)...", len(staleSecrets))
	for _, s := range staleSecrets {
		err := dynClient.Resource(secretGVR).Namespace(s.ns).Delete(ctx, s.name, metav1.DeleteOptions{})
		if err != nil {
			log.Printf("fix-stale-ca: ERROR deleting %s/%s: %v", s.ns, s.name, err)
		} else {
			log.Printf("fix-stale-ca: DELETED %s/%s", s.ns, s.name)
		}
	}

	// Step 5: Retry loop — wait for cert-manager to re-issue with correct CA
	log.Printf("fix-stale-ca: waiting for cert-manager to re-issue certificates...")
	for attempt := 1; attempt <= 5; attempt++ {
		time.Sleep(10 * time.Second)

		remaining := 0
		for _, s := range staleSecrets {
			secret, err := dynClient.Resource(secretGVR).Namespace(s.ns).Get(ctx, s.name, metav1.GetOptions{})
			if err != nil {
				// Not yet re-created
				remaining++
				continue
			}
			data := secret.Object["data"]
			if data == nil {
				remaining++
				continue
			}
			dataMap, ok := data.(map[string]interface{})
			if !ok {
				remaining++
				continue
			}
			caCrtB64, ok := dataMap["ca.crt"].(string)
			if !ok || caCrtB64 == "" {
				remaining++
				continue
			}
			fp, err := fingerprintFromBase64(caCrtB64)
			if err != nil || fp != currentCAFP {
				remaining++
				continue
			}
		}

		if remaining == 0 {
			log.Printf("fix-stale-ca: all %d kubeconfig-cert secrets re-issued with correct CA (attempt %d/5)", len(staleSecrets), attempt)
			rolloutRestartStaleDeployments(ctx, dynClient, staleSecrets)
			return nil
		}
		log.Printf("fix-stale-ca: attempt %d/5: %d/%d still pending...", attempt, remaining, len(staleSecrets))
	}

	log.Printf("fix-stale-ca: WARNING: some secrets may not have been re-issued yet (cert-manager may need more time)")
	// Still proceed with rollout restart for pods that had stale CA
	rolloutRestartStaleDeployments(ctx, dynClient, staleSecrets)
	return nil
}

// rolloutRestartStaleDeployments restarts konk-service deployments that mount
// kubeconfig secrets which had a stale CA. These pods cache TLS config in memory
// and won't pick up the updated secret without a restart.
func rolloutRestartStaleDeployments(ctx context.Context, dynClient dynamic.Interface, staleSecrets []struct{ ns, name string }) {
	deployGVR := schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "deployments"}

	// For each stale secret (e.g. "foo-konk-service-kubeconfig-cert"),
	// the affected deployment is:
	//   <ks-name>-konk-service-apiservice (reconcile-apiservice — caches kubeconfig TLS in memory)
	// The base is the secret name minus "-kubeconfig-cert" suffix.
	suffixes := []string{"-apiservice"}
	restarted := 0

	for _, s := range staleSecrets {
		// secret name: <ks-name>-konk-service-kubeconfig-cert
		base := strings.TrimSuffix(s.name, "-kubeconfig-cert")
		if base == s.name {
			continue // unexpected naming — skip
		}

		for _, suffix := range suffixes {
			deployName := base + suffix
			deploy, err := dynClient.Resource(deployGVR).Namespace(s.ns).Get(ctx, deployName, metav1.GetOptions{})
			if err != nil {
				// Deployment doesn't exist (e.g. some KonkServices don't have kubectl-apiservice)
				continue
			}

			// Trigger rollout restart by patching pod template annotation
			spec := deploy.Object["spec"].(map[string]interface{})
			template := spec["template"].(map[string]interface{})
			metadata, ok := template["metadata"].(map[string]interface{})
			if !ok {
				metadata = map[string]interface{}{}
				template["metadata"] = metadata
			}
			annotations, ok := metadata["annotations"].(map[string]interface{})
			if !ok {
				annotations = map[string]interface{}{}
				metadata["annotations"] = annotations
			}
			annotations["konk.infoblox.com/restartedAt"] = time.Now().Format(time.RFC3339)

			_, err = dynClient.Resource(deployGVR).Namespace(s.ns).Update(ctx, deploy, metav1.UpdateOptions{})
			if err != nil {
				log.Printf("fix-stale-ca: ERROR restarting %s/%s: %v", s.ns, deployName, err)
			} else {
				log.Printf("fix-stale-ca: RESTARTED %s/%s", s.ns, deployName)
				restarted++
			}
		}
	}

	if restarted > 0 {
		log.Printf("fix-stale-ca: triggered rollout restart for %d deployment(s)", restarted)
	}
}

// getCAFingerprint reads the tls.crt from a kubernetes.io/tls secret and returns its SHA-256 fingerprint.
func getCAFingerprint(ctx context.Context, dynClient dynamic.Interface, namespace, secretName string) (string, error) {
	secretGVR := schema.GroupVersionResource{Group: "", Version: "v1", Resource: "secrets"}
	secret, err := dynClient.Resource(secretGVR).Namespace(namespace).Get(ctx, secretName, metav1.GetOptions{})
	if err != nil {
		return "", err
	}

	data := secret.Object["data"]
	if data == nil {
		return "", fmt.Errorf("secret %s/%s has no data", namespace, secretName)
	}
	dataMap, ok := data.(map[string]interface{})
	if !ok {
		return "", fmt.Errorf("secret %s/%s data is not a map", namespace, secretName)
	}
	tlsCrtB64, ok := dataMap["tls.crt"].(string)
	if !ok || tlsCrtB64 == "" {
		return "", fmt.Errorf("secret %s/%s has no tls.crt", namespace, secretName)
	}

	return fingerprintFromBase64(tlsCrtB64)
}

// fingerprintFromBase64 decodes a base64-encoded PEM cert and returns its SHA-256 fingerprint.
func fingerprintFromBase64(b64 string) (string, error) {
	certBytes, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", fmt.Errorf("base64 decode: %w", err)
	}

	block, _ := pem.Decode(certBytes)
	if block == nil {
		return "", fmt.Errorf("no PEM block found")
	}

	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return "", fmt.Errorf("parse cert: %w", err)
	}

	hash := sha256.Sum256(cert.Raw)
	parts := make([]string, len(hash))
	for i, b := range hash {
		parts[i] = fmt.Sprintf("%02X", b)
	}
	return strings.Join(parts, ":"), nil
}
