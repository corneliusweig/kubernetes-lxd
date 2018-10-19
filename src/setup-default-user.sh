#!/bin/bash

echo References
echo https://sysdig.com/blog/kubernetes-security-rbac-tls/
echo https://kubernetes.io/docs/reference/access-authn-authz/rbac/#default-roles-and-role-bindings
echo

function die() {
   echo "$1"
   exit 1
}

KUBECTL=$(command -v kubectl)
[[ -z $KUBECTL ]] && die "you need to install kubectl"


echo -n 'Input cluster name for which to set up default-user (defaults to k8s-lxc)  '
read -r KUBE_CLUSTER
echo "Using ${KUBE_CLUSTER:=k8s-lxc}"

echo -n 'Input the username to set up (defaults to lxc-default-user)  '
read -r KUBE_USER

KUBE_CREDFOLDER=~/.kube/${KUBE_USER:=lxc-default-user}/

echo "Using ${KUBE_USER}"
echo "Saving credentials in ${KUBE_CREDFOLDER}"

echo -n "Continue? [y/n]  "
read YESNO
[[ $YESNO != 'y' ]] && die 'Quit'


mkdir -p $KUBE_CREDFOLDER
pushd $KUBE_CREDFOLDER || die "cannot change to directory ${KUBE_CREDFOLDER}"

[[ -f user.crt || -f user.key ]] && die "certificate and user key are already present"

# create a new key
openssl genrsa -out user.key 2048

# create a certificate signing request with subject 'default-user' (this will be the username as seen by the API server)
openssl req -new -key user.key -out user.csr -subj "/CN=default-user"

# create csr in k8s
cat <<-EOF | $KUBECTL create -f -
   apiVersion: certificates.k8s.io/v1beta1
   kind: CertificateSigningRequest
   metadata:
     name: default-user
   spec:
     groups:
     - system:authenticated
     request: $(base64 user.csr | tr -d '\n')
     usages:
     - digital signature
     - key encipherment
     - client auth
EOF

$KUBECTL certificate approve default-user
$KUBECTL get csr default-user -o jsonpath='{.status.certificate}' | base64 --decode > user.crt
$KUBECTL config set-credentials "$KUBE_USER" --client-certificate="$PWD/user.crt" --client-key="$PWD/user.key"
$KUBECTL config set-context "$KUBE_USER" --user="$KUBE_USER" --cluster "$KUBE_CLUSTER"

popd

cat <<-EOF | $KUBECTL create -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: default-user-edit
     namespace: default
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: ClusterRole
     name: edit
   subjects:
   - apiGroup: rbac.authorization.k8s.io
     kind: User
     name: default-user
     namespace: default
EOF

echo "Certificate installed and user set up with edit rights in the 'default' namespace"
