



//go:generate openapi-gen-o . --output-package ../../pkg/openapi --report-filename violations.report -i ../../pkg/apis/...,../../vendor/k8s.io/api/core/v1,../../vendor/k8s.io/apimachinery/pkg/apis/meta/v1 -h ../../boilerplate.go.txt
package openapi

