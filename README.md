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
  - Do you want to configure a new storage pool? (yes/no) [default=yes]: yes -> default location
  - Would you like to connect to a MAAS server? (yes/no) [default=no]:  
  - Would you like to create a new local network bridge? (yes/no) [default=yes]:
  - What should the new bridge be called? [default=lxdbr0]:             
  - What IPv4 address should be used? (CIDR subnet notation, “auto” or “none”) [default=auto]:
  - What IPv6 address should be used? (CIDR subnet notation, “auto” or “none”) [default=auto]:
  - Would you like LXD to be available over the network? (yes/no) [default=no]: no
  - Would you like stale cached images to be updated automatically? (yes/no) [default=yes]     
  - Would you like a YAML "lxd init" preseed to be printed? (yes/no) [default=no]:


## Starting your LXC container

0. Before you can fire up your lxc container, you have to make sure to create `/etc/subuid` and `/etc/subgid` with the following entries:

    root:1000000:1000000000
    <youruserid>:1000000:1000000000

1. As the base system for our kubernetes we will use Debian and call the lxc machine `k8s-lxc`. Now create your kubernetes host machine with

       lxc launch images:debian/stretch k8s-lxc

   Run `lxc list` to ensure that your machine `k8s-lxc` is up and running.

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

## Installing kubernetes in the lxc container
Below, some commands will need to be executed inside the lxc container and others on the host.
- **$**-prefix means to be executed on the host machine
- **@**-prefix means to be executed inside the lxc container

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

2. Install docker and kubernetes runtime in the lxc container.
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
3. Configure the kubelet in the lxc container:
   ```bash
   @ kubeadm init --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables
   @ kubeadm alpha phase addons all
   ```
   For the first command you need to ignore the `bridge-nf-call-iptables` check which you have done manually before.

4. Disable the software container network infrastructure, because it is not needed for a dev environment:
   ```bash
   @ sed -i 's/--network-plugin=cni //' /var/lib/kubelet/kubeadm-flags.env
   @ systemctl daemon-reload
   @ systemctl restart kubelet
   ```

5. (Optional) Reduce the replica count of the coreDNS service to 1.
   ```bash
   @ kubectl scale -n kube-system deployment --replicas 1 coredns
   ```

Congratulations, if the last command worked, you now have kubernetes running in your lxc container.

