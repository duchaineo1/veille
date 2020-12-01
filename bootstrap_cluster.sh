#!/bin/bash

CONTROLLER_IPS=()
WORKER_IPS=()
CLUSTER_IP=""
echo '[STEP 1 - Install packages]'
apt-get update && apt-get upgrade -y && apt-get install -y lxd lxc-utils curl


echo '[STEP 2 - LXD config]'
lxd init --auto
lxc network create mynet ipv6.address=none ipv4.address=10.10.10.1/24 ipv4.nat=true
lxc profile create k8s
cat k8s_profile.yaml | lxc profile edit k8s


echo '[STEP 3 - Container config]'

for instance in worker-0 worker-1 worker-2
do
	lxc launch ubuntu:18.04 ${instance} --profile k8s
	sleep 10
	#lxc stop ${instance}
	#sleep 10
	#lxc network attach mynet ${instance} eth0
	#lxc start ${instance}
	#sleep 5 
	lxc list
	
done;

sleep 30

for instance in worker-0 worker-1 worker-2
do
	WORKER_IPS+=$(lxc list | grep ${instance} | awk '{print $6}') && WORKER_IPS+=' '
done;

for instance in controller-0 controller-1 controller-2
do
        lxc launch ubuntu:18.04 ${instance} --profile k8s
        sleep 10
        #lxc stop ${instance}
        #sleep 10
        #lxc network attach mynet ${instance} eth0
        #lxc start ${instance}
	#sleep 5 
	lxc list
done;

sleep 30

for instance in controller-0 controller-1 controller-2
do
        CONTROLLER_IPS+=$(lxc list | grep ${instance} | awk '{print $6}') && CONTROLLER_IPS+=' '
done;

lxc launch images:centos/7 haproxy
sleep 10
#lxc stop haproxy
#sleep 10
#lxc network attach mynet haproxy eth0 
#lxc start haproxy
#sleep 20
CLUSTER_IP=$(lxc list | grep haproxy | awk '{print $6}')
echo 'Cluster IP :' ${CLUSTER_IP}
echo 'Workers IP :' ${WORKER_IPS}
echo 'Controller IP :' ${CONTROLLER_IPS}

echo '[STEP 4 - haproxy config and client tools install on host]'

lxc exec haproxy -- yum install -y haproxy

controller0_ip=$(echo $CONTROLLER_IPS | awk '{print $1}')
controller1_ip=$(echo $CONTROLLER_IPS | awk '{print $2}')
controller2_ip=$(echo $CONTROLLER_IPS | awk '{print $3}')

export controller0_ip controller1_ip controller2_ip CLUSTER_IP
envsubst < haproxy_template.cfg > haproxy.cfg
lxc file push haproxy.cfg haproxy/etc/haproxy/haproxy.cfg
lxc exec haproxy -- systemctl enable haproxy
lxc exec haproxy -- systemctl start haproxy


wget -q --show-progress --https-only --timestamping \
  https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/linux/cfssl \
  https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/linux/cfssljson

chmod +x cfssl cfssljson
sudo mv cfssl cfssljson /usr/local/bin/

wget https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kubectl
chmod +x kubectl
sudo mv kubectl /usr/local/bin/


echo '[STEP 5 - CA and TLS certificates]'

# CERTIFICATE AUTHORITY
{

cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat > ca-csr.json <<EOF
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

}
# CLIENT AND SERVER CERTIFICATE
{

cat > admin-csr.json <<EOF
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:masters",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  admin-csr.json | cfssljson -bare admin

}

# KUBELET client certificates
for instance in worker-0 worker-1 worker-2; do
cat > ${instance}-csr.json <<EOF
{
  "CN": "system:node:${instance}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

EXTERNAL_IP=$(lxc info ${instance} | grep eth0 | head -1 | awk '{print $3}')

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=${instance},${EXTERNAL_IP}, \
  -profile=kubernetes \
  ${instance}-csr.json | cfssljson -bare ${instance}
done

# Controller manager client certificate 

{

cat > kube-controller-manager-csr.json <<EOF
{
  "CN": "system:kube-controller-manager",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-controller-manager",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager

}

# Kube proxy 

{

cat > kube-proxy-csr.json <<EOF
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:node-proxier",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-proxy-csr.json | cfssljson -bare kube-proxy

}

# Scheduler client certificate

{

cat > kube-scheduler-csr.json <<EOF
{
  "CN": "system:kube-scheduler",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-scheduler",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-scheduler-csr.json | cfssljson -bare kube-scheduler

}

# Api certificate

{

KUBERNETES_PUBLIC_ADDRESS=${CLUSTER_IP}

KUBERNETES_HOSTNAMES=kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.svc.cluster.local

cat > kubernetes-csr.json <<EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=${controller0_ip},${controller1_ip},${controller2_ip},${KUBERNETES_PUBLIC_ADDRESS},127.0.0.1,${KUBERNETES_HOSTNAMES} \
  -profile=kubernetes \
  kubernetes-csr.json | cfssljson -bare kubernetes

}
# Service account key pair 

{

cat > service-account-csr.json <<EOF
{
  "CN": "service-accounts",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  service-account-csr.json | cfssljson -bare service-account

}

for instance in worker-0 worker-1 worker-2; do
  lxc file push ca.pem ${instance}-key.pem ${instance}.pem ${instance}/root/
done

for instance in controller-0 controller-1 controller-2; do
  lxc file push ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem \
    service-account-key.pem service-account.pem ${instance}/root/
done

echo '[STEP 6 - generating Kubernetes config files]'

KUBERNETES_PUBLIC_ADDRESS=${CLUSTER_IP}
# worker0 kubeconfig
for instance in worker-0 worker-1 worker-2; do
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-credentials system:node:${instance} \
    --client-certificate=${instance}.pem \
    --client-key=${instance}-key.pem \
    --embed-certs=true \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:node:${instance} \
    --kubeconfig=${instance}.kubeconfig

  kubectl config use-context default --kubeconfig=${instance}.kubeconfig
done
# kube-proxy.kubeconfig
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-credentials system:kube-proxy \
    --client-certificate=kube-proxy.pem \
    --client-key=kube-proxy-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-proxy \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
}
# kube-controller-manager.kubeconfig
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-credentials system:kube-controller-manager \
    --client-certificate=kube-controller-manager.pem \
    --client-key=kube-controller-manager-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-controller-manager \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig
}
# kube-scheduler.kubeconfig
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-credentials system:kube-scheduler \
    --client-certificate=kube-scheduler.pem \
    --client-key=kube-scheduler-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-scheduler \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig
}
# admin.kubeconfig
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=admin.kubeconfig

  kubectl config set-credentials admin \
    --client-certificate=admin.pem \
    --client-key=admin-key.pem \
    --embed-certs=true \
    --kubeconfig=admin.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=admin \
    --kubeconfig=admin.kubeconfig

  kubectl config use-context default --kubeconfig=admin.kubeconfig
}

for instance in worker-0 worker-1 worker-2; do
  lxc file push ${instance}.kubeconfig kube-proxy.kubeconfig ${instance}/root/
done

for instance in controller-0 controller-1 controller-2; do
  lxc file push admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig ${instance}/root/
done

echo '[STEP 7 - Encryption key]'

ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

for instance in controller-0 controller-1 controller-2; do
  lxc file push encryption-config.yaml ${instance}/root/
done

echo '[STEP 8 - etcd service]'


for instance in controller-0 controller-1 controller-2; do 
	INTERNAL_IP=$(lxc info ${instance} | grep eth0 | awk '{print $3}' | head -n 1)
	ETCD_NAME=$(lxc info ${instance} | grep Name: | awk '{print $2}')
	lxc exec ${instance} -- wget -q --show-progress --https-only --timestamping \
  "https://github.com/etcd-io/etcd/releases/download/v3.4.10/etcd-v3.4.10-linux-amd64.tar.gz"
	lxc exec ${instance} -- tar -xvf etcd-v3.4.10-linux-amd64.tar.gz
	lxc exec ${instance} -- mv etcd-v3.4.10-linux-amd64/etcd /usr/local/bin/
	lxc exec ${instance} -- mv etcd-v3.4.10-linux-amd64/etcdctl /usr/local/bin/
	lxc exec ${instance} -- mkdir -p /etc/etcd /var/lib/etcd
	lxc exec ${instance} -- chmod 700 /var/lib/etcd
	lxc exec ${instance} -- cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/
	export controller0_ip controller1_ip controller2_ip INTERNAL_IP
	envsubst < etcd.service_template.cfg > etcd.service
	lxc file push etcd.service ${instance}/etc/systemd/system/etcd.service
	lxc exec ${instance} -- systemctl daemon-reload
	lxc exec ${instance} -- systemctl enable etcd
  	lxc exec ${instance} -- systemctl start etcd
done

echo '[STEP 8 - Bootstrapping controller nodes]'

for instance in controller-0 controller-1 controller-2; do 
	INTERNAL_IP=$(lxc info ${instance} | grep eth0 | awk '{print $3}' | head -n 1)
	lxc exec ${instance} -- mkdir -p /etc/kubernetes/config
	lxc exec ${instance} -- wget -q --show-progress --https-only --timestamping \
	  "https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kube-apiserver" \
	  "https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kube-controller-manager" \
	  "https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kube-scheduler" \
	  "https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kubectl"
	lxc exec ${instance} -- chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
  	lxc exec ${instance} -- mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
	lxc exec ${instance} -- mkdir -p /var/lib/kubernetes/
	lxc exec ${instance} -- mv ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem service-account-key.pem service-account.pem encryption-config.yaml /var/lib/kubernetes/
	export controller0_ip controller1_ip controller2_ip INTERNAL_IP
	envsubst < kube-apiserver.service_template > kube-apiserver.service
	lxc file push kube-apiserver.service ${instance}/etc/systemd/system/kube-apiserver.service
	lxc file push kube-controller-manager.service ${instance}/etc/systemd/system/kube-controller-manager.service
	lxc exec ${instance} -- mv kube-scheduler.kubeconfig /var/lib/kubernetes/
	lxc file push kube-scheduler.yaml ${instance}/etc/kubernetes/config/kube-scheduler.yaml
	lxc file push /etc/systemd/system/kube-scheduler.service ${instance}/etc/systemd/system/kube-scheduler.service
	lxc exec ${instance} -- systemctl daemon-reload && systemctl enable kube-apiserver kube-controller-manager kube-scheduler && systemctl start kube-apiserver kube-controller-manager kube-scheduler	
done
