FROM golang:1.15.5-buster
MAINTAINER ketrelhf <serltretu24@gmail.com>

ENV SRC_DIR /lotus

RUN apt-get update && apt-get install -y ca-certificates llvm clang mesa-opencl-icd ocl-icd-opencl-dev jq hwloc libhwloc-dev

RUN curl -sSf https://sh.rustup.rs | sh -s -- -y


# Get su-exec, a very minimal tool for dropping privileges,
# and tini, a very minimal init daemon for containers
ENV SUEXEC_VERSION v0.2
ENV TINI_VERSION v0.18.0
RUN set -x \
  && cd /tmp \
  && git clone https://github.com/ncopa/su-exec.git \
  && cd su-exec \
  && git checkout -q $SUEXEC_VERSION \
  && make \
  && cd /tmp \
  && wget -q -O tini https://github.com/krallin/tini/releases/download/$TINI_VERSION/tini \
  && chmod +x tini

# Download packages first so they can be cached.
COPY lotus/go.mod lotus/go.sum $SRC_DIR/
COPY lotus/extern/ $SRC_DIR/extern/
RUN cd $SRC_DIR \
  && go mod download

COPY lotus/Makefile $SRC_DIR

# Because extern/filecoin-ffi building script need to get version number from git
COPY lotus/.git/ $SRC_DIR/.git/
COPY lotus/.gitmodules $SRC_DIR/

# Download dependence first
RUN cd $SRC_DIR \
  && mkdir $SRC_DIR/build \
  && . $HOME/.cargo/env \
  && make clean \
  && FFI_BUILD_FROM_SOURCE=1 RUSTFLAGS="-C target-cpu=native -g" CGO_CFLAGS="-D__BLST_PORTABLE__" make deps


COPY lotus/ $SRC_DIR

ARG MAKE_TARGET=lotus

# Build the thing.
RUN cd $SRC_DIR \
  && . $HOME/.cargo/env \
  && FFI_BUILD_FROM_SOURCE=1 RUSTFLAGS="-C target-cpu=native -g" CGO_CFLAGS="-D__BLST_PORTABLE__" make $MAKE_TARGET

# Now comes the actual target image, which aims to be as small as possible.
FROM busybox:1-glibc
MAINTAINER textile <filecoin@textile.io>

# Get the executable binary and TLS CAs from the build container.
ENV SRC_DIR /lotus
COPY --from=0 $SRC_DIR/lotus /usr/local/bin/lotus
COPY --from=0 /tmp/su-exec/su-exec /sbin/su-exec
COPY --from=0 /tmp/tini /sbin/tini
COPY --from=0 /etc/ssl/certs /etc/ssl/certs


# This shared lib (part of glibc) doesn't seem to be included with busybox.
COPY --from=0 /lib/x86_64-linux-gnu/libdl-2.28.so /lib/libdl.so.2
COPY --from=0 /lib/x86_64-linux-gnu/libutil-2.28.so /lib/libutil.so.1
COPY --from=0 /usr/lib/x86_64-linux-gnu/libOpenCL.so.1.0.0 /lib/libOpenCL.so.1
COPY --from=0 /usr/lib/gcc/x86_64-linux-gnu/8/libstdc++.so /lib/libstdc++.so.6
COPY --from=0 /lib/x86_64-linux-gnu/librt-2.28.so /lib/librt.so.1
COPY --from=0 /lib/x86_64-linux-gnu/libgcc_s.so.1 /lib/libgcc_s.so.1
COPY --from=0 /usr/lib/x86_64-linux-gnu/libhwloc.so.5 /lib/libhwloc.so.5
COPY --from=0 /usr/lib/x86_64-linux-gnu/libnuma.so.1 /lib/libnuma.so.1
COPY --from=0 /usr/lib/x86_64-linux-gnu/libltdl.so.7 /lib/libltdl.so.7

# WS port
EXPOSE 1235
# P2P port
EXPOSE 5678


# Create the home directory and switch to a non-privileged user.
ENV HOME_PATH /data
ENV PARAMCACHE_PATH /var/tmp/filecoin-proof-parameters
ENV FULLNODE_API_INFO wss://wss.node.glif.io/apigw/lotus

RUN mkdir -p $HOME_PATH $PARAMCACHE_PATH \
  && adduser -D -h $HOME_PATH -u 1000 -G users lotus \
  && chown lotus:users $HOME_PATH $PARAMCACHE_PATH


VOLUME $HOME_PATH
VOLUME $PARAMCACHE_PATH
VOLUME $FULLNODE_API_INFO

USER lotus

# Execute the daemon subcommand by default
CMD ["/sbin/tini", "--", "lotus", "daemon", "--lite"]