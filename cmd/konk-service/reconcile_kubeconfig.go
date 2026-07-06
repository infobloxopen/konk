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

	appsv1 "k8s.io/api/apps/v1"
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

	ctx := context.Background()
	secretName := fullname + "-kubeconfig"
	var lastCertSum string

	for {
		log.Println("Reconciling kubeconfig...")

		// Wrap in an anonymous function so defer cleanup() fires at end of
		// each iteration, releasing the HTTP/2 transport even if reconcileOnce panics.
		func() {
			infraClient, cleanup, err := newInClusterClient()
			if err != nil {
				log.Printf("Error creating infra client: %v", err)
				return
			}
			defer cleanup()
			reconcileOnce(ctx, infraClient, kubeconfigPath, certDir, konkName, konkFQDN, namespace, fullname, secretName, labels, &lastCertSum)
		}()

		// 3 minute loop with 30s jitter (matching original shell)
		jitter := time.Duration(rand.Intn(30)) * time.Second
		time.Sleep(150*time.Second + jitter)
	}
}

func reconcileOnce(
	ctx context.Context,
	infraClient *kubernetes.Clientset,
	kubeconfigPath, certDir, konkName, konkFQDN, namespace, fullname, secretName string,
	labels map[string]string,
	lastCertSum *string,
) {
	// Read certs from the mounted cert-manager secret
	caCert, err := os.ReadFile(certDir + "/ca.crt")
	if err != nil {
		log.Printf("Error reading ca.crt: %v", err)
		return
	}
	tlsCert, err := os.ReadFile(certDir + "/tls.crt")
	if err != nil {
		log.Printf("Error reading tls.crt: %v", err)
		return
	}
	tlsKey, err := os.ReadFile(certDir + "/tls.key")
	if err != nil {
		log.Printf("Error reading tls.key: %v", err)
		return
	}

	kubeconfigBytes, err := buildKubeconfig(konkName, konkFQDN)
	if err != nil {
		log.Printf("Error serializing kubeconfig: %v", err)
		return
	}

	dir := kubeconfigPath[:strings.LastIndex(kubeconfigPath, "/")]
	if err := os.MkdirAll(dir, 0755); err != nil {
		log.Printf("Error creating kubeconfig dir: %v", err)
		return
	}
	if err := os.WriteFile(kubeconfigPath, kubeconfigBytes, 0600); err != nil {
		log.Printf("Error writing kubeconfig: %v", err)
		return
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
		log.Printf("Error reconciling secret: %v", err)
	}
}

// buildKubeconfig returns a kubeconfig that references certs by relative file
// path (ca.crt, tls.crt, tls.key) rather than embedding cert data.
//
// This is critical for automatic cert rotation: when client-go sees file-based
// TLS config, it activates the dynamicClientCert reload mechanism in
// k8s.io/client-go/transport/cert_rotation.go which re-reads the cert files
// from disk on every TLS handshake (with a 5-minute refresh). Embedding cert
// data via ClientCertificateData/ClientKeyData/CertificateAuthorityData
// disables this mechanism, causing consumers to keep using the expired cert
// in memory until pod restart.
//
// Regression history: the original shell-based reconcile-kubeconfig used file
// refs (`kubectl config set-credentials --client-certificate tls.crt ...`).
// The distroless Go rewrite initially embedded cert *data* which broke
// rotation. See kubeconfig-cert-rotation-options.md (Option 7).
func buildKubeconfig(konkName, konkFQDN string) ([]byte, error) {
	kubeconfig := clientcmdapi.NewConfig()
	kubeconfig.Clusters[konkName] = &clientcmdapi.Cluster{
		Server:               "https://" + konkFQDN + ":6443",
		CertificateAuthority: "ca.crt",
	}
	kubeconfig.AuthInfos["kubernetes-admin"] = &clientcmdapi.AuthInfo{
		ClientCertificate: "tls.crt",
		ClientKey:         "tls.key",
	}
	kubeconfig.Contexts[konkName] = &clientcmdapi.Context{
		Cluster:  konkName,
		AuthInfo: "kubernetes-admin",
	}
	kubeconfig.CurrentContext = konkName
	return clientcmd.Write(*kubeconfig)
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

		// Trigger rolling restart of deployments that mount this secret
		if *lastCertSum != "" {
			// Only restart on rotation (not on first run)
			if err := restartDependentDeployments(ctx, client, namespace, secretName, certSum); err != nil {
				log.Printf("Warning: failed to restart dependent deployments: %v", err)
			}
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

// restartDependentDeployments finds all deployments in the namespace that mount
// the given secret as a volume, and patches their pod template annotation to
// trigger a rolling restart (similar to `kubectl rollout restart`).
func restartDependentDeployments(ctx context.Context, client *kubernetes.Clientset, namespace, secretName, certSum string) error {
	deployments, err := client.AppsV1().Deployments(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("listing deployments: %w", err)
	}

	for _, deploy := range deployments.Items {
		if !deploymentMountsSecret(deploy, secretName) {
			continue
		}

		log.Printf("Restarting deployment %s (mounts rotated secret %s)", deploy.Name, secretName)

		patch, err := json.Marshal(map[string]interface{}{
			"spec": map[string]interface{}{
				"template": map[string]interface{}{
					"metadata": map[string]interface{}{
						"annotations": map[string]string{
							"konk.infoblox.com/cert-checksum": certSum,
						},
					},
				},
			},
		})
		if err != nil {
			log.Printf("Error marshaling patch for %s: %v", deploy.Name, err)
			continue
		}

		_, err = client.AppsV1().Deployments(namespace).Patch(
			ctx, deploy.Name, types.StrategicMergePatchType, patch, metav1.PatchOptions{},
		)
		if err != nil {
			log.Printf("Error patching deployment %s: %v", deploy.Name, err)
			continue
		}
	}

	return nil
}

// deploymentMountsSecret checks if a deployment has a volume that references
// the given secret name.
func deploymentMountsSecret(deploy appsv1.Deployment, secretName string) bool {
	for _, vol := range deploy.Spec.Template.Spec.Volumes {
		if vol.Secret != nil && vol.Secret.SecretName == secretName {
			return true
		}
	}
	return false
}
