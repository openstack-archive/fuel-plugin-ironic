#!/bin/bash -ex

exec > /tmp/fuel-plugin-ironic.log

package_path=$(rpm -ql fuel-plugin-ironic-1.0 | head -n1)
deployment_scripts_path="${package_path}/deployment_scripts"

key_path="/var/lib/fuel/keys/ironic"
mkdir -p "${key_path}"
key_file="${key_path}/bootstrap.rsa"
if [ ! -f "${key_file}" ]; then
  ssh-keygen -b 2048 -t rsa -N '' -f "${key_file}" 2>&1
else
  echo "Key ${key_file} already exists"
fi

export BOOTSTRAP_IRONIC="yes"
export EXTRA_DEB_REPOS="deb http://127.0.0.1:8080/plugins/fuel-plugin-ironic-1.0/repositories/ubuntu /"
export DESTDIR="/var/www/nailgun/bootstrap/ironic"
export BOOTSTRAP_SSH_KEYS="${key_file}.pub"
export AGENT_PACKAGE_PATH="${package_path}/repositories/ubuntu"

mkdir -p "${DESTDIR}"
#${deployment_scripts_path}/fuel-bootstrap-image-builder/bin/fuel-bootstrap-image
chmod 755 -R "${DESTDIR}"
