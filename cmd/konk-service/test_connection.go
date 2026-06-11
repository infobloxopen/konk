package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

// runTestConnection replaces konk/templates/tests/test-connection.yaml shell script.
// It verifies the konk API server is healthy by:
//  1. Checking cluster-info (via kubeconfig)
//  2. Listing apiservices
//  3. Connecting via direct TLS with client certs
//
// Required env vars:
//
//	KUBECONFIG       - path to konk kubeconfig
//	KONK_ENDPOINT    - the konk API server URL (e.g. https://my-konk:6443)
//	TLS_CA_PATH      - path to CA cert for direct TLS connection
//	TLS_CERT_PATH    - path to client cert for direct TLS connection
//	TLS_KEY_PATH     - path to client key for direct TLS connection
func runTestConnection() error {
	kubeconfigPath := mustEnv("KUBECONFIG")
	konkEndpoint := mustEnv("KONK_ENDPOINT")
	tlsCAPath := mustEnv("TLS_CA_PATH")
	tlsCertPath := mustEnv("TLS_CERT_PATH")
	tlsKeyPath := mustEnv("TLS_KEY_PATH")

	ctx := context.Background()

	// Step 1: Wait for cluster-info (API server is up)
	log.Println("Step 1: Checking cluster-info via kubeconfig...")
	if err := waitForClusterInfo(ctx, kubeconfigPath); err != nil {
		return fmt.Errorf("cluster-info check failed: %w", err)
	}
	log.Println("Cluster is reachable via kubeconfig")

	// Step 2: List apiservices
	log.Println("Step 2: Listing apiservices...")
	if err := waitForAPIServices(ctx, kubeconfigPath); err != nil {
		return fmt.Errorf("apiservices check failed: %w", err)
	}
	log.Println("APIServices are available")

	// Step 3: Direct TLS connection with client certs
	log.Println("Step 3: Verifying direct TLS connection...")
	if err := waitForDirectTLS(ctx, konkEndpoint, tlsCAPath, tlsCertPath, tlsKeyPath); err != nil {
		return fmt.Errorf("direct TLS check failed: %w", err)
	}
	log.Println("Direct TLS connection successful")

	log.Println("All connection tests passed!")
	return nil
}

func waitForClusterInfo(ctx context.Context, kubeconfigPath string) error {
	for {
		client, _, cleanup, err := newKubeconfigClient(kubeconfigPath)
		if err == nil {
			// Use Discovery to check that the API server is reachable.
			// A konk API server is a bare kube-apiserver without a
			// controller-manager, so the "kubernetes" service in the
			// default namespace does not exist.  Calling ServerVersion()
			// hits the /version endpoint which is always available.
			_, err = client.Discovery().ServerVersion()
			cleanup()
			if err == nil {
				return nil
			}
		}
		log.Printf("Cluster not ready: %v, retrying...", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(1 * time.Second):
		}
	}
}

func waitForAPIServices(ctx context.Context, kubeconfigPath string) error {
	for {
		client, _, cleanup, err := newKubeconfigClient(kubeconfigPath)
		if err == nil {
			_, err = client.Discovery().ServerGroups()
			cleanup()
			if err == nil {
				return nil
			}
		}
		log.Printf("APIServices not ready: %v, retrying...", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(1 * time.Second):
		}
	}
}

func waitForDirectTLS(ctx context.Context, endpoint, caPath, certPath, keyPath string) error {
	for {
		err := checkDirectTLS(endpoint, caPath, certPath, keyPath)
		if err == nil {
			return nil
		}
		log.Printf("Direct TLS not ready: %v, retrying...", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(1 * time.Second):
		}
	}
}

func checkDirectTLS(endpoint, caPath, certPath, keyPath string) error {
	caCert, err := os.ReadFile(caPath)
	if err != nil {
		return fmt.Errorf("reading CA cert: %w", err)
	}
	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCert) {
		return fmt.Errorf("failed to parse CA cert")
	}

	clientCert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return fmt.Errorf("loading client cert: %w", err)
	}

	transport := &http.Transport{
		TLSClientConfig: &tls.Config{
			RootCAs:      caCertPool,
			Certificates: []tls.Certificate{clientCert},
		},
	}
	httpClient := &http.Client{Transport: transport, Timeout: 5 * time.Second}

	resp, err := httpClient.Get(endpoint + "/api")
	if err != nil {
		return fmt.Errorf("GET /api: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET /api returned status %d", resp.StatusCode)
	}
	return nil
}
