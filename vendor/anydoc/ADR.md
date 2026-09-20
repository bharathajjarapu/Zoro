# Vendored AnyDoc helper

Status: accepted 2026-09-13.

Zoro needs local document extraction without adding Rust or Node to builds and
runtime containers. AnyDoc 0.2.4 covers the supported document formats without
OCR.

The repository stores a stripped x86_64 Linux musl helper and its exact Rust
sources. Normal builds verify its SHA-256 and copy it beside `zoro`:

```text
610013d93cda03f4a51cba78eb951a990a00b9dfab1a6ca2a5a3beda67a4b81a
```

Rebuild only when upgrading AnyDoc:

```sh
podman run --rm -v "$PWD:/build" -w /build rust:1.88-alpine3.21 \
  sh -c 'apk add --no-cache musl-dev >/dev/null && cargo build --release --locked'
cp target/release/zoro-anydoc anydoc
chmod 0555 anydoc
sha256sum anydoc
```

Update the checksum here and in `build.zig` together.
