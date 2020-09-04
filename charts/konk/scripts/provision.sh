kubeadm init phase certs all
kubeadm init phase kubeconfig admin
VAL=$(kubectl -n {{ .Release.Namespace }} get secret {{ include "konk.fullname" . }}-etcd-cert --ignore-not-found)
if [[ $VAL == "" ]]
then
  kubectl -n {{ .Release.Namespace }} create secret generic {{ include "konk.fullname" . }}-etcd-cert --from-file=/etc/kubernetes/pki/etcd/ca.crt --from-file=/etc/kubernetes/pki/etcd/server.crt --from-file=/etc/kubernetes/pki/etcd/server.key
fi
VAL=$(kubectl -n {{ .Release.Namespace }} get secret {{ include "konk.fullname" . }}-apiserver-cert --ignore-not-found)
if [[ $VAL == "" ]]
then
  kubectl -n {{ .Release.Namespace }} create secret generic {{ include "konk.fullname" . }}-apiserver-cert --from-file=/etc/kubernetes/pki/etcd/ca.crt --from-file=/etc/kubernetes/pki/apiserver-etcd-client.crt --from-file=/etc/kubernetes/pki/apiserver-etcd-client.key
fi
VAL=$(kubectl -n {{ .Release.Namespace }} get secret {{ include "konk.fullname" . }}-kubeconfig --ignore-not-found)
if [[ $VAL == "" ]]
then
  kubectl -n {{ .Release.Namespace }} create secret generic {{ include "konk.fullname" . }}-kubeconfig --from-file=/etc/kubernetes/admin.conf
fi
