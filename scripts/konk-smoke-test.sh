#!/bin/bash -x

cd $(dirname $BASH_SOURCE)

function cleanup {
  kubectl -n konk-test delete -f ../examples/konk.yaml
}

trap cleanup EXIT

kubectl create ns konk-test || true
kubectl -n konk-test apply -f ../examples/konk.yaml

kubectl wait --timeout=1s --for=condition=Deployed -n konk-test konk runner-konk

REASON=$(kubectl -n konk-test get konk runner-konk -o jsonpath="{range.status.conditions[?(@.type=='Deployed')]}{$@.type}={@.reason}{'\n'}{end}")

if [[ $REASON != *"InstallSuccessful" ]]; then
  echo Issue with installation: $REASON
fi

helm -n konk-test test --logs runner-konk
