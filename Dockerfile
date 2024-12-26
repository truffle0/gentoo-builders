# Images for fetching stage3, bootstrapping images, and creating cross compile images

# Important ARGs: (change these to modify the resulting image)
# STAGE = gentoo stage to fetch for bootstrap (the ARCH is implied from this)
# PROFILE = selects the profile to build, must be in a form that `eselect profile set` will accept
# BOOTSTRAP = specify to use an existing container instead of stage3 (only really makes sense if it's gentoo)

# Optional: bootstrapping stage using gentoo stage3
FROM alpine:latest as fetcher

RUN apk --no-cache add ca-certificates gnupg tar wget xz

ARG MIRROR="https://distfiles.gentoo.org"
ARG STAGE="amd64-musl-llvm"
# yes I like musl, fuck you
ARG VERSION="latest"
ARG SIGNING_KEY="BB572E0E2D182910"

WORKDIR "/build"

RUN <<-EOF
    die() { echo $1 ; exit 1 ; }

    # acquire signing key from official gentoo keyserver
    gpg -q --keyserver hkps://keys.gentoo.org --recv-keys ${SIGNING_KEY}

	ARCH=$(echo ${STAGE} | sed -nE 's/([:alum:]*)-[[:alnum:]-]*/\1/ ; p')
	[ -n "$ARCH" ] || die "Failed to parse arch!"
    echo "Using Gentoo ${ARCH} with profile: ${STAGE}"

    # Find latest version if needed
    if [[ "${VERSION}" == "latest" ]] ; then
        SOURCE="${MIRROR}/releases/${ARCH}/autobuilds"

        echo "Fetching manifest: ${SOURCE}/latest-stage3.txt ..."
        wget -q "${SOURCE}/latest-stage3.txt" || die "Couldn't find manifest!"
        gpg --verify "latest-stage3.txt" || die "Failed to verify manifest!"

        # From gentoo-docker-images sources
		ARCHIVE=$(cat "latest-stage3.txt" | sed -nE 's/^([0-9TZ]*\/stage3-'${STAGE}'-[0-9TZ]*.tar.[a-z]{2}).*/\1/p')
		#ARCHIVE=$(cat "latest-stage3.txt" | sed -nE 's/^(stage3-[[:alnum:]-]*.tar.([a-z]{2}))\s.*/\1/p')

		# adjust source/archive to match reflect dirname/basename
		SOURCE="${SOURCE}/$(dirname $ARCHIVE)"
		ARCHIVE="$(basename $ARCHIVE)"
    else
        SOURCE="${MIRROR}/releases/${ARCH}/autobuilds/${STAGE}"
        ARCHIVE="stage3-${STAGE}-${VERSION}.tar.xz"
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

    
    
    # verify digists & signatures
    openssl dgst -r -sha512 "${ARCHIVE}"
    sha256sum --check "${ARCHIVE}.sha256"

    gpg --verify "${ARCHIVE}.asc" || die "Failed to verify!"
    gpg --verify "${ARCHIVE}.DIGESTS" || die "Failed to verify!"
    gpg --verify "${ARCHIVE}.sha256" || die "Failed to verify!"

    # extract stage3
    mkdir "/gentoo"
    tar xvpf "${ARCHIVE}" --xattrs-include='*.*' --numeric-owner -C "/gentoo"
	
	echo "STAGE=${ARCHIVE}" >> /gentoo/build.txt
    echo DONE!
EOF

# Turn the extracted stage3 into a container
# this is a perfectly viable build target if you want to skip compiling a system from scratch
FROM scratch AS stage3
WORKDIR /
COPY --from=fetcher /gentoo/ /


# Begin building a system from scratch using an existing BOOTSTRAP gentoo image
ARG BOOTSTRAP
FROM ${BOOTSTRAP:-stage3} AS builder

ARG PROFILE="default/linux/amd64/23.0/musl/llvm"

RUN emerge-webrsync
ADD make.conf.build /etc/portage/make.conf

# Profile-based checks & setup
RUN <<-EOF
    die() { echo $1 ; exit 1 ; }

	eselect profile set ${PROFILE}

	if [[ "${PROFILE}" =~ "llvm" ]] ; then
        (qlist llvm-core/llvm >/dev/null && qlist llvm-core/clang >/dev/null) || die "LLVM & Clang are required for llvm profiles!"
    else
        qlist sys-devel/gcc >/dev/null || die "GCC required for non-llvm profiles!"

        # gcc doesn't support thin lto
        sed -i 's/ -flto=thin//' /etc/portage/make.conf
    fi

    if [[ "${PROFILE}" =~ "musl" ]] ; then
        qlist sys-libs/musl >/dev/null || die "musl required for musl profiles!"
    else
        qlist sys-libs/glibc >/dev/null || die "glibc required for glibc profiles!"
    fi
   
	echo "PROFILE=${PROFILE}" >> build.txt
	echo "PORTAGE_TIMESTAMP=$(cat /var/db/repos/gentoo/metadata/timestamp.chk)" >> /build.log
EOF

RUN <<-EOF
    mkdir /gentoo
    export ROOT=/gentoo

    mkdir -m 777 /tmp/log
    export PORTAGE_LOGDIR=/tmp/log

    export MAKEOPTS="-j$(nproc)"
    export EMERGE_DEFAULT_OPTS="--jobs=$(expr `nproc` / 4)"

    USE="${USE} build" emerge -1 baselayout
    emerge -1 @system
EOF

# Move build log into the new image
RUN "cp /build.log /gentoo/build.log"


# Generate final image, and complete build
FROM scratch as gentoo
ARG PROFILE="default/linux/amd64/23.0/musl/llvm"

WORKDIR /
COPY --from=builder /gentoo/ /

COPY --from=builder /var/db/repos/gentoo /var/db/repos/gentoo
COPY --from=builder /etc/portage/make.conf /etc/portage/make.conf

# Complete world updates
RUN <<-EOF
    eselect profile set ${PROFILE}
    touch /var/lib/portage/world

    export MAKEOPTS="-j$(nproc)"
    export EMERGE_DEFAULT_OPTS="--jobs=$(expr `nproc` / 4)"
    export PORTAGE_LOGDIR="/var/log"
    
    #emerge -uDU @world
    emerge --depclean

    emaint all
EOF

# Final cleanup
RUN <<-EOF
    echo "Clearing distfiles..."
    rm -fr /var/cache/distfiles/*

    echo "Clearing logs..."
    rm -fr /var/log/*

    echo "Clearing /var/tmp..."
    rm -fr /var/tmp/*

    echo "Clearing binpkgs..."
    rm -fr /var/cache/binpkgs/*

    echo "Clearing /var/db/repos..."
    rm -fr /var/db/repos/*

	echo "Removing build make.conf..."
	rm /etc/portage/make.conf
EOF

ADD make.conf.generic /etc/portage/make.conf

SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]



FROM --platform=$BUILDPLATFORM gentoo AS crossbuilder
ARG MIRROR="https://distfiles.gentoo.org"
ARG CROSSARCH="aarch64"
ARG CROSSSTAGE="arm64-musl-llvm"
ARG CROSSVERSION="latest"
ARG SIGNING_KEY="BB572E0E2D182910"

WORKDIR /
ADD make.conf /etc/portage/make.conf
ADD qemu.use /etc/portage/package.use

VOLUME /var/cache/binpkgs

RUN <<-EOF
    die() {
        echo $1
        exit 1
    }

    # Adjust the ARCH variable to match gentoo's naming convention
    case ${CROSSARCH} in
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
            GEN_ARCH=${CROSSARCH}
            ;;
    esac
    echo "Using Gentoo ${GEN_ARCH} with profile: ${CROSSSTAGE}"

    # Figure out latest version if needed
    if [[ "${CROSSVERSION}" == "latest" ]] ; then
        SOURCE="${MIRROR}/releases/${GEN_ARCH}/autobuilds/current-stage3-${CROSSSTAGE}"

        echo "Fetching ${SOURCE}/latest-stage3-${CROSSSTAGE}.txt..."
        wget -q "${SOURCE}/latest-stage3-${CROSSSTAGE}.txt" || die "Couldn't find archive!"
        gpg --verify "latest-stage3-${CROSSSTAGE}.txt"

        # From gentoo-docker-images sources
        ARCHIVE=$(sed -n '6p' "latest-stage3-${CROSSSTAGE}.txt" | cut -f 1 -d ' ')
    else
        SOURCE="${MIRROR}/releases/${GEN_ARCH}/autobuilds/${CROSSSTAGE}"
        ARCHIVE="stage3-${CROSSSTAGE}-${CROSSVERSION}.tar.xz"
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

RUN emerge-webrsync
RUN MAKEOPTS="-j$(nproc)" emerge --jobs=$(expr `nproc` / 4) --quiet-build sys-apps/busybox
RUN MAKEOPTS="-j$(nproc)" emerge --jobs=$(expr `nproc` / 4) --quiet-build app-emulation/qemu


RUN <<-EOF
    mkdir "/images"
    cp /usr/bin/qemu-{x86_64,riscv32,riscv64,arm,aarch64} /images/
    cp `which busybox` /images/
EOF


FROM scratch as crossdev
ARG ARCH
ARG PROFILE

WORKDIR /
COPY --from=crossbuilder /images/* /usr/local/bin/
COPY --from=crossbuilder /gentoo/ /

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
