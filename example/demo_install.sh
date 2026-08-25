#!/bin/bash
while getopts 'auh' opt; do
  case "$opt" in
    a)
      echo "Running in 'auto-install' mode"
      auto_install=true
      ;;
    u)
      echo "Rollback changes"
      rollback=true
      ;;
    h)
      echo "Usage: $(basename $0) [-a] [-h]\n\n  -a Enable installation of packages if needed\n  -h Show this help"
      exit 0
      ;;
  esac
done
shift "$(($OPTIND -1))"

(export DEBIAN_FRONTEND=noninteractive

echo "1. Check pre-requisite"
echo " 1.1. OS distribution"
cat /etc/lsb-release 2>/dev/null | grep -P 'DISTRIB_DESCRIPTION="Ubuntu 22\.04\.\d+ LTS"' \
|| echo "Install script in designed for Ubuntu 22.04.x LTS" && exit(1)

echo " 1.2. Gitlab-CE install from package"
apt -qq list gitlab-ce | grep '[installed]' \
|| [ -z "$auto_install" ] \
	&& apt install -y curl openssh-server ca-certificates tzdata perl postfix \
	&& curl https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash \
	&& apt install -y gitlab-ce \
	|| >&2 echo "Gitlab-CE not installed, aborting" && exit(1)

echo " 1.3. OpenResty from package"
apt -qq list openresty | grep '[installed]' \
|| [ -z "$auto_install" ] \
	&& apt install -y libpcre3-dev libssl-dev perl make build-essential curl \
	&& wget -O - https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg \
	&& apt update -y && apt install -y openresty \
	|| >&2 echo "OpenResty not installed, aborting" && exit(1)
)

echo "2. Copy file"
for file in $(find -type f ./src | grep -Po '^.(.*)'); then
	echo " 2.1. Backup if already exist"
	test -f "$file" && mv $file $file.bak
	echo " 2.2. Create directories and copy files"
	mkdir -p $(echo $file | grep -Po '^(.*)/') && cp ./src$file $file
done

echo "3. Apply configuration change"
echo " 3.1. Disable Gitlab Nginx"
sed -ri "s/#?\s*nginx\['enable'\] = true/nginx['enable'] = false/g" /etc/gitlab/gitlab.rb \
&& gitlab-ctl reconfigure

echo " 3.2. Check if SSL certificates are present otherwize create them"
test -f /etc/ssl/private/gitlab.crt \
&& test -f /etc/ssl/private/gitlab.key \
&& test -f /etc/ssl/private/root-ca.crt \
|| cd ./example && bash ./build_certs.sh \
	&& cp ./certs/gitlab.{crt,key} /etc/ssl/private/ \
	&& cat ./ca/*.crt > /etc/ssl/private/ca.crt \
	&& cd ..

echo "4. Restart services"
echo " 4.1. Start gitlab-ssl-auth service"
systemctl daemon reload && systemctl start gitlab-ssl-auth.service

echo " 4.2. Reload OpenResty"
openresty -t && openresty -s reload

echo "Demo installation done"