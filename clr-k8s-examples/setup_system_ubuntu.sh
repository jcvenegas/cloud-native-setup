#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

handle_error (){
	local exit_code="${?}"
	local line_number="${1:-}"
	echo "Failed at $line_number: ${BASH_COMMAND}"
	exit "${exit_code}"
}
trap 'handle_error $LINENO' ERR

install_k8s(){
	sudo bash -c "echo 'deb http://apt.kubernetes.io/ kubernetes-xenial-unstable main' | tee  /etc/apt/sources.list.d/kubernetes.list"
	curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

	sudo -E apt update
	# FIXME query kata version
	sudo -E apt install -y kubelet kubeadm kubectl

	sudo swapoff -a
	sudo modprobe br_netfilter
	echo '1' | sudo tee  /proc/sys/net/ipv4/ip_forward

}

install_containerd(){
	# FIXME query kata version
	VERSION="1.2.5"
	echo "Install Containerd ${VERSION}"
	# FIXME consider handle arch
	curl -OL https://storage.googleapis.com/cri-containerd-release/cri-containerd-${VERSION}.linux-amd64.tar.gz
	sudo tar -C / -xzf cri-containerd-${VERSION}.linux-amd64.tar.gz
	sudo systemctl restart containerd
}

# clear cloud native 
get_clear_cloud_native(){
	[ -d "cloud-native-setup" ] || git clone https://github.com/clearlinux/cloud-native-setup.git
	cd cloud-native-setup/clr-k8s-examples
	# update repository if already downloaded
	git pull || true
	# clean any problematic envioment releated with the stack
	./reset_stack.sh || true
	./create_stack.sh minimal
}

kata_deploy(){
	kubectl apply -f https://raw.githubusercontent.com/kata-containers/packaging/master/kata-deploy/kata-rbac.yaml
	kubectl apply -f https://raw.githubusercontent.com/kata-containers/packaging/master/kata-deploy/kata-deploy.yaml
	kubectl apply -f https://raw.githubusercontent.com/clearlinux/cloud-native-setup/master/clr-k8s-examples/8-kata/kata-qemu-runtimeClass.yaml
}

function print_usage_exit() {
	exit_code=${1:-0}
	cat <<EOT
Usage: $0 [subcommand]
Subcommands:
$(
for cmd in "${!command_handlers[@]}"; do
printf "\t%s:|\t%s\n" "${cmd}" "${command_help[${cmd}]:-Not-documented}"
done | sort | column -t -s "|"
)
EOT
	exit "${exit_code}"
}

install_img(){
	if command -v img; then
		return
	fi
	install_runc
	local IMG_SHA256="41aa98ab28be55ba3d383cb4e8f86dceac6d6e92102ee4410a6b43514f4da1fa"
	# Download and check the sha256sum.
	sudo -E curl -fSL "https://github.com/genuinetools/img/releases/download/v0.5.7/img-linux-amd64" -o "/usr/local/bin/img"
	echo "${IMG_SHA256}  /usr/local/bin/img" | sha256sum -c -
	sudo chmod a+x "/usr/local/bin/img"

	echo "img installed!"

}

install_runc(){
	if command -v runc; then
		return
	fi
	# Install runc
	local RUNC_VERSION=v1.0.0-rc8
	sudo -E curl -fSL -o "/usr/bin/runc" "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64"
	sudo chmod +x /usr/bin/runc
}

install_crio(){
	mkdir -p "/etc/cni/net.d/"

	sudo mkdir -p /etc/containers/
	sudo apt-get install -y libgpgme-dev
	install_img

	img pull  jcvenega/kata-cri-o:ubuntu-lts-latest
	rm -rf "$(pwd)/crio-rootfs"
	img unpack  --output "$(pwd)/crio-rootfs"  jcvenega/kata-cri-o:ubuntu-lts-latest
	(
	cd crio-rootfs/crio-rootfs/
	echo "Move crio to rootfs"
	tar cf - .  | sudo tar xvf -  -C /
	)
	# by defeault crio looks for this path
	if [ ! -x "/usr/bin/runc" ];then
		runc_path=$(command -v runc)
		sudo ln -sf "$runc_path" /usr/bin/runc
	fi
	sudo systemctl daemon-reload
	sudo systemctl restart crio
	sudo systemctl status crio
}

all(){

	runtime=${2:-none}
	install_k8s
	install_img
	case "${runtime}" in
		containerd)
			install_containerd
			;;
		crio)
			install_crio
			;;
		*)
			echo "No runtime provided using crio"
			install_crio
			;;
	esac

	get_clear_cloud_native
}


declare -A command_handlers
declare -A command_help
command_handlers[install-k8s]=install_k8s
command_help[install-k8s]="Install k8s"

command_handlers[get-clear-cloud-native]=get_clear_cloud_native
command_help[get_clear_cloud_native]="Get Clear Clould Native setup"

command_handlers[install-containerd]=install_containerd
command_help[install-containerd]="Install containerd"

command_handlers[install-crio]=install_crio
command_help[install-crio]="Install crio"

command_handlers[deploy-kata]=kata_deploy
command_help[deploy-kata]="deploy kata in runnning cluster using kata-deploy"

command_handlers[all]=all
command_help[deploy-kata]="Create a cluster with kata "

cmd_handler=${command_handlers[${1:-none}]:-unimplemented}
if [ "${cmd_handler}" != "unimplemented" ]; then
	"${cmd_handler}" $*
else
	print_usage_exit 1
fi
