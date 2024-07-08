#!/bin/bash
set -xe

secret_not_found () {
  output=$(kubectl -n ${2:-$NAMESPACE} get secret $1 --ignore-not-found)
  echo "$output"
  [ "$output" = "" ]
}

# load existing CA
if ! secret_not_found $FULLNAME-ca
then
  mkdir -p /etc/kubernetes/pki
  for ext in crt key
  do
    kubectl -n $NAMESPACE get secret $FULLNAME-ca -o 'go-template={{index .data "tls.'$ext'"}}' | base64 --decode > /etc/kubernetes/pki/ca.$ext
  done
fi
if ! secret_not_found $FULLNAME-etcd-ca
then
  mkdir -p /etc/kubernetes/pki/etcd
  for ext in crt key
  do
    kubectl -n $NAMESPACE get secret $FULLNAME-etcd-ca -o 'go-template={{index .data "tls.'$ext'"}}' | base64 --decode > /etc/kubernetes/pki/etcd/ca.$ext
  done
fi

cat << EOF > /tmp/kubeadmcfg.yaml
apiVersion: "kubeadm.k8s.io/v1beta2"
kind: ClusterConfiguration
etcd:
  local:
    serverCertSANs:
    - localhost
    - $RELEASE-etcd-headless
EOF

kubeadm init phase certs all --apiserver-cert-extra-sans $FULLNAME,$FULLNAME.$NAMESPACE,$FULLNAME.$NAMESPACE.svc,$FULLNAME.$NAMESPACE.svc.cluster.local
rm -f /etc/kubernetes/pki/etcd/server*
kubeadm init phase certs etcd-server --config=/tmp/kubeadmcfg.yaml
kubeadm init phase kubeconfig admin --control-plane-endpoint $FULLNAME.$NAMESPACE.svc
find /etc/kubernetes/pki

if secret_not_found $FULLNAME-ca
then
  kubectl -n $NAMESPACE create secret tls $FULLNAME-ca \
    --cert=/etc/kubernetes/pki/ca.crt \
    --key=/etc/kubernetes/pki/ca.key
  kubectl -n $NAMESPACE label secret $FULLNAME-ca $LABELS
fi
if secret_not_found $FULLNAME-etcd-ca
then
  kubectl -n $NAMESPACE create secret tls $FULLNAME-etcd-ca \
    --cert=/etc/kubernetes/pki/etcd/ca.crt \
    --key=/etc/kubernetes/pki/etcd/ca.key
  kubectl -n $NAMESPACE label secret $FULLNAME-etcd-ca $LABELS
fi

if [ "$SCOPE" = "cluster" ]
then
  if secret_not_found $FULLNAME-ca $CERT_MANAGER_NAMESPACE
  then
    kubectl -n $CERT_MANAGER_NAMESPACE create secret tls $FULLNAME-ca \
      --cert=/etc/kubernetes/pki/ca.crt \
      --key=/etc/kubernetes/pki/ca.key
    kubectl -n $CERT_MANAGER_NAMESPACE label secret $FULLNAME-ca $LABELS
  else
    kubectl -n $CERT_MANAGER_NAMESPACE patch secret $FULLNAME-ca --type=json -p '[
      {"op":"replace","path":"/data/tls.crt","value":"'"$(base64 --wrap=0 < /etc/kubernetes/pki/ca.crt)"'"},
      {"op":"replace","path":"/data/tls.key","value":"'"$(base64 --wrap=0 < /etc/kubernetes/pki/ca.key)"'"},
    ]'
  fi
fi

if secret_not_found $FULLNAME-kubeconfig
then
  kubectl -n $NAMESPACE create secret generic $FULLNAME-kubeconfig \
    --from-file=/etc/kubernetes/admin.conf
  kubectl -n $NAMESPACE label secret $FULLNAME-kubeconfig $LABELS
fi

kubectl -n $NAMESPACE wait --timeout=3m --for=condition=progressing deployments.apps -l app.kubernetes.io/instance=$RELEASE

DEPLOYMENT_UID=$(kubectl get deployments.apps -n $NAMESPACE $FULLNAME -o jsonpath='{.metadata.uid}')
for name in $FULLNAME-apiserver-cert $FULLNAME-ca $FULLNAME-etcd-ca $FULLNAME-kubeconfig
do
  kubectl patch -n $NAMESPACE secret $name -p '{"metadata":{"ownerReferences":[{"apiVersion":"apps/v1", "kind":"Deployment", "name":"'${FULLNAME}'", "uid":"'${DEPLOYMENT_UID}'"}]}}'
done
