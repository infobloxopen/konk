#!/bin/bash -xe

kubeadm init phase certs all
kubeadm init phase kubeconfig admin
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
    --from-file=/etc/kubernetes/pki/ca.crt \
    --from-file=etcd-ca.crt=/etc/kubernetes/pki/etcd/ca.crt \
    --from-file=/etc/kubernetes/pki/apiserver-etcd-client.crt \
    --from-file=/etc/kubernetes/pki/apiserver-etcd-client.key
  kubectl -n $NAMESPACE label secret $FULLNAME-apiserver-cert $LABELS
fi
if ! kubectl -n $NAMESPACE get secret $FULLNAME-kubeconfig
then
  kubectl -n $NAMESPACE create secret generic $FULLNAME-kubeconfig \
    --from-file=/etc/kubernetes/admin.conf
  kubectl -n $NAMESPACE label secret $FULLNAME-kubeconfig $LABELS
fi
