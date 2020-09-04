#!/bin/bash -xe

kubeadm init phase certs all
kubeadm init phase kubeconfig admin
if ! kubectl -n {{ .Release.Namespace }} get secret {{ include "konk.fullname" . }}-etcd-cert
then
  kubectl -n {{ .Release.Namespace }} create secret generic {{ include "konk.fullname" . }}-etcd-cert --from-file=/etc/kubernetes/pki/etcd/ca.crt --from-file=/etc/kubernetes/pki/etcd/server.crt --from-file=/etc/kubernetes/pki/etcd/server.key
fi
if ! kubectl -n {{ .Release.Namespace }} get secret {{ include "konk.fullname" . }}-apiserver-cert
then
  kubectl -n {{ .Release.Namespace }} create secret generic {{ include "konk.fullname" . }}-apiserver-cert --from-file=/etc/kubernetes/pki/etcd/ca.crt --from-file=/etc/kubernetes/pki/apiserver-etcd-client.crt --from-file=/etc/kubernetes/pki/apiserver-etcd-client.key
fi
if ! kubectl -n {{ .Release.Namespace }} get secret {{ include "konk.fullname" . }}-kubeconfig
then
  kubectl -n {{ .Release.Namespace }} create secret generic {{ include "konk.fullname" . }}-kubeconfig --from-file=/etc/kubernetes/admin.conf
fi
