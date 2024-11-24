ARG BOOTSTRAP
FROM --platform=$BUILDPLATFORM {BOOTSTRAP:-alpine/latest} as fetcher

ARG MIRROR="https://distfiles.gentoo.org"
ARG ARCH="x86_64"
ARG BUILD="amd64-musl-llvm"
# yes I like musl, fuck you
ARG VERSION="latest"
ARG SIGNING_KEY="BB572E0E2D182910"

RUN <<-EOF
    die() {
        echo $1
        exit 1
    }

    # Adjust the ARCH variable to match gentoo's naming convention
    case ${ARCH} in
        x86_64)
            GEN_ARCH=amd64
            ;;

        riscv??)
            GEN_ARCH=riscv
            ;;

        aarch64)
            GEN_ARCH=arm64
            ;;

        *)
            GEN_ARCH=${ARCH}
            ;;
    esac
    echo "Using Gentoo ${GEN_ARCH} with profile: ${BUILD}"

    # Figure out latest version if needed
    if [[ "${VERSION}" == "latest" ]] ; then
        SOURCE="${MIRROR}/releases/${GEN_ARCH}/autobuilds/current-stage3-${PROFILE}"

        echo "Fetching ${SOURCE}/latest-stage3-${PROFILE}.txt..."
        wget -q "${SOURCE}/latest-stage3-${PROFILE}.txt" || die "Couldn't find archive!"
        gpg --verify "latest-stage3-${PROFILE}.txt"

        # From gentoo-docker-images sources
        ARCHIVE=$(sed -n '6p' "latest-stage3-${PROFILE}.txt" | cut -f 1 -d ' ')
    else
        SOURCE="${MIRROR}/releases/${GEN_ARCH}/autobuilds/${PROFILE}"
        ARCHIVE="stage3-${PROFILE}-${VERSION}.tar.xz"
    fi

    echo "Using ${ARCHIVE}"

    # acquire files and signatures
    echo "Fetching ${ARCHIVE}..."
    wget -q --show-progress --progress=bar:force "${SOURCE}/${ARCHIVE}" || die "Couldn't find archive!"

    echo "Fetching ${ARCHIVE}.CONTENTS.gz..."
    wget -q "${SOURCE}/${ARCHIVE}.CONTENTS.gz"

    echo "Fetching ${ARCHIVE}.DIGESTS..."
    wget -q "${SOURCE}/${ARCHIVE}.DIGESTS"

    echo "Fetching ${ARCHIVE}.sha256..."
    wget -q "${SOURCE}/${ARCHIVE}.sha256"

    echo "Fetching ${ARCHIVE}.asc..."
    wget -q "${SOURCE}/${ARCHIVE}.asc"

    
    # acquire signing key from gentoo keyserver (code from gentoo-docker-images sources)
    gpg --keyserver hkps://keys.gentoo.org --recv-keys ${SIGNING_KEY}
    
    # verify digists & signatures
    openssl dgst -r -sha512 "${ARCHIVE}"
    sha256sum --check "${ARCHIVE}.sha256"

    gpg --verify "${ARCHIVE}.asc" || die "Failed to verify!"
    gpg --verify "${ARCHIVE}.DIGESTS" || die "Failed to verify!"
    gpg --verify "${ARCHIVE}.sha256" || die "Failed to verify!"

    # extract stage3
    mkdir "/gentoo"
    tar xvpf "${ARCHIVE}" --xattrs-include='*.*' --numeric-owner -C "/gentoo"

    echo DONE!
EOF


FROM scratch AS builder

WORKDIR /
COPY --from fetcher /gentoo/ /

ARG PROFILE="default/linux/amd64/23.0/musl/llvm"

ADD make.conf /etc/portage/make.conf
RUN emerge-webrsync

RUN <<-EOF
    eselect profile set ${PROFILE}

    mkdir /gentoo
    export ROOT=/gentoo

    mkdir -m 777 /tmp/log
    export PORTAGE_LOGDIR=/tmp/log

    export MAKEOPTS="-j$(nproc)"
    export EMERGE_DEFAULT_OPTS="--jobs=$(expr `nproc` / 4)"

    USE="${USE} build" emerge -1 baselayout
    emerge -1 @system
EOF


FROM scratch as gentoo
WORKDIR /
COPY --from=builder /gentoo/ /

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]



FROM --platform=$BUILDPLATFORM gentoo AS builder2
ARG ARCH

WORKDIR /
ADD make.conf /etc/portage/make.conf
ADD qemu.use /etc/portage/package.use

VOLUME /var/cache/binpkgs

RUN emerge-webrsync
RUN MAKEOPTS="-j$(nproc)" emerge --jobs=$(expr `nproc` / 4) --quiet-build sys-apps/busybox
RUN MAKEOPTS="-j$(nproc)" emerge --jobs=$(expr `nproc` / 4) --quiet-build app-emulation/qemu


RUN <<-EOF
    mkdir "/images"
    cp /usr/bin/qemu-{x86_64,riscv32,riscv64,arm,aarch64} /images/
    cp `which busybox` /images/
EOF


FROM --platform=$BUILDPLATFORM gentoo as fetcher

ARG MIRROR="https://distfiles.gentoo.org"
ARG ARCH="x86_64"
ARG PROFILE="amd64-musl-llvm"
# yes I like musl, fuck you
ARG VERSION="latest"
ARG SIGNING_KEY="BB572E0E2D182910"

RUN <<-EOF
    die() {
        echo $1
        exit 1
    }

    # Adjust the ARCH variable to match gentoo's naming convention
    case ${ARCH} in
        x86_64)
            GEN_ARCH=amd64
            ;;

        riscv??)
            GEN_ARCH=riscv
            ;;

        aarch64)
            GEN_ARCH=arm64
            ;;

        *)
            GEN_ARCH=${ARCH}
            ;;
    esac
    echo "Using Gentoo ${GEN_ARCH} with profile: ${PROFILE}"

    # Figure out latest version if needed
    if [[ "${VERSION}" == "latest" ]] ; then
        SOURCE="${MIRROR}/releases/${GEN_ARCH}/autobuilds/current-stage3-${PROFILE}"

        echo "Fetching ${SOURCE}/latest-stage3-${PROFILE}.txt..."
        wget -q "${SOURCE}/latest-stage3-${PROFILE}.txt" || die "Couldn't find archive!"
        gpg --verify "latest-stage3-${PROFILE}.txt"

        # From gentoo-docker-images sources
        ARCHIVE=$(sed -n '6p' "latest-stage3-${PROFILE}.txt" | cut -f 1 -d ' ')
    else
        SOURCE="${MIRROR}/releases/${GEN_ARCH}/autobuilds/${PROFILE}"
        ARCHIVE="stage3-${PROFILE}-${VERSION}.tar.xz"
    fi

    echo "Using ${ARCHIVE}"

    # acquire files and signatures
    echo "Fetching ${ARCHIVE}..."
    wget -q --show-progress --progress=bar:force "${SOURCE}/${ARCHIVE}" || die "Couldn't find archive!"

    echo "Fetching ${ARCHIVE}.CONTENTS.gz..."
    wget -q "${SOURCE}/${ARCHIVE}.CONTENTS.gz"

    echo "Fetching ${ARCHIVE}.DIGESTS..."
    wget -q "${SOURCE}/${ARCHIVE}.DIGESTS"

    echo "Fetching ${ARCHIVE}.sha256..."
    wget -q "${SOURCE}/${ARCHIVE}.sha256"

    echo "Fetching ${ARCHIVE}.asc..."
    wget -q "${SOURCE}/${ARCHIVE}.asc"

    
    # acquire signing key from gentoo keyserver (code from gentoo-docker-images sources)
    gpg --keyserver hkps://keys.gentoo.org --recv-keys ${SIGNING_KEY}
    
    # verify digists & signatures
    openssl dgst -r -sha512 "${ARCHIVE}"
    sha256sum --check "${ARCHIVE}.sha256"

    gpg --verify "${ARCHIVE}.asc" || die "Failed to verify!"
    gpg --verify "${ARCHIVE}.DIGESTS" || die "Failed to verify!"
    gpg --verify "${ARCHIVE}.sha256" || die "Failed to verify!"

    # extract stage3
    mkdir "/gentoo"
    tar xvpf "${ARCHIVE}" --xattrs-include='*.*' --numeric-owner -C "/gentoo"

    echo DONE!
EOF


FROM scratch as crossdev
ARG ARCH
ARG PROFILE


WORKDIR /
COPY --from=builder2 /images/* /usr/local/bin/
COPY --from=fetcher /gentoo/ /

# configure entry point
SHELL ["/usr/local/bin/busybox", "sh", "-c"]
RUN <<-EOF
    for x in `find /usr/local/bin -name 'qemu-*'` ; do
        ln -s $x /usr/bin/$(basename ${x})
        echo "linked ${x}"
    done
EOF

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]