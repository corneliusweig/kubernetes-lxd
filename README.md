# kubernetes-lxd
A step-by-step guide to get kubernetes running inside an LXC container.

This guide is an alternative to minikube which also offers a local kubernetes environment.
The advantage of the LXC approach is that everything runs natively on the host kernel without any virtualization costs from a Virtual Machine.
For example, minikube causes such high CPU usage on the host (see [minikube issue #3207](https://github.com/kubernetes/minikube/issues/3207)), that development is impaired.
The downside is more setup work to get the kubernetes environment running, its administration costs, and lower isolation of the kubernetes cluster.

Below, you find a step-by-step guide to setup an LXC container and install kubernetes on it.

## Lxc installation

Lxc is similar to docker but aims more to be an OS container instead of just application containers.
To use it, install lxd and initialize it using `lxd init`. When prompted, answer the following questions:

  - Would you like to use LXD clustering? (yes/no) [default=no]:        
  - Do you want to configure a new storage pool? (yes/no) [default=yes]: yes -> **dir** (any directory based provider should work)
  - Would you like to connect to a MAAS server? (yes/no) [default=no]:  
  - Would you like to create a new local network bridge? (yes/no) [default=yes]:
  - What should the new bridge be called? [default=lxdbr0]:             
  - What IPv4 address should be used? (CIDR subnet notation, “auto” or “none”) [default=auto]:
  - What IPv6 address should be used? (CIDR subnet notation, “auto” or “none”) [default=auto]:
  - Would you like LXD to be available over the network? (yes/no) [default=no]: **no**
  - Would you like stale cached images to be updated automatically? (yes/no) [default=yes]     
  - Would you like a YAML "lxd init" preseed to be printed? (yes/no) [default=no]:


## Starting your LXC container

0. Before you can fire up your lxc container, you have to make sure to create `/etc/subuid` and `/etc/subgid` with the following entries:

       root:100000:1000000000
       <youruserid>:100000:1000000000

   Run `systemctl restart lxd` to have LXD detect your new maps.

1. As the base system for our kubernetes we will use Debian and call the lxc machine `k8s-lxc`. Now create your kubernetes host machine with

       lxc launch images:debian/stretch k8s-lxc

   Run `lxc list` to ensure that your machine `k8s-lxc` is up and running.

   Note: To get an overview over the supported base images, run

       lxc image list images:


2. Usual lxc containers are quite restricted in their capabilities.
   Because we need to run docker and kubernetes in the lxc container, it is required to give the container the capabilities to manage networking configuration and create cgroups.
   For that, run `lxc config edit k8s-lxc` and merge in the following settings:
	```yaml
	config:
	  linux.kernel_modules: ip_tables,ip6_tables,netlink_diag,nf_nat,overlay
	  raw.lxc: "lxc.apparmor.profile=unconfined\nlxc.cap.drop= \nlxc.cgroup.devices.allow=a\nlxc.mount.auto=proc:rw
	    sys:rw"
	  security.privileged: "true"
	  security.nesting: "true"
	```
   - `kernel_modules`: depending on the kernel of your host system, you need to add further kernel modules here. The ones listed above are for networking and for dockers overlay filesystem.
   - `raw.lxc`: this allows the lxc container to configure certain system resources.
   - `security.privileged` and `security.nesting`: for a privileged container which may create nested cgroups

3. Restart your lxc container. Unfortunately, `lxc stop k8s-lxc` does not work for me. I need to do `lxc exec k8s-lxc reboot`.

### Using docker and kubernetes on zfs backed host systems

If your host system is backed by ZFS storage (e.g. an option for Proxmox), some adaption need to be made. ZFS currently lacks full namespace support an thus a dataset cannot be reached into a LXC container retaining full control over the child datasets. The easiest solution is to create two volumes for `/var/lib/docker` and `/var/lib/kubelet` and format these ext4.

    zfs create -V 50G mypool/my-dockervol
    zfs create -V 5G mypool/my-kubeletvol
    mkfs.ext4 /dev/zvol/mypool/my-dockervol
    mkfs.ext4 /dev/zvol/mypool/my-kubeletvol
    
One then just needs to reach in the two volumes at the right location. The configuration for Proxmox looks like this:

    ...
    mp0: /dev/zvol/mypool/my-dockervol,mp=/var/lib/docker,backup=0
    mp1: /dev/zvol/mypool/my-kubeletvol,mp=/var/lib/kubelet,backup=0
    ...

## Installing kubernetes in the lxc container
Below, some commands will need to be executed inside the lxc container and others on the host.
- **$**-prefix means to be executed on the host machine
- **@**-prefix means to be executed inside the lxc container
- no prefix means it does not matter where the command is executed

1. First ensure on your host system that `$ cat /proc/sys/net/bridge/bridge-nf-call-iptables` returns 1.
   This is required by kubernetes but cannot be validated inside the lxc container.

   On your host, ensure that `$ conntrack -L` produces some output (this means it works).
   If this requires additional kernel modules to be loaded, add those to the lxc container config.
   For example you might need to add in `$ lxc config edit k8s-lxc`
   ```yaml
   config:
     linux.kernel_modules: xt_conntrack,...
   ```
   After that, verify that `@ conntrack` also works inside your lxc container.
   To enter your container as root, do `$ lxc exec k8s-lxc /bin/bash`.

2. Recent kubernetes versions want to read from `/dev/kmsg` which is not present in the container.
   You need to instruct systemd to always create a symlink to `/dev/console` instead:
   ```bash
   @ echo 'L /dev/kmsg - - - - /dev/console' > /etc/tmpfiles.d/kmsg.conf
   ```
   This solution can cause infinite CPU usage in some cases; some(?) versions of
   `systemd-journald` read from `/dev/kmsg` and write to `/dev/console`, and if
   they're symlinked together, this will cause an infinite loop. If this affects
   you, link `/dev/null` to `/dev/kmsg` instead:
   ```bash
   @ echo 'L /dev/kmsg - - - - /dev/null' > /etc/tmpfiles.d/kmsg.conf
   ```

3. Install docker and kubernetes runtime in the lxc container.
   The following commands add the required repositories, install kubernetes with dependencies, and pin the kubernetes & docker version:

   ```bash
   @ apt-get install apt-transport-https ca-certificates curl gnupg2 software-properties-common
   @ curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
   @ curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
   @ add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
   @ add-apt-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"
   @ apt-get update
   @ apt-get install -y docker-ce kubelet kubeadm kubectl
   @ apt-mark hold kubelet kubeadm kubectl docker-ce
   ```

4. Configure the kubelet in the lxc container:
   ```bash
   @ kubeadm init --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables
   @ kubeadm init phase addon all
   ```
   For the first command you need to ignore the `bridge-nf-call-iptables` check which you have done manually before.
   In case you obtain an error like `failed to parse kernel config` in the preflight check, copy your host kernel config to from `/boot` to your lxc-guest `/boot`.

5. Disable the software container network infrastructure, because it is not needed for a dev environment:
   ```bash
   @ sed -i 's/--network-plugin=cni //' /var/lib/kubelet/kubeadm-flags.env
   @ systemctl daemon-reload
   @ systemctl restart kubelet
   ```

6. (Optional) Reduce the replica count of the coreDNS service to 1.
   ```bash
   @ kubectl scale -n kube-system deployment --replicas 1 coredns
   ```

Congratulations, if the last command worked, you now have kubernetes running in your lxc container.

## Configure the host for working with k8s-lxc

1. On your host machine, add a host entry to access your `k8s-lxc` container by DNS name.
   Find out the IP of your lxc container by running `$ lxc list k8s-lxc`.
   Add its IP in `/etc/hosts`
   ```/etc/hosts
   <k8s-lxc-ip>   k8s-lxc
   ```
   After that, it should be possible to ping the container with `ping k8s-lxc`.

2. Make your docker daemon in the lxc cluster available from your host.
   There are two options.
   - **insecure** without authentication

     Open docker in the lxc container so that it can be accessed from outside. Run
     ```bash
     @ systemctl edit docker.service
     ```
     and add the following lines:
     ```systemd
     [Service]
     ExecStart=
     ExecStart=/usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:2376
     ```
     This is necessary, because the default unit definition also defines a host address, so that it cannot be overridden by the configuration file.

     Restart docker in the lxc container, so that the changes take effect. Run
     ```bash
     @ systemctl restart docker.service
     ```

     On your host machine, you can then talk to this docker daemon by setting the environment variable
     ```bash
     $ export DOCKER_HOST="tcp://k8s-lxc:2376"
     $ docker ps   # should show some kubernetes infrastructure containers
     ```

   - **secure** with authentication

      1. In your lxc container, change into folder `/etc/docker`.
         Follow the instructions from [docker.com](https://docs.docker.com/engine/security/https/) to set up server and client credentials.
      2. Then create a `/etc/docker/daemon.json` with the following content:
          ```json
          @ cat <<-EOF > /etc/docker/daemon.json
          {
             "tls": true,
             "tlscacert": "/etc/docker/ca.pem",
             "tlscert": "/etc/docker/server-cert.pem",
             "tlskey": "/etc/docker/server-key.pem",
             "hosts": ["fd://", "tcp://0.0.0.0:2376"]
          }
          EOF
          ```
      3. Edit your `docker.service` unit by running `@ systemctl edit docker.service` and add/change the following:
          ```systemd
          [Service]
          ExecStart=
          ExecStart=/usr/bin/dockerd
          ```
         This is necessary, because the default unit definition also defines a host address, so that it cannot be overridden by the configuration file.

      4. Pull the certificate and client keys to a config directory
         ```bash
         $ mkdir ~/.docker-lxc && cd ~/.docker-lxc
         $ lxc file pull k8s-lxc/etc/docker/ca.pem .
         $ lxc file pull k8s-lxc/etc/docker/cert.pem .
         $ lxc file pull k8s-lxc/etc/docker/key.pem .
         ```
         If you do not plan to use docker on your host as well, you can also use the default docker config directory `~/.docker/`.

      5. Set the following environment variables to access the docker daemon in the lxc cluster
         ```bash
         export DOCKER_TLS_VERIFY="1"
         export DOCKER_CERT_PATH="~/.docker-lxc/"
         export DOCKER_HOST="tcp://k8s-lxc:2376"
         export DOCKER_API_VERSION="1.37"
         ```
3. Set up a kubectl context on your host system to talk to your kubernetes installation in the lxc container:
   ```bash
   $ lxc file pull k8s-lxc/etc/kubernetes/admin.conf .
   $ KUBECONFIG=~/.kube/config:admin.conf kubectl config view --raw > config.tmp
   $ mv config.tmp ~/.kube/config
   $ kubectl config use-context k8s-lxc-admin@k8s-lxc
   ```
    The second line does some magic to merge the admin access credentials into the existing `KUBECONFIG` file.

4. Kubeadm usually taints the master node which prevents non-system pods from being scheduled.
   If this applies to you, do
   ```bash
   kubectl edit node
   ```
   and remove the taint.


## Kubernetes fine-tuning

1. If needed, configure an ingress controller for your kubernetes installation

   - Ensure that IP forwarding is enabled on your host
     ```bash
     sysctl net.ipv4.ip_forward
     ```
     or enable it permanently with
     ```bash
     sysctl -w net.ipv4.ip_forward=1
     ```

   - Create the ingress controller

     ```bash
     kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/mandatory.yaml
     ```

   - To access the ingress via the default http/https ports, add `hostPort` directives to its deployment template.
     Run `kubectl edit -n ingress-nginx deployment nginx-ingress-controller` and change the port definitions to
     ```yaml
     ports:
     - containerPort: 80
       hostPort: 80
       name: http
       protocol: TCP
     - containerPort: 443
       hostPort: 443
       name: https
       protocol: TCP
     ```

     Because we are skipping the `ingress-nginx` service, you should also remove `--publish-service=$(POD_NAMESPACE)/ingress-nginx`
     from the arguments to `nginx-ingress-controller`.


2. Disable leader election for control plane components, because this it is obsolete for a single node deployment.
   ```bash
   sed -i 's/--leader-elect=true/--leader-elect=false/' \
      /etc/kubernetes/manifests/{kube-controller-manager.yaml,kube-scheduler.yaml}
   ```

3. (Optional) Create an SSL certificate for your lxc container to secure traffic

   - Follow the instructions from [kubernetes.io](https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster/).
     Using the following commands:
   
     ```bash
     # prepare certificate signing request
     cat <<EOF | cfssl genkey - | cfssljson -bare server
     {
        "hosts": [
           "k8s-lxc"
        ],
        "CN": "k8s-lxc",
        "key": {
          "algo": "ecdsa",
          "size": 256
        }
     }
     EOF

     # create certificate signing request
     cat <<EOF | kubectl create -f -
     apiVersion: certificates.k8s.io/v1beta1
     kind: CertificateSigningRequest
     metadata:
       name: k8s-lxc-csr
     spec:
       groups:
       - system:authenticated
       request: $(cat server.csr | base64 | tr -d '\n')
       usages:
       - digital signature
       - key encipherment
       - server auth
     EOF

     # approve the certificate, using the k8s cluster ca.pem
     kubectl certificate approve k8s-lxc-csr

     # retrieve the server certificate
     kubectl get csr k8s-lxc-csr -o jsonpath='{.status.certificate}' \
         | base64 --decode > server.crt

     # create tls secret
     kubectl create secret tls k8s-lxc --cert=server.crt --key=server-key.pem
     ```
4. (Optional) Secure access to your cluster by creating a user with edit rights.
   Use the script `src/setup-default-user.sh` to set up authentication by client certificate for a user with name `default-user`.

5. Check if everything is running correctly by deploying a small test application
   ```bash
   kubectl apply -f src/test-k8s-lxc.yaml
   ```
   You should be able to access the application from your browser [http://k8s-lxc](http://k8s-lxc).

   If that does not work, try to access the test service from within your kubernetes network.
   ```bash
   $ kubectl run --generator=run-pod/v1 -ti --image nicolaka/netshoot curl
   > curl test # should fetch a minimal greeting
   Ctrl-D
   $ kubectl delete pod curl
   ```

## Useful command for working with your LXC container

- Start your lxc container with `lxc start k8s-lxc`
- Show your running container with its IP `lxc list`
- Open a privileged shell in your container with `lxc exec k8s-lxc /bin/bash`


## References
- https://blog.ubuntu.com/2017/02/20/running-kubernetes-inside-lxd
- https://medium.com/@kvapss/run-kubernetes-in-lxc-container-f04aa94b6c9c

You might also like [github.com/charmed-kubernetes/bundle/wiki/Deploying-on-LXD](https://github.com/charmed-kubernetes/bundle/wiki/Deploying-on-LXD)

