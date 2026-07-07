package main

import (
	"fmt"
	"log"
	"os"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)

	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "Usage: konk-service <command>\n")
		fmt.Fprintf(os.Stderr, "Commands:\n")
		fmt.Fprintf(os.Stderr, "  reconcile-kubeconfig   Build and reconcile kubeconfig secret from cert-manager certs\n")
		fmt.Fprintf(os.Stderr, "  reconcile-apiservice   Deploy APIService and related resources into konk\n")
		fmt.Fprintf(os.Stderr, "  delete-apiservice      Delete APIService and related resources from konk\n")
		fmt.Fprintf(os.Stderr, "  test-apiservice        Poll APIService health and write readiness status\n")
		fmt.Fprintf(os.Stderr, "  test-connection        Smoke-test konk API server connectivity\n")
		fmt.Fprintf(os.Stderr, "  test-setup             Verify RBAC and wait for CRD resources\n")
		fmt.Fprintf(os.Stderr, "  wait-for-resource      Wait until a resource type is listable\n")
		fmt.Fprintf(os.Stderr, "  example-test           Create, get, and delete a sample custom resource\n")
		fmt.Fprintf(os.Stderr, "  post-upgrade           Clean up ghost containers and stale deployments after upgrade\n")
		fmt.Fprintf(os.Stderr, "  fix-helm-orphans       Annotate orphaned resources so Helm can adopt them on install\n")
		fmt.Fprintf(os.Stderr, "  healthz <file>         Exit 0 if file exists (readiness probe)\n")
		os.Exit(1)
	}

	var err error
	switch os.Args[1] {
	case "reconcile-kubeconfig":
		err = runReconcileKubeconfig()
	case "reconcile-apiservice":
		err = runReconcileAPIService()
	case "delete-apiservice":
		err = runDeleteAPIService()
	case "test-apiservice":
		err = runTestAPIService()
	case "test-connection":
		err = runTestConnection()
	case "test-setup":
		err = runTestSetup()
	case "wait-for-resource":
		err = runWaitForResource()
	case "example-test":
		err = runExampleTest()
	case "post-upgrade":
		err = runPostUpgrade()
	case "fix-helm-orphans":
		err = runFixHelmOrphans()
	case "healthz":
		// Readiness probe: exit 0 if the given file exists, 1 otherwise.
		// Replaces "cat <file>" which requires a shell — unavailable in distroless.
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: konk-service healthz <file>\n")
			os.Exit(1)
		}
		if _, statErr := os.Stat(os.Args[2]); statErr != nil {
			os.Exit(1)
		}
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}

	if err != nil {
		log.Fatalf("Command %s failed: %v", os.Args[1], err)
	}
}

func mustEnv(key string) string {
	val := os.Getenv(key)
	if val == "" {
		log.Fatalf("Required environment variable %s is not set", key)
	}
	return val
}
