package main

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	pkiDir        = "/etc/kubernetes/pki"
	etcdPKIDir    = "/etc/kubernetes/pki/etcd"
	renewalBuffer = 30 * 24 * time.Hour
)

type config struct {
	Namespace            string
	Fullname             string
	Labels               map[string]string
	Release              string
	Scope                string
	CertManagerNamespace string
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)

	// healthz subcommand: check if ready file exists (used by readiness probe)
	if len(os.Args) >= 3 && os.Args[1] == "healthz" {
		if _, err := os.Stat(os.Args[2]); err != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}

	cfg := loadConfig()
	client := mustCreateClient()
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()

	for {
		sleepUntilRenewal(ctx, client, cfg)

		if err := provision(ctx, client, cfg); err != nil {
			log.Fatalf("Provisioning failed: %v", err)
		}

		log.Println("Provisioning complete")

		if err := os.WriteFile("/tmp/ready", []byte{}, 0644); err != nil {
			log.Fatalf("Failed to write readiness file: %v", err)
		}
	}
}

// sleepUntilRenewal reads the current apiserver cert expiry from the secret
// and sleeps until renewalBuffer before NotAfter. On the first run (no secret
// yet) it returns true immediately so provisioning runs right away.
// Returns true if provisioning is needed now.
// When cert is still valid, it writes the ready file, sleeps, then returns true
// (to re-provision after waking).
func sleepUntilRenewal(ctx context.Context, client *kubernetes.Clientset, cfg config) bool {
	secret, err := getSecret(ctx, client, cfg.Namespace, cfg.Fullname+"-apiserver-cert")
	if err != nil {
		log.Printf("Could not read apiserver-cert secret, provisioning now: %v", err)
		return true
	}
	if secret == nil {
		log.Println("No existing cert found, provisioning now")
		return true
	}

	certPEM := secret.Data["apiserver.crt"]
	block, _ := pem.Decode(certPEM)
	if block == nil {
		log.Println("Could not decode cert PEM, provisioning now")
		return true
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		log.Printf("Could not parse cert, provisioning now: %v", err)
		return true
	}

	renewAt := cert.NotAfter.Add(-renewalBuffer)
	if time.Now().Before(renewAt) {
		sleepDur := time.Until(renewAt)
		log.Printf("Cert expires %s, next renewal at %s (sleeping %s)",
			cert.NotAfter.Format(time.RFC3339),
			renewAt.Format(time.RFC3339),
			sleepDur.Round(time.Minute))
		// Cert is still valid — mark ready before sleeping
		if err := os.WriteFile("/tmp/ready", []byte{}, 0644); err != nil {
			log.Printf("Failed to write readiness file: %v", err)
		}
		select {
		case <-time.After(sleepDur):
		case <-ctx.Done():
			log.Println("Received shutdown signal, exiting")
			os.Exit(0)
		}
	} else {
		log.Printf("Cert expires %s, renewal due now", cert.NotAfter.Format(time.RFC3339))
	}
	return true
}

func loadConfig() config {
	labelsStr := os.Getenv("LABELS")
	labels := make(map[string]string)
	for _, pair := range strings.Fields(labelsStr) {
		parts := strings.SplitN(pair, "=", 2)
		if len(parts) == 2 {
			labels[parts[0]] = parts[1]
		}
	}

	return config{
		Namespace:            mustEnv("NAMESPACE"),
		Fullname:             mustEnv("FULLNAME"),
		Labels:               labels,
		Release:              mustEnv("RELEASE"),
		Scope:                os.Getenv("SCOPE"),
		CertManagerNamespace: os.Getenv("CERT_MANAGER_NAMESPACE"),
	}
}

func mustEnv(key string) string {
	val := os.Getenv(key)
	if val == "" {
		log.Fatalf("Required environment variable %s is not set", key)
	}
	return val
}

func mustCreateClient() *kubernetes.Clientset {
	rc, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("Failed to get in-cluster config: %v", err)
	}
	cs, err := kubernetes.NewForConfig(rc)
	if err != nil {
		log.Fatalf("Failed to create clientset: %v", err)
	}
	return cs
}

func provision(ctx context.Context, client *kubernetes.Clientset, cfg config) error {
	// Load existing CA secrets if present
	if err := loadExistingCA(ctx, client, cfg); err != nil {
		return fmt.Errorf("loading CA: %w", err)
	}
	if err := loadExistingEtcdCA(ctx, client, cfg); err != nil {
		return fmt.Errorf("loading etcd CA: %w", err)
	}

	// Write kubeadm config
	if err := writeKubeadmConfig(cfg.Release); err != nil {
		return fmt.Errorf("writing kubeadm config: %w", err)
	}

	// Run kubeadm cert phases
	if err := runKubeadmPhases(cfg); err != nil {
		return fmt.Errorf("running kubeadm phases: %w", err)
	}

	// Manage secrets
	if err := manageEtcdCertSecret(ctx, client, cfg); err != nil {
		return fmt.Errorf("managing etcd-cert secret: %w", err)
	}
	if err := manageApiserverCertSecret(ctx, client, cfg); err != nil {
		return fmt.Errorf("managing apiserver-cert secret: %w", err)
	}
	if err := manageCASecret(ctx, client, cfg); err != nil {
		return fmt.Errorf("managing CA secret: %w", err)
	}
	if err := manageEtcdCASecret(ctx, client, cfg); err != nil {
		return fmt.Errorf("managing etcd-ca secret: %w", err)
	}
	if cfg.Scope == "cluster" && cfg.CertManagerNamespace != "" {
		if err := manageCertManagerCASecret(ctx, client, cfg); err != nil {
			return fmt.Errorf("managing cert-manager CA secret: %w", err)
		}
	}
	if err := manageKubeconfigSecret(ctx, client, cfg); err != nil {
		return fmt.Errorf("managing kubeconfig secret: %w", err)
	}

	// Wait for deployment to be progressing
	if err := waitForDeployment(ctx, client, cfg); err != nil {
		return fmt.Errorf("waiting for deployment: %w", err)
	}

	// Set owner references on all managed secrets
	if err := setOwnerReferences(ctx, client, cfg); err != nil {
		return fmt.Errorf("setting owner references: %w", err)
	}

	return nil
}

// loadExistingCA loads the existing CA secret and writes cert/key to disk
func loadExistingCA(ctx context.Context, client *kubernetes.Clientset, cfg config) error {
	secret, err := client.CoreV1().Secrets(cfg.Namespace).Get(ctx, cfg.Fullname+"-ca", metav1.GetOptions{})
	if k8serrors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}

	if err := os.MkdirAll(pkiDir, 0755); err != nil {
		return err
	}
	for _, ext := range []string{"crt", "key"} {
		data := secret.Data["tls."+ext]
		if err := os.WriteFile(filepath.Join(pkiDir, "ca."+ext), data, 0600); err != nil {
			return err
		}
	}
	log.Printf("Loaded existing CA from secret %s-ca", cfg.Fullname)
	return nil
}

// loadExistingEtcdCA loads the existing etcd CA secret and writes cert/key to disk
func loadExistingEtcdCA(ctx context.Context, client *kubernetes.Clientset, cfg config) error {
	secret, err := client.CoreV1().Secrets(cfg.Namespace).Get(ctx, cfg.Fullname+"-etcd-ca", metav1.GetOptions{})
	if k8serrors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}

	if err := os.MkdirAll(etcdPKIDir, 0755); err != nil {
		return err
	}
	for _, ext := range []string{"crt", "key"} {
		data := secret.Data["tls."+ext]
		if err := os.WriteFile(filepath.Join(etcdPKIDir, "ca."+ext), data, 0600); err != nil {
			return err
		}
	}
	log.Printf("Loaded existing etcd CA from secret %s-etcd-ca", cfg.Fullname)
	return nil
}

func writeKubeadmConfig(release string) error {
	cfg := fmt.Sprintf(`apiVersion: "kubeadm.k8s.io/v1beta2"
kind: ClusterConfiguration
etcd:
  local:
    serverCertSANs:
    - localhost
    - %s-etcd-headless
`, release)
	return os.WriteFile("/tmp/kubeadmcfg.yaml", []byte(cfg), 0644)
}

func runCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	log.Printf("Running: %s %s", name, strings.Join(args, " "))
	return cmd.Run()
}

func runKubeadmPhases(cfg config) error {
	sans := strings.Join([]string{
		cfg.Fullname,
		cfg.Fullname + "." + cfg.Namespace,
		cfg.Fullname + "." + cfg.Namespace + ".svc",
		cfg.Fullname + "." + cfg.Namespace + ".svc.cluster.local",
	}, ",")

	// Generate all certs
	if err := runCommand("kubeadm", "init", "phase", "certs", "all",
		"--apiserver-cert-extra-sans", sans); err != nil {
		return fmt.Errorf("kubeadm certs all: %w", err)
	}

	// Remove etcd server certs to regenerate with custom config
	matches, _ := filepath.Glob(filepath.Join(etcdPKIDir, "server*"))
	for _, m := range matches {
		os.Remove(m)
	}

	// Regenerate etcd server cert with custom SANs
	if err := runCommand("kubeadm", "init", "phase", "certs", "etcd-server",
		"--config=/tmp/kubeadmcfg.yaml"); err != nil {
		return fmt.Errorf("kubeadm etcd-server: %w", err)
	}

	// Generate admin kubeconfig
	controlPlaneEndpoint := cfg.Fullname + "." + cfg.Namespace + ".svc"
	if err := runCommand("kubeadm", "init", "phase", "kubeconfig", "admin",
		"--control-plane-endpoint", controlPlaneEndpoint); err != nil {
		return fmt.Errorf("kubeadm kubeconfig admin: %w", err)
	}

	// List generated PKI files
	filepath.Walk(pkiDir, func(path string, info os.FileInfo, err error) error {
		if err == nil {
			log.Println(path)
		}
		return nil
	})

	return nil
}

func mustReadFile(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		log.Fatalf("Failed to read %s: %v", path, err)
	}
	return data
}

// getSecret returns the secret or nil if not found
func getSecret(ctx context.Context, client *kubernetes.Clientset, namespace, name string) (*corev1.Secret, error) {
	secret, err := client.CoreV1().Secrets(namespace).Get(ctx, name, metav1.GetOptions{})
	if k8serrors.IsNotFound(err) {
		return nil, nil
	}
	return secret, err
}

func createSecret(ctx context.Context, client *kubernetes.Clientset, secret *corev1.Secret) error {
	_, err := client.CoreV1().Secrets(secret.Namespace).Create(ctx, secret, metav1.CreateOptions{})
	return err
}

func updateSecret(ctx context.Context, client *kubernetes.Clientset, secret *corev1.Secret) error {
	_, err := client.CoreV1().Secrets(secret.Namespace).Update(ctx, secret, metav1.UpdateOptions{})
	return err
}

func manageEtcdCertSecret(ctx context.Context, client *kubernetes.Clientset, cfg config) error {
	name := cfg.Fullname + "-etcd-cert"
	existing, err := getSecret(ctx, client, cfg.Namespace, name)
	if err != nil {
		return err
	}

	data := map[string][]byte{
		"ca.crt":     mustReadFile(filepath.Join(etcdPKIDir, "ca.crt")),
		"server.crt": mustReadFile(filepath.Join(etcdPKIDir, "server.crt")),
		"server.key": mustReadFile(filepath.Join(etcdPKIDir, "server.key")),
	}

	if existing == nil {
		log.Printf("Creating secret %s", name)
		return createSecret(ctx, client, &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: cfg.Namespace,
				Labels:    cfg.Labels,
			},
			Data: data,
		})
	}

	log.Printf("Updating secret %s", name)
	existing.Data["server.crt"] = data["server.crt"]
	existing.Data["server.key"] = data["server.key"]
	return updateSecret(ctx, client, existing)
}

func manageApiserverCertSecret(ctx context.Context, client *kubernetes.Clientset, cfg config) error {
	name := cfg.Fullname + "-apiserver-cert"
	existing, err := getSecret(ctx, client, cfg.Namespace, name)
	if err != nil {
		return err
	}

	data := map[string][]byte{
		"apiserver.crt":             mustReadFile(filepath.Join(pkiDir, "apiserver.crt")),
		"apiserver.key":             mustReadFile(filepath.Join(pkiDir, "apiserver.key")),
		"ca.crt":                    mustReadFile(filepath.Join(pkiDir, "ca.crt")),
		"etcd-ca.crt":               mustReadFile(filepath.Join(etcdPKIDir, "ca.crt")),
		"apiserver-etcd-client.crt": mustReadFile(filepath.Join(pkiDir, "apiserver-etcd-client.crt")),
		"apiserver-etcd-client.key": mustReadFile(filepath.Join(pkiDir, "apiserver-etcd-client.key")),
	}

	if existing == nil {
		log.Printf("Creating secret %s", name)
		return createSecret(ctx, client, &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: cfg.Namespace,
				Labels:    cfg.Labels,
			},
			Data: data,
		})
	}

	log.Printf("Updating secret %s", name)
	existing.Data["apiserver.crt"] = data["apiserver.crt"]
	existing.Data["apiserver.key"] = data["apiserver.key"]
	existing.Data["apiserver-etcd-client.crt"] = data["apiserver-etcd-client.crt"]
	existing.Data["apiserver-etcd-client.key"] = data["apiserver-etcd-client.key"]
	return updateSecret(ctx, client, existing)
}

func manageCASecret(ctx context.Context, client *kubernetes.Clientset, cfg config) error {
	name := cfg.Fullname + "-ca"
	existing, err := getSecret(ctx, client, cfg.Namespace, name)
	if err != nil {
		return err
	}
	if existing != nil {
		// Ensure the keep annotation is present on existing secrets
		if existing.Annotations == nil || existing.Annotations["helm.sh/resource-policy"] != "keep" {
			if existing.Annotations == nil {
				existing.Annotations = map[string]string{}
			}
			existing.Annotations["helm.sh/resource-policy"] = "keep"
			log.Printf("Updating TLS secret %s with resource-policy annotation", name)
			return updateSecret(ctx, client, existing)
		}
		return nil // CA secret already exists with correct annotations
	}

	log.Printf("Creating TLS secret %s", name)
	return createSecret(ctx, client, &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: cfg.Namespace,
			Labels:    cfg.Labels,
			Annotations: map[string]string{
				"helm.sh/resource-policy": "keep",
			},
		},
		Type: corev1.SecretTypeTLS,
		Data: map[string][]byte{
			"tls.crt": mustReadFile(filepath.Join(pkiDir, "ca.crt")),
			"tls.key": mustReadFile(filepath.Join(pkiDir, "ca.key")),
		},
	})
}

func manageEtcdCASecret(ctx context.Context, client *kubernetes.Clientset, cfg config) error {
	name := cfg.Fullname + "-etcd-ca"
	existing, err := getSecret(ctx, client, cfg.Namespace, name)
	if err != nil {
		return err
	}
	if existing != nil {
		// Ensure the keep annotation is present on existing secrets
		if existing.Annotations == nil || existing.Annotations["helm.sh/resource-policy"] != "keep" {
			if existing.Annotations == nil {
				existing.Annotations = map[string]string{}
			}
			existing.Annotations["helm.sh/resource-policy"] = "keep"
			log.Printf("Updating TLS secret %s with resource-policy annotation", name)
			return updateSecret(ctx, client, existing)
		}
		return nil // etcd CA secret already exists with correct annotations
	}

	log.Printf("Creating TLS secret %s", name)
	return createSecret(ctx, client, &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: cfg.Namespace,
			Labels:    cfg.Labels,
			Annotations: map[string]string{
				"helm.sh/resource-policy": "keep",
			},
		},
		Type: corev1.SecretTypeTLS,
		Data: map[string][]byte{
			"tls.crt": mustReadFile(filepath.Join(etcdPKIDir, "ca.crt")),
			"tls.key": mustReadFile(filepath.Join(etcdPKIDir, "ca.key")),
		},
	})
}

func manageCertManagerCASecret(ctx context.Context, client *kubernetes.Clientset, cfg config) error {
	name := cfg.Fullname + "-ca"
	ns := cfg.CertManagerNamespace
	existing, err := getSecret(ctx, client, ns, name)
	if err != nil {
		return err
	}

	data := map[string][]byte{
		"tls.crt": mustReadFile(filepath.Join(pkiDir, "ca.crt")),
		"tls.key": mustReadFile(filepath.Join(pkiDir, "ca.key")),
	}

	if existing == nil {
		log.Printf("Creating TLS secret %s in namespace %s", name, ns)
		return createSecret(ctx, client, &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: ns,
				Labels:    cfg.Labels,
			},
			Type: corev1.SecretTypeTLS,
			Data: data,
		})
	}

	log.Printf("Updating TLS secret %s in namespace %s", name, ns)
	existing.Data["tls.crt"] = data["tls.crt"]
	existing.Data["tls.key"] = data["tls.key"]
	return updateSecret(ctx, client, existing)
}

func manageKubeconfigSecret(ctx context.Context, client *kubernetes.Clientset, cfg config) error {
	name := cfg.Fullname + "-kubeconfig"
	existing, err := getSecret(ctx, client, cfg.Namespace, name)
	if err != nil {
		return err
	}
	if existing != nil {
		return nil // kubeconfig secret already exists, don't overwrite
	}

	log.Printf("Creating secret %s", name)
	return createSecret(ctx, client, &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: cfg.Namespace,
			Labels:    cfg.Labels,
		},
		Data: map[string][]byte{
			"admin.conf": mustReadFile("/etc/kubernetes/admin.conf"),
		},
	})
}

func waitForDeployment(ctx context.Context, client *kubernetes.Clientset, cfg config) error {
	log.Printf("Waiting for deployments with label app.kubernetes.io/instance=%s to be progressing", cfg.Release)
	timeout := time.After(3 * time.Minute)
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-timeout:
			return fmt.Errorf("timed out waiting for deployment to be progressing")
		case <-ticker.C:
			deployments, err := client.AppsV1().Deployments(cfg.Namespace).List(ctx, metav1.ListOptions{
				LabelSelector: "app.kubernetes.io/instance=" + cfg.Release,
			})
			if err != nil {
				log.Printf("Error listing deployments: %v", err)
				continue
			}

			if len(deployments.Items) == 0 {
				continue
			}

			allProgressing := true
			for _, d := range deployments.Items {
				progressing := false
				for _, c := range d.Status.Conditions {
					if c.Type == appsv1.DeploymentProgressing && c.Status == corev1.ConditionTrue {
						progressing = true
						break
					}
				}
				if !progressing {
					allProgressing = false
					break
				}
			}

			if allProgressing {
				log.Println("Deployments are progressing")
				return nil
			}
		}
	}
}

func setOwnerReferences(ctx context.Context, client *kubernetes.Clientset, cfg config) error {
	// Get the deployment UID
	deployment, err := client.AppsV1().Deployments(cfg.Namespace).Get(ctx, cfg.Fullname, metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("getting deployment %s: %w", cfg.Fullname, err)
	}

	ownerRef := metav1.OwnerReference{
		APIVersion: "apps/v1",
		Kind:       "Deployment",
		Name:       cfg.Fullname,
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

	secretNames := []string{
		cfg.Fullname + "-apiserver-cert",
		cfg.Fullname + "-etcd-cert",
		cfg.Fullname + "-ca",
		cfg.Fullname + "-etcd-ca",
		cfg.Fullname + "-kubeconfig",
	}

	for _, name := range secretNames {
		log.Printf("Setting owner reference on secret %s", name)
		_, err := client.CoreV1().Secrets(cfg.Namespace).Patch(
			ctx, name, types.MergePatchType, patch, metav1.PatchOptions{},
		)
		if err != nil {
			return fmt.Errorf("patching secret %s: %w", name, err)
		}
	}

	return nil
}
