#!/bin/bash -x

cd $(dirname $BASH_SOURCE)

# ./apiserver-smoke-test.sh {TAG}

TAG=${1:-v0.0.1-69-g6d4186c}
RELEASE_NAME=apiserver

function cleanup {
  helm -n konk-test delete ${RELEASE_NAME}
}

trap cleanup EXIT

helm upgrade --debug -i --wait \
  --create-namespace \
  -n konk-test \
  ${RELEASE_NAME} \
  --set=konk.create==true \
  --set=image.tag=${TAG} \
  --set=ingress.enabled=false \
  ../helm-charts/example-apiserver

kubectl wait --timeout=1s --for=condition=Deployed \
  -n konk-test \
  konkservice \
  ${RELEASE_NAME}-api

REASON=$(kubectl -n konk-test get konkservice ${RELEASE_NAME}-api -o jsonpath="{range.status.conditions[?(@.type=='Deployed')]}{$@.type}={@.reason}{'\n'}{end}")

if [[ $REASON != *"Successful" ]]; then
  echo Issue with installation: $REASON
fi

helm -n konk-test test --logs ${RELEASE_NAME}-api
helm -n konk-test test --logs ${RELEASE_NAME}
