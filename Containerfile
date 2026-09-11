FROM debian:trixie-slim AS build

ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fsSL -o zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
 && echo "${ZIG_SHA256}  zig.tar.xz" | sha256sum -c - \
 && tar -xJf zig.tar.xz \
 && mv "zig-x86_64-linux-${ZIG_VERSION}" /opt/zig \
 && rm zig.tar.xz

COPY build.zig build.zig.zon ./
COPY vendor ./vendor
COPY src ./src
# Build a static runtime binary.
RUN /opt/zig/zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl

FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home --home-dir /home/zoro zoro \
 && mkdir -p /data /skills /workspace \
 && chown zoro:zoro /data /skills /workspace \
 # Prevent runtime package installation.
 && rm -rf /usr/bin/apt /usr/bin/apt-get /usr/bin/apt-cache /usr/bin/apt-config \
           /usr/bin/apt-key /usr/bin/apt-mark /usr/bin/dpkg /usr/bin/dpkg-deb \
           /usr/bin/dpkg-query /usr/bin/dpkg-split /usr/bin/dpkg-trigger \
           /usr/lib/apt /etc/apt /var/lib/dpkg /var/cache/apt

COPY --from=build /src/zig-out/bin/zoro /usr/local/bin/zoro

USER zoro
WORKDIR /home/zoro
ENV ZORO_DATA_DIR=/data \
    ZORO_SKILLS_DIR=/skills \
    ZORO_WORKSPACE=/workspace
VOLUME ["/data", "/skills", "/workspace"]
ENTRYPOINT ["/usr/local/bin/zoro"]
