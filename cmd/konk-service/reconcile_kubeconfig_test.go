package main

import (
	"strings"
	"testing"

	"k8s.io/client-go/tools/clientcmd"
)

// TestBuildKubeconfig_UsesFileRefsNotEmbeddedData is the regression test for
// the cert-rotation bug that caused log errors like:
//
//	"Unable to authenticate the request" err="x509: certificate has expired
//	 or is not yet valid: current time ... is after ..."
//
// Root cause: the distroless Go rewrite of reconcile-kubeconfig embedded
// cert *data* into the kubeconfig (ClientCertificateData/ClientKeyData/
// CertificateAuthorityData). This disabled client-go's dynamicClientCert
// reload (which only activates for file-based TLS config), so consumers
// kept using expired in-memory certs until pod restart.
//
// The fix uses relative file references that resolve against the Secret
// mount directory, restoring the behavior of the original shell script.
func TestBuildKubeconfig_UsesFileRefsNotEmbeddedData(t *testing.T) {
	out, err := buildKubeconfig("test-konk", "test-konk.aggregate.svc")
	if err != nil {
		t.Fatalf("buildKubeconfig returned error: %v", err)
	}

	yaml := string(out)

	// MUST contain relative file references
	mustContain := []string{
		"certificate-authority: ca.crt",
		"client-certificate: tls.crt",
		"client-key: tls.key",
		"server: https://test-konk.aggregate.svc:6443",
	}
	for _, s := range mustContain {
		if !strings.Contains(yaml, s) {
			t.Errorf("kubeconfig missing required file reference %q\nGot:\n%s", s, yaml)
		}
	}

	// MUST NOT contain embedded cert data (the regression we're guarding against)
	mustNotContain := []string{
		"certificate-authority-data:",
		"client-certificate-data:",
		"client-key-data:",
	}
	for _, s := range mustNotContain {
		if strings.Contains(yaml, s) {
			t.Errorf("kubeconfig contains embedded cert field %q which breaks dynamic cert rotation\nGot:\n%s", s, yaml)
		}
	}
}

// TestBuildKubeconfig_LoadableAndConsistent verifies the output is a valid
// kubeconfig that client-go can load, with the expected context wired up.
func TestBuildKubeconfig_LoadableAndConsistent(t *testing.T) {
	out, err := buildKubeconfig("my-konk", "my-konk.ns.svc")
	if err != nil {
		t.Fatalf("buildKubeconfig returned error: %v", err)
	}

	cfg, err := clientcmd.Load(out)
	if err != nil {
		t.Fatalf("clientcmd.Load failed: %v", err)
	}

	if cfg.CurrentContext != "my-konk" {
		t.Errorf("CurrentContext = %q, want %q", cfg.CurrentContext, "my-konk")
	}

	cluster, ok := cfg.Clusters["my-konk"]
	if !ok {
		t.Fatalf("cluster %q missing", "my-konk")
	}
	if cluster.Server != "https://my-konk.ns.svc:6443" {
		t.Errorf("Server = %q", cluster.Server)
	}
	if cluster.CertificateAuthority != "ca.crt" {
		t.Errorf("CertificateAuthority = %q, want %q", cluster.CertificateAuthority, "ca.crt")
	}
	if len(cluster.CertificateAuthorityData) != 0 {
		t.Errorf("CertificateAuthorityData must be empty (regression: rotation breaks if data is embedded)")
	}

	auth, ok := cfg.AuthInfos["kubernetes-admin"]
	if !ok {
		t.Fatalf("AuthInfo %q missing", "kubernetes-admin")
	}
	if auth.ClientCertificate != "tls.crt" {
		t.Errorf("ClientCertificate = %q, want %q", auth.ClientCertificate, "tls.crt")
	}
	if auth.ClientKey != "tls.key" {
		t.Errorf("ClientKey = %q, want %q", auth.ClientKey, "tls.key")
	}
	if len(auth.ClientCertificateData) != 0 {
		t.Errorf("ClientCertificateData must be empty (regression: rotation breaks if data is embedded)")
	}
	if len(auth.ClientKeyData) != 0 {
		t.Errorf("ClientKeyData must be empty (regression: rotation breaks if data is embedded)")
	}
}

// TestComputeCertSum_DetectsRotation verifies that the checksum changes when
// any of the cert files change. This is what triggers the secret update
// (and, in the rollout-restart PR, dependent deployment annotation patches).
func TestComputeCertSum_DetectsRotation(t *testing.T) {
	ca := []byte("ca-data")
	crt := []byte("crt-data")
	key := []byte("key-data")

	base := computeCertSum(ca, crt, key)

	cases := []struct {
		name              string
		ca, crt, key      []byte
		shouldDifferFrom  string
	}{
		{"ca changed", []byte("ca-data-NEW"), crt, key, base},
		{"crt changed", ca, []byte("crt-data-NEW"), key, base},
		{"key changed", ca, crt, []byte("key-data-NEW"), base},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := computeCertSum(tc.ca, tc.crt, tc.key)
			if got == tc.shouldDifferFrom {
				t.Errorf("checksum did not change when %s; rotation would be missed", tc.name)
			}
		})
	}

	// Same inputs must produce the same checksum (stable, no rotation noise)
	if computeCertSum(ca, crt, key) != base {
		t.Errorf("computeCertSum is not deterministic")
	}
}
