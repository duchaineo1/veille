#!/bin/bash

CONTROLLER_IPS=()
WORKER_IPS=()
CLUSTER_IP=""
echo '[STEP 1 - Install packages]'
apt-get update && apt-get upgrade -y && apt-get install -y lxd lxc-utils 


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
	lxc stop ${instance}
	sleep 10
	lxc list
	lxc network attach mynet ${instance} eth0
	lxc start ${instance}
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
        lxc stop ${instance}
        sleep 10
        lxc list
        lxc network attach mynet ${instance} eth0
        lxc start ${instance}
done;

sleep 30

for instance in controller-0 controller-1 controller-2
do
        CONTROLLER_IPS+=$(lxc list | grep ${instance} | awk '{print $6}') && CONTROLLER_IPS+=' '
done;

lxc launch images:centos/7 haproxy
sleep 10
lxc stop haproxy
sleep 10
lxc network attach mynet haproxy eth0 
lxc start haproxy
sleep 20
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


curl -o cfssl https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/darwin/cfssl
curl -o cfssljson https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/darwin/cfssljson

chmod +x cfssl cfssljson

sudo mv cfssl cfssljson /usr/local/bin/



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
