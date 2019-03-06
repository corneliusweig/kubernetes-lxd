# kubernetes-lxd
A step-by-step guide to get [rancher/k3s](https://github.com/rancher/k3s) running inside an LXC container.

This guide is an alternative to minikube which also offers a local kubernetes environment.
The advantage of the LXC approach is that everything runs natively on the host kernel without any virtualization costs from a Virtual Machine.
For example, minikube causes such high CPU usage on the host (see [minikube issue #3207](https://github.com/kubernetes/minikube/issues/3207)), that development is impaired.
The downside is more setup work to get the kubernetes environment running, its administration costs, and lower isolation of the kubernetes cluster.

Below, you find a step-by-step guide to setup an LXC container and install [rancher/k3s](https://github.com/rancher/k3s) on it.

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

       root:1000000:1000000000
       <youruserid>:1000000:1000000000

   Run `systemctl restart lxd` to have LXD detect your new maps.

1. As the base system for our kubernetes we will use Debian and call the lxc machine `k3s-lxc`. Now create your kubernetes host machine with

       lxc launch images:debian/10 k3s-lxc

   Run `lxc list` to ensure that your machine `k3s-lxc` is up and running.

   Note: To get an overview over the supported base images, run

       lxc image list images:


2. Usual lxc containers are quite restricted in their capabilities.
   Because k3s needs to set up nested containers, it is required to give the lxc container the capabilities to manage networking configuration and create cgroups.
   For that, run `lxc config edit k3s-lxc` and merge in the following settings:
	```yaml
	config:
	  linux.kernel_modules: ip_tables,ip6_tables,netlink_diag,nf_nat,overlay
	  raw.lxc: lxc.mount.auto=proc:rw sys:rw
	  security.privileged: "true"
	  security.nesting: "true"
	```
   - `kernel_modules`: depending on the kernel of your host system, you need to add further kernel modules here. The ones listed above are for networking and for dockers overlay filesystem.
   - `raw.lxc`: this configures lxc to make container configuration inside the lxc container possible.
   - `security.privileged` and `security.nesting`: for a privileged container which may create nested cgroups


## Installing rancher/k3s in the lxc container
Below, some commands will need to be executed inside the lxc container and others on the host.
- **$**-prefix means to be executed on the host machine.
- **@**-prefix means to be executed inside the lxc container.
  To enter the container as root, do `$ lxc exec k3s-lxc /bin/bash`.
- no prefix means it does not matter where the command is executed.

1. On your host, ensure that `$ conntrack -L` produces some output (this means it works).
   If this requires additional kernel modules to be loaded, add those to the lxc container config.
   For example you might need to add in `$ lxc config edit k3s-lxc`
   ```yaml
   config:
     linux.kernel_modules: xt_conntrack,...
   ```
2. Pull `k3s` on your host system, and push it into the container:
   ```bash
   $ curl -Lo k3s https://github.com/rancher/k3s/releases/download/v0.2.0/k3s
   $ chmod +x k3s
   $ lxc file push k3s k3s-lxc/usr/local/bin/k3s
   ```

2. Install `ca-certificates` in k3s-lxc.
   ```bash
   @ apt-get install -y ca-certificates
   ```
   If you skip this, image pulling will not work due to certificate validation errors.

3. Restart your lxc container with
   ```bash
   lxc restart k3s-lxc
   ```
   If this does not work, try the hard way
   ```bash
   lxc exec k3s-lxc reboot
   ```

3. Now it is time to try out if `k3s` runs in your container:
   ```bash
   @ k3s server
   ```
   Congratulations, if the last command worked, you now have k3s/kubernetes running in your lxc container.

   If this isn't working, you need to trouble-shoot. Then stop `k3s` (Ctrl+C).

4. Automatically start `k3s` when the container starts. Run
   ```
   @ systemctl edit --force --full k3s.service
   ```
   and paste the the content of the [`k3s` unit file](https://github.com/rancher/k3s/blob/master/k3s.service)
   Finally, enable the unit with
   ```
   @ systemctl enable k3s
   @ systemctl start k3s
   ```

## Configure the host for working with k3s-lxc

1. On your host machine, add a host entry to access your `k3s-lxc` container by DNS name.
   Find out the IP of your lxc container by running `$ lxc list k3s-lxc`.
   Add its IP in `/etc/hosts`
   ```/etc/hosts
   <k3s-lxc-ip>   k3s-lxc
   ```
   After that, it should be possible to ping the container with `ping k3s-lxc`.

2. Set up a kubectl context on your host system to talk to your `k3s` installation in the lxc container:
   ```bash
   $ lxc file pull k3s-lxc/etc/rancher/k3s/k3s.yaml .
   $ sed -i 's:localhost:k3s-lxc:;s:default:k3s-lxc:g' k3s.yaml
   $ KUBECONFIG=~/.kube/config:k3s.yaml kubectl config view --raw > config.tmp
   $ mv config.tmp ~/.kube/config
   $ kubectl config use-context k3s-lxc
   ```
   The third line does some magic to merge the rancher config into your existing `KUBECONFIG` file.

3. (Optional) Check if everything is running correctly by deploying a small test application
   ```bash
   kubectl apply -f src/test-app.yaml
   ```
   You should be able to access the application from your browser [http://k3s-lxc](http://k3s-lxc).

   If that does not work, try to access the test service from within your kubernetes network.
   ```bash
   $ kubectl run --generator=run-pod/v1 -ti --image nicolaka/netshoot curl
   > curl test # should fetch a minimal greeting
   Ctrl-D
   $ kubectl delete pod curl
   ```

## Useful command for working with your LXC container

- Start your lxc container with `lxc start k3s-lxc`
- Show your running container with its IP `lxc list`
- Open a privileged shell in your container with `lxc exec k3s-lxc /bin/bash`

