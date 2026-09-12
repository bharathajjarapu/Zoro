FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS build

ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00

RUN apk add --no-cache ca-certificates curl xz

WORKDIR /src
RUN curl -fsSL -o zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
 && echo "${ZIG_SHA256}  zig.tar.xz" | sha256sum -c - \
 && tar -xJf zig.tar.xz \
 && mv "zig-x86_64-linux-${ZIG_VERSION}" /opt/zig \
 && rm zig.tar.xz

COPY build.zig build.zig.zon ./
COPY vendor ./vendor
COPY src ./src
RUN /opt/zig/zig build -j1 -Doptimize=ReleaseFast

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

RUN apk add --no-cache ca-certificates \
 && addgroup -S zoro \
 && adduser -S -D -u 10001 -h /home/zoro -G zoro zoro \
 && mkdir -p /data /workspace/inbox /data/tmp \
 && chown -R zoro:zoro /data /workspace

COPY --from=build /src/zig-out/bin/zoro /usr/local/bin/zoro

USER zoro
WORKDIR /home/zoro
ENV ZORO_HOME=/data \
    ZORO_DATA_DIR=/data/data \
    ZORO_SKILLS_DIR=/data/skills \
    ZORO_WORKSPACE=/workspace \
    ZORO_INBOX_DIR=/workspace/inbox \
    ZORO_TMP_DIR=/data/tmp
VOLUME ["/data", "/workspace"]
ENTRYPOINT ["/usr/local/bin/zoro"]
