#!/bin/sh

set -eu

install_ssh_keys()
{
    if [ ! -f "${ssh_private_key_path}" ]; then
        # write public/private ssh key pair
        public_key_path="${ssh_private_key_path}.pub"

        # shellcheck disable=SC2174
        mkdir -m 0700 -p "${ssh_path}"
        touch "${public_key_path}" "${ssh_private_key_path}"
        chmod 0600 "${public_key_path}" "${ssh_private_key_path}"
        echo "${ssh_public_key}" > "${public_key_path}"
        echo "${ssh_private_key}" > "${ssh_private_key_path}"

        # add public key to authorized_keys
        authoried_keys_path="${HOME}/.ssh/authorized_keys"

        # the existing file is overwritten to avoid conflicts (ex: RHEL on EC2 blocks root login)
        cat "${public_key_path}" > "${authoried_keys_path}"
        chmod 0600 "${authoried_keys_path}"

        # add localhost's server keys to known_hosts
        known_hosts_path="${HOME}/.ssh/known_hosts"

        for key in /etc/ssh/ssh_host_*_key.pub; do
            echo "localhost $(cat "${key}")" >> "${known_hosts_path}"
        done
    fi
}

customize_bashrc()
{
    true > ~/.bashrc

    # Show color `ls` results when available.
    if ls --color > /dev/null 2>&1; then
        echo "alias ls='ls --color'" >> ~/.bashrc
    elif ls -G > /dev/null 2>&1; then
        echo "alias ls='ls -G'" >> ~/.bashrc
    fi

    # Improve shell prompts for interactive use.
    echo "export PS1='\[\e]0;\u@\h: \w\a\]\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '" >> ~/.bashrc
}

install_pip() {
    if ! "${python_interpreter}" -m pip.__main__ --version --disable-pip-version-check 2>/dev/null; then
        case "${python_version}" in
            *)
                pip_bootstrap_url="https://ansible-ci-files.s3.amazonaws.com/ansible-test/get-pip-20.3.4.py"
                ;;
        esac

        while true; do
            curl --silent --show-error "${pip_bootstrap_url}" -o /tmp/get-pip.py && \
            "${python_interpreter}" /tmp/get-pip.py --disable-pip-version-check --quiet && \
            rm /tmp/get-pip.py \
            && break
            echo "Failed to install packages. Sleeping before trying again..."
            sleep 10
        done
    fi
}

pip_install() {
    pip_packages="$1"

    while true; do
        # shellcheck disable=SC2086
        "${python_interpreter}" -m pip install --disable-pip-version-check ${pip_packages} \
        && break
        echo "Failed to install packages. Sleeping before trying again..."
        sleep 10
    done
}

bootstrap_remote_aix()
{
    chfs -a size=1G /
    chfs -a size=4G /usr
    chfs -a size=1G /var
    chfs -a size=1G /tmp
    chfs -a size=2G /opt

    if [ "${python_version}" = "2.7" ]; then
        python_package_version=""
    else
        python_package_version="3"
    fi

    packages="
        gcc
        python${python_package_version}
        python${python_package_version}-devel
        python${python_package_version}-pip
        "

    while true; do
        # shellcheck disable=SC2086
        yum install -q -y ${packages} \
        && break
        echo "Failed to install packages. Sleeping before trying again..."
        sleep 10
    done
}

bootstrap_remote_freebsd()
{
    if [ "${python_version}" = "2.7" ]; then
        # on Python 2.7 our only option is to use virtualenv
        virtualenv_pkg="py27-virtualenv"
    else
        # on Python 3.x we'll use the built-in venv instead
        virtualenv_pkg=""
    fi

    packages="
        python${python_package_version}
        ${virtualenv_pkg}
        bash
        curl
        gtar
        sudo
        "

    if [ "${controller}" ]; then
        # Declare platform/python version combinations which do not have supporting OS packages available.
        # For these combinations ansible-test will use pip to install the requirements instead.
        case "${platform_version}/${python_version}" in
            "11.4/3.8")
                have_os_packages=""
                ;;
            "12.2/3.8")
                have_os_packages=""
                ;;
            "13.0/3.8")
                have_os_packages=""
                ;;
            "13.0/3.9")
                have_os_packages=""
                ;;
            *)
                have_os_packages="yes"
                ;;
        esac

        # PyYAML is never installed with an OS package since it does not include libyaml support.
        # Instead, ansible-test will install it using pip.
        if [ "${have_os_packages}" ]; then
            jinja2_pkg="py${python_package_version}-Jinja2"
            cryptography_pkg="py${python_package_version}-cryptography"
        else
            jinja2_pkg=""
            cryptography_pkg=""
        fi

        packages="
            ${packages}
            libyaml
            ${jinja2_pkg}
            ${cryptography_pkg}
            "
    fi

    while true; do
        # shellcheck disable=SC2086
        env ASSUME_ALWAYS_YES=YES pkg bootstrap && \
        pkg install -q -y ${packages} \
        && break
        echo "Failed to install packages. Sleeping before trying again..."
        sleep 10
    done

    install_pip

    if ! grep '^PermitRootLogin yes$' /etc/ssh/sshd_config > /dev/null; then
        sed -i '' 's/^# *PermitRootLogin.*$/PermitRootLogin yes/;' /etc/ssh/sshd_config
        service sshd restart
    fi
}

bootstrap_remote_macos()
{
    # Silence macOS deprecation warning for bash.
    echo "export BASH_SILENCE_DEPRECATION_WARNING=1" >> ~/.bashrc

    # Make sure ~/ansible/ is the starting directory for interactive shells on the control node.
    # The root home directory is under a symlink. Without this the real path will be displayed instead.
    if [ "${controller}" ]; then
        echo "cd ~/ansible/" >> ~/.bashrc
    fi

    # Make sure commands like 'brew' can be found.
    # This affects users with the 'zsh' shell, as well as 'root' accessed using 'sudo' from a user with 'zsh' for a shell.
    # shellcheck disable=SC2016
    echo 'PATH="/usr/local/bin:$PATH"' > /etc/zshenv
}

bootstrap_remote_rhel_7()
{
    packages="
        gcc
        python-devel
        python-virtualenv
        "

    if [ "${controller}" ]; then
        packages="
            ${packages}
            python2-cryptography
            "
    fi

    while true; do
        # shellcheck disable=SC2086
        yum install -q -y ${packages} \
        && break
        echo "Failed to install packages. Sleeping before trying again..."
        sleep 10
    done

    install_pip
}

bootstrap_remote_rhel_8()
{
    if [ "${python_version}" = "3.6" ]; then
        py_pkg_prefix="python3"
    else
        py_pkg_prefix="python${python_package_version}"
    fi

    packages="
        gcc
        ${py_pkg_prefix}-devel
        "

    if [ "${controller}" ]; then
        packages="
            ${packages}
            ${py_pkg_prefix}-jinja2
            ${py_pkg_prefix}-cryptography
            "
    fi

    while true; do
        # shellcheck disable=SC2086
        yum module install -q -y "python${python_package_version}" && \
        yum install -q -y ${packages} \
        && break
        echo "Failed to install packages. Sleeping before trying again..."
        sleep 10
    done
}

bootstrap_remote_rhel()
{
    case "${platform_version}" in
        7.*) bootstrap_remote_rhel_7 ;;
        8.*) bootstrap_remote_rhel_8 ;;
    esac

    # pin packaging and pyparsing to match the downstream vendored versions
    pip_packages="
        packaging==20.4
        pyparsing==2.4.7
        "

    pip_install "${pip_packages}"
}

bootstrap_docker()
{
    # Required for newer mysql-server packages to install/upgrade on Ubuntu 16.04.
    rm -f /usr/sbin/policy-rc.d
}

bootstrap_remote()
{
    for python_version in ${python_versions}; do
        echo "Bootstrapping Python ${python_version}"

        python_interpreter="python${python_version}"
        python_package_version="$(echo "${python_version}" | tr -d '.')"

        case "${platform}" in
            "aix") bootstrap_remote_aix ;;
            "freebsd") bootstrap_remote_freebsd ;;
            "macos") bootstrap_remote_macos ;;
            "rhel") bootstrap_remote_rhel ;;
        esac
    done
}

bootstrap()
{
    ssh_path="${HOME}/.ssh"
    ssh_private_key_path="${ssh_path}/id_${ssh_key_type}"

    install_ssh_keys
    customize_bashrc

    case "${bootstrap_type}" in
        "docker") bootstrap_docker ;;
        "remote") bootstrap_remote ;;
    esac
}

# These variables will be templated before sending the script to the host.
# They are at the end of the script to maintain line numbers for debugging purposes.
bootstrap_type=#{bootstrap_type}
controller=#{controller}
platform=#{platform}
platform_version=#{platform_version}
python_versions=#{python_versions}
ssh_key_type=#{ssh_key_type}
ssh_private_key=#{ssh_private_key}
ssh_public_key=#{ssh_public_key}

bootstrap
