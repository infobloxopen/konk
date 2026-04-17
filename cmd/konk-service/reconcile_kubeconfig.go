package main

import (
	"context"
	"crypto/md5"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"os"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

// runReconcileKubeconfig replaces kubeconfig-deployment.yaml shell script.
// It builds a kubeconfig from cert-manager TLS secrets, creates/updates
// a Kubernetes Secret with it, and sets owner references.
//
// Required env vars:
//   KUBECONFIG_PATH - path to write the kubeconfig file (e.g. /etc/kubernetes/admin.conf)
//   LABELS          - space-separated key=value labels for the secret
//   NAMESPACE       - the namespace
//   FULLNAME        - the konk-service fullname (for secret names)
//   KONK_NAME       - the konk cluster name
//   KONK_FQDN       - the konk FQDN (e.g. my-konk.namespace.svc)
//   CERT_DIR        - path to mounted cert-manager certs (ca.crt, tls.crt, tls.key)
func runReconcileKubeconfig() error {
	kubeconfigPath := mustEnv("KUBECONFIG_PATH")
	labelsStr := mustEnv("LABELS")
	namespace := mustEnv("NAMESPACE")
	fullname := mustEnv("FULLNAME")
	konkName := mustEnv("KONK_NAME")
	konkFQDN := mustEnv("KONK_FQDN")
	certDir := mustEnv("CERT_DIR")

	labels := parseLabels(labelsStr)

	infraClient, err := newInClusterClient()
	if err != nil {
		return fmt.Errorf("creating infra client: %w", err)
	}

	ctx := context.Background()
	secretName := fullname + "-kubeconfig"
	var lastCertSum string

	const maxConsecutiveErrors = 10
	consecutiveErrors := 0

	for {
		log.Println("Reconciling kubeconfig...")
		err = reconcileOnce(ctx, infraClient, kubeconfigPath, certDir, konkName, konkFQDN, namespace, fullname, secretName, labels, &lastCertSum)
		if err != nil {
			consecutiveErrors++
			log.Printf("Error reconciling kubeconfig (%d/%d consecutive): %v",
				consecutiveErrors, maxConsecutiveErrors, err)
			if consecutiveErrors >= maxConsecutiveErrors {
				os.Remove("/tmp/status")
				log.Fatalf("FATAL: %d consecutive kubeconfig reconciliation failures — exiting so pod restarts. Last error: %v",
					maxConsecutiveErrors, err)
			}
		} else {
			if consecutiveErrors > 0 {
				log.Printf("Kubeconfig reconciliation recovered after %d consecutive errors", consecutiveErrors)
			}
			consecutiveErrors = 0
		}

		// 1 minute loop with 10s jitter for faster cert rotation pickup
		jitter := time.Duration(rand.Intn(10)) * time.Second
		time.Sleep(60*time.Second + jitter)
	}
}

func reconcileOnce(
	ctx context.Context,
	infraClient *kubernetes.Clientset,
	kubeconfigPath, certDir, konkName, konkFQDN, namespace, fullname, secretName string,
	labels map[string]string,
	lastCertSum *string,
) error {
	// Read certs from the mounted cert-manager secret
	caCert, err := os.ReadFile(certDir + "/ca.crt")
	if err != nil {
		return fmt.Errorf("reading ca.crt: %w", err)
	}
	tlsCert, err := os.ReadFile(certDir + "/tls.crt")
	if err != nil {
		return fmt.Errorf("reading tls.crt: %w", err)
	}
	tlsKey, err := os.ReadFile(certDir + "/tls.key")
	if err != nil {
		return fmt.Errorf("reading tls.key: %w", err)
	}

	// Validate cert expiry — log warnings for expiring certs
	if err := checkCertExpiry("kubeconfig client", tlsCert); err != nil {
		log.Printf("CRITICAL: client cert is expired, kubeconfig will be rejected by konk: %v", err)
	}
	checkCertExpiry("kubeconfig CA", caCert)

	// Build a kubeconfig programmatically
	kubeconfig := clientcmdapi.NewConfig()
	kubeconfig.Clusters[konkName] = &clientcmdapi.Cluster{
		Server:                   "https://" + konkFQDN + ":6443",
		CertificateAuthorityData: caCert,
	}
	kubeconfig.AuthInfos["kubernetes-admin"] = &clientcmdapi.AuthInfo{
		ClientCertificateData: tlsCert,
		ClientKeyData:         tlsKey,
	}
	kubeconfig.Contexts[konkName] = &clientcmdapi.Context{
		Cluster:  konkName,
		AuthInfo: "kubernetes-admin",
	}
	kubeconfig.CurrentContext = konkName

	kubeconfigBytes, err := clientcmd.Write(*kubeconfig)
	if err != nil {
		return fmt.Errorf("serializing kubeconfig: %w", err)
	}

	dir := kubeconfigPath[:strings.LastIndex(kubeconfigPath, "/")]
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("creating kubeconfig dir: %w", err)
	}
	if err := os.WriteFile(kubeconfigPath, kubeconfigBytes, 0600); err != nil {
		return fmt.Errorf("writing kubeconfig: %w", err)
	}

	// Compute cert checksum to detect rotation
	certSum := computeCertSum(caCert, tlsCert, tlsKey)

	secretData := map[string][]byte{
		"admin.conf": kubeconfigBytes,
		"ca.crt":     caCert,
		"tls.crt":    tlsCert,
		"tls.key":    tlsKey,
	}

	err = reconcileKubeconfigSecret(ctx, infraClient, namespace, secretName, fullname, labels, secretData, certSum, lastCertSum)
	if err != nil {
		return fmt.Errorf("reconciling secret: %w", err)
	}
	return nil
}

func parseLabels(labelsStr string) map[string]string {
	labels := make(map[string]string)
	for _, pair := range strings.Fields(labelsStr) {
		parts := strings.SplitN(pair, "=", 2)
		if len(parts) == 2 {
			labels[parts[0]] = parts[1]
		}
	}
	return labels
}

func computeCertSum(files ...[]byte) string {
	h := md5.New()
	for _, f := range files {
		h.Write(f)
	}
	return fmt.Sprintf("%x", h.Sum(nil))
}

func reconcileKubeconfigSecret(
	ctx context.Context,
	client *kubernetes.Clientset,
	namespace, secretName, fullname string,
	labels map[string]string,
	data map[string][]byte,
	certSum string,
	lastCertSum *string,
) error {
	existing, err := client.CoreV1().Secrets(namespace).Get(ctx, secretName, metav1.GetOptions{})
	if k8serrors.IsNotFound(err) {
		// Create new secret
		log.Printf("Creating secret %s", secretName)
		secret := &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{
				Name:      secretName,
				Namespace: namespace,
				Labels:    labels,
			},
			Data: data,
		}
		_, err = client.CoreV1().Secrets(namespace).Create(ctx, secret, metav1.CreateOptions{})
		if err != nil {
			return fmt.Errorf("creating secret: %w", err)
		}

		// Set owner reference to the deployment
		if err := setKubeconfigOwnerRef(ctx, client, namespace, secretName, fullname); err != nil {
			return fmt.Errorf("setting owner ref: %w", err)
		}

		*lastCertSum = certSum
		if err := writeHealthFile("/tmp/status", 0); err != nil {
			log.Printf("Warning: failed to write health file: %v", err)
		}
		return nil
	}
	if err != nil {
		return fmt.Errorf("getting secret: %w", err)
	}

	// Secret exists — check if certs have rotated
	if certSum != *lastCertSum {
		log.Printf("Certs changed, updating secret %s", secretName)
		existing.Data = data
		_, err = client.CoreV1().Secrets(namespace).Update(ctx, existing, metav1.UpdateOptions{})
		if err != nil {
			return fmt.Errorf("updating secret: %w", err)
		}
		*lastCertSum = certSum
	} else {
		log.Printf("Certs unchanged, skipping update")
	}

	if err := writeHealthFile("/tmp/status", 0); err != nil {
		log.Printf("Warning: failed to write health file: %v", err)
	}
	return nil
}

func setKubeconfigOwnerRef(ctx context.Context, client *kubernetes.Clientset, namespace, secretName, fullname string) error {
	deploymentName := fullname + "-kubeconfig"
	deployment, err := client.AppsV1().Deployments(namespace).Get(ctx, deploymentName, metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("getting deployment %s: %w", deploymentName, err)
	}

	ownerRef := metav1.OwnerReference{
		APIVersion: "apps/v1",
		Kind:       "Deployment",
		Name:       deploymentName,
		UID:        deployment.UID,
	}

	patch, err := json.Marshal(map[string]interface{}{
		"metadata": map[string]interface{}{
			"ownerReferences": []metav1.OwnerReference{ownerRef},
		},
	})
	if err != nil {
		return err
	}

	_, err = client.CoreV1().Secrets(namespace).Patch(
		ctx, secretName, types.MergePatchType, patch, metav1.PatchOptions{},
	)
	return err
}
