#!/bin/bash
set -xe

kubeadm init phase certs all --apiserver-cert-extra-sans $FULLNAME,$FULLNAME.$NAMESPACE,$FULLNAME.$NAMESPACE.svc,$FULLNAME.$NAMESPACE.svc.cluster.local
kubeadm init phase kubeconfig admin --control-plane-endpoint $FULLNAME.$NAMESPACE.svc
find /etc/kubernetes/pki
if ! kubectl -n $NAMESPACE get secret $FULLNAME-etcd-cert
then
  kubectl -n $NAMESPACE create secret generic $FULLNAME-etcd-cert \
    --from-file=/etc/kubernetes/pki/etcd/ca.crt \
    --from-file=/etc/kubernetes/pki/etcd/server.crt \
    --from-file=/etc/kubernetes/pki/etcd/server.key
  kubectl -n $NAMESPACE label secret $FULLNAME-etcd-cert $LABELS
fi
if ! kubectl -n $NAMESPACE get secret $FULLNAME-apiserver-cert
then
  kubectl -n $NAMESPACE create secret generic $FULLNAME-apiserver-cert \
    --from-file=/etc/kubernetes/pki/apiserver.crt \
    --from-file=/etc/kubernetes/pki/apiserver.key \
    --from-file=/etc/kubernetes/pki/ca.crt \
    --from-file=etcd-ca.crt=/etc/kubernetes/pki/etcd/ca.crt \
    --from-file=/etc/kubernetes/pki/apiserver-etcd-client.crt \
    --from-file=/etc/kubernetes/pki/apiserver-etcd-client.key
  kubectl -n $NAMESPACE label secret $FULLNAME-apiserver-cert $LABELS
fi
if ! kubectl -n $NAMESPACE get secret $FULLNAME-ca
then
  kubectl -n $NAMESPACE create secret tls $FULLNAME-ca \
    --cert=/etc/kubernetes/pki/ca.crt \
    --key=/etc/kubernetes/pki/ca.key
  kubectl -n $NAMESPACE label secret $FULLNAME-ca $LABELS
fi

if ! kubectl -n $NAMESPACE get secret $FULLNAME-kubeconfig
then
  kubectl -n $NAMESPACE create secret generic $FULLNAME-kubeconfig \
    --from-file=/etc/kubernetes/admin.conf
  kubectl -n $NAMESPACE label secret $FULLNAME-kubeconfig $LABELS
fi

kubectl -n $NAMESPACE wait --timeout=3m --for=condition=progressing deployments.apps -l app.kubernetes.io/instance=$RELEASE

DEPLOYMENT_UID=$(kubectl get deployments.apps -n $NAMESPACE $FULLNAME -o jsonpath='{.metadata.uid}')
for name in $FULLNAME-apiserver-cert $FULLNAME-etcd-cert $FULLNAME-ca $FULLNAME-kubeconfig
do
  kubectl patch -n $NAMESPACE secret $name -p '{"metadata":{"ownerReferences":[{"apiVersion":"apps/v1", "kind":"Deployment", "name":"'${FULLNAME}'", "uid":"'${DEPLOYMENT_UID}'"}]}}'
done
