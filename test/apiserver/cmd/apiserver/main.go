package main

import (
	// Make sure dep tools picks up these dependencies
	_ "github.com/go-openapi/loads"
	_ "k8s.io/apimachinery/pkg/apis/meta/v1"

	_ "k8s.io/client-go/plugin/pkg/client/auth" // Enable cloud provider auth
	"sigs.k8s.io/apiserver-builder-alpha/pkg/cmd/server"

	"github.com/infobloxopen/konk/test/apiserver/pkg/apis"
	"github.com/infobloxopen/konk/test/apiserver/pkg/openapi"
	// _ "github.com/infobloxopen/konk/test/apiserver/plugin/admission/install"
)

func main() {
	version := "v0"

	err := server.StartApiServerWithOptions(&server.StartOptions{
		EtcdPath:    "/registry/infoblox.com",
		Apis:        apis.GetAllApiBuilders(),
		Openapidefs: openapi.GetOpenAPIDefinitions,
		Title:       "Api",
		Version:     version,

		// TweakConfigFuncs []func(apiServer *apiserver.Config) error
		// FlagConfigFuncs []func(*cobra.Command) error
	})
	if err != nil {
		panic(err)
	}
}
