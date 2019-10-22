#!/bin/sh
# Linux Deploy Component
# (c) Anton Skshidlevsky <meefik@gmail.com>, GPLv3

[ -n "${SUITE}" ] || SUITE="30"

if [ -z "${ARCH}" ]
then
    case "$(get_platform)" in
    x86) ARCH="i386" ;;
    x86_64) ARCH="x86_64" ;;
    arm) ARCH="armhfp" ;;
    arm_64) ARCH="aarch64" ;;
    esac
fi

[ -n "${SOURCE_PATH}" ] || SOURCE_PATH="http://dl.fedoraproject.org/pub/archive/"

dnf_install()
{
    local packages="$@"
    [ -n "${packages}" ] || return 1
    (set -e
        chroot_exec -u root dnf --nogpgcheck -y install ${packages}
        chroot_exec -u root dnf clean packages
    exit 0)
    return $?
}

yum_repository()
{
    find "${CHROOT_DIR}/etc/yum.repos.d/" -name '*.repo' | while read f; do sed -i 's/^enabled=.*/enabled=0/g' "${f}"; done
    local repo_file="${CHROOT_DIR}/etc/yum.repos.d/fedora-${SUITE}-${ARCH}.repo"
    local repo_url
    if [ "${ARCH}" = "i386" ]
    then repo_url="${SOURCE_PATH%/}/fedora-secondary/releases/${SUITE}/Everything/${ARCH}/os"
    else repo_url="${SOURCE_PATH%/}/fedora/linux/releases/${SUITE}/Everything/${ARCH}/os"
    fi
    echo "[fedora-${SUITE}-${ARCH}]" > "${repo_file}"
    echo "name=Fedora ${SUITE} - ${ARCH}" >> "${repo_file}"
    echo "failovermethod=priority" >> "${repo_file}"
    echo "baseurl=${repo_url}" >> "${repo_file}"
    echo "enabled=1" >> "${repo_file}"
    echo "metadata_expire=7d" >> "${repo_file}"
    echo "gpgcheck=0" >> "${repo_file}"
    chmod 644 "${repo_file}"
}

do_install()
{
    is_archive "${SOURCE_PATH}" && return 0

    msg ":: Installing ${COMPONENT} ... "

    local core_packages="acl alternatives audit-libs basesystem bash brotli bzip2-libs ca-certificates coreutils cracklib crypto-policies cryptsetup-libs curl cyrus-sasl-lib dbus dbus-tools dbus-broker dbus-common device-mapper device-mapper-libs dnf dnf-data dnf-yum elfutils-default-yama-scope elfutils-libelf elfutils-libs expat fedora-gpg-keys fedora-release fedora-release-container fedora-repos file-libs filesystem gawk gdbm-libs generic-release generic-release-common glib2 glibc glibc-common glibc-minimal-langpack gmp gnupg2 gnutls gpgme grep gzip ima-evm-utils iptables-libs json-c keyutils-libs kmod-libs krb5-libs libacl libarchive libargon2 libassuan libattr libblkid libcap libcap-ng libcom_err libcomps libcurl libcurl-minimal libdb libdb-utils libdnf libfdisk libffi libgcc libgcrypt libgomp libgpg-error libidn2 libksba libmetalink libmodulemd libmodulemd1 libmount libnghttp2 libnsl2 libpcap libpsl libpwquality librepo libreport-filesystem libseccomp libselinux libsemanage libsepol libsigsegv libsmartcols libsolv libssh libsss_idmap libsss_nss_idmap libstdc++ libtasn1 libtirpc libunistring libusbx libutempter libuuid libverto libxcrypt libxml2 libyaml libzstd lua-libs lz4-libs mpfr ncurses ncurses-base ncurses-libs nettle npth openldap openssl openssl-libs p11-kit p11-kit-trust pam pcre pcre2 popt publicsuffix-list-dafsa python3 python3-dnf python3-gpg python3-hawkey python3-libcomps python3-libdnf python3-libs python3-rpm python-pip-wheel python-setuptools-wheel qrencode-libs readline rootfiles rpm rpm-build-libs rpm-libs rpm-sign-libs sed setup shadow-utils sqlite-libs sssd-client sudo systemd systemd-libs systemd-pam systemd-rpm-macros tss2 tzdata util-linux vim-minimal xz-libs zchunk-libs zlib"

    local repo_url
    if [ "${ARCH}" = "i386" ]
    then repo_url="${SOURCE_PATH%/}/fedora-secondary/releases/${SUITE}/Everything/${ARCH}/os"
    else repo_url="${SOURCE_PATH%/}/fedora/linux/releases/${SUITE}/Everything/${ARCH}/os"
    fi

    msg -n "Preparing for deployment ... "
    tar xzf "${COMPONENT_DIR}/filesystem.tgz" -C "${CHROOT_DIR}"
    is_ok "fail" "done" || return 1

    msg -n "Retrieving packages list ... "
    local pkg_list="${CHROOT_DIR}/tmp/packages.list"
    (set -e
        repodata=$(wget -q -O - "${repo_url}/repodata/repomd.xml" | sed -n '/<location / s/^.*<location [^>]*href="\([^\"]*\-primary\.xml\.gz\)".*$/\1/p')
        [ -z "${repodata}" ] && exit 1
        wget -q -O - "${repo_url}/${repodata}" | gzip -dc | sed -n '/<location / s/^.*<location [^>]*href="\([^\"]*\)".*$/\1/p' > "${pkg_list}"
    exit 0)
    is_ok "fail" "done" || return 1

    msg "Retrieving packages: "
    local package i pkg_url pkg_file pkg_arch
    case "${ARCH}" in
    i386) pkg_arch="-e i686 -e noarch" ;;
    x86_64) pkg_arch="-e x86_64 -e noarch" ;;
    armhfp) pkg_arch="-e armv7hl -e noarch" ;;
    aarch64) pkg_arch="-e aarch64 -e noarch" ;;
    esac
    for package in ${core_packages}
    do
        msg -n "${package} ... "
        pkg_url=$(grep -e "^.*/${package}-[0-9r][0-9\.\-].*rpm$" "${pkg_list}" | grep -m1 ${pkg_arch})
        test "${pkg_url}"; is_ok "fail" || return 1
        pkg_file="${pkg_url##*/}"
        # download
        for i in 1 2 3
        do
            wget -q -c -O "${CHROOT_DIR}/tmp/${pkg_file}" "${repo_url}/${pkg_url}" && break
            sleep 30s
        done
        [ "${package}" = "filesystem" ] && { msg "done"; continue; }
        # unpack
        (cd "${CHROOT_DIR}"; rpm2cpio "./tmp/${pkg_file}" | cpio -idmu >/dev/null)
        is_ok "fail" "done" || return 1
    done

    component_exec core/emulator

    msg "Installing packages ... "
    chroot_exec /bin/rpm -i --force --nosignature --nodeps /tmp/*.rpm
    is_ok || return 1

    msg -n "Clearing cache ... "
    rm -rf "${CHROOT_DIR}"/tmp/*
    is_ok "skip" "done"

    component_exec core/mnt core/net

    # msg -n "Updating repository ... "
    # yum_repository
    # is_ok "fail" "done"

    msg -n "Setting up dnf excludes ... "
    chroot_exec /bin/echo "\nkernel* dosfstools e2fsprogs fuse-libs gnupg2-smime libss pinentry shared-mime-info trousers xkeyboard-config grubby glibc-langpack-en cracklib-dicts" > /etc/dnf/dnf.conf
    s_ok "fail" "done"

    msg "Installing minimal environment: "
    dnf_install @minimal-environment --exclude=kernel,dosfstools,e2fsprogs,fuse-libs,gnupg2-smime,libss,pinentry,shared-mime-info,trousers,xkeyboard-config,grubby,glibc-langpack-en,cracklib-dicts
    is_ok || return 1

    if [ -n "${EXTRA_PACKAGES}" ]; then
      msg "Installing extra packages: "
      dnf_install ${EXTRA_PACKAGES}
      is_ok || return 1
    fi

    msg -n "Cleaning up dnf cache ... "
    chroot_exec dnf clean all
    s_ok "fail" "done"

    return 0
}

do_help()
{
cat <<EOF
   --arch="${ARCH}"
     Architecture of Linux distribution, supported "armhfp", "aarch64", "i386" and "x86_64".

   --suite="${SUITE}"
     Version of Linux distribution, supported version "28".

   --source-path="${SOURCE_PATH}"
     Installation source, can specify address of the repository or path to the rootfs archive.

   --extra-packages="${EXTRA_PACKAGES}"
     List of optional installation packages, separated by spaces.

EOF
}
