# Copilot / Microsoft TLS: CERT_DECOMPRESSION_FAILED — Analysis and Fix

## Summary

When accessing **Microsoft Copilot** (`copilot.microsoft.com`) through the g3 proxy with TLS interception (e.g. `tls_modern`), the upstream TLS handshake failed with:

```text
CERT_DECOMPRESSION_FAILED ... alg=2
```

Other sites (e.g. ChatGPT, Claude) worked. This document describes the root cause and the fix applied in the g3 codebase.

---

## 1. Observed behavior

- **Logs** (e.g. `icapeg/logs/g3proxylogs-edge.txt`):
  - `upstream: copilot.microsoft.com:443`
  - `reason: InterceptionError`
  - `reason_detail: tls_modern interception error: tls: upstream handshake failed: upstream handshake error: ssl connect: error:10000124:SSL routines:OPENSSL_internal:CERT_DECOMPRESSION_FAILED ... alg=2`
- **Stack:** BoringSSL (`bssl-cmake-sys`), TLS 1.3, during the **proxy → upstream** TLS handshake (not client → proxy).

So the failure happens when the proxy, acting as a TLS **client**, connects to Microsoft’s server and tries to process the server’s certificate chain.

---

## 2. Root cause

### 2.1 Certificate compression (RFC 8879)

- TLS 1.3 certificate compression allows the server to send the certificate chain compressed (e.g. Brotli, Zlib, Zstd).
- **Algorithm ID `alg=2`** corresponds to **Brotli**.
- Microsoft (e.g. `copilot.microsoft.com`) sends Brotli-compressed certificates; many other sites do not, which is why only Copilot (and possibly other Microsoft endpoints) failed.

### 2.2 BoringSSL contract for the decompression callback

The decompression callback registered with the SSL context must:

- Decompress the input into the provided output buffer.
- Produce **exactly** the number of bytes the library expects (the output buffer length).
- Return that byte count on success; return `0` (or failure) otherwise.

If the callback returns fewer bytes than the expected length, BoringSSL treats decompression as failed and reports **CERT_DECOMPRESSION_FAILED**.

### 2.3 Bug in g3’s Brotli callback

The Brotli decompression was implemented as a **single** `Read::read()` call:

```rust
brotli::Decompressor::new(in_buf, 4096)
    .read(out_buf)
    .unwrap_or(0)
```

`Read::read()` is only required to return *at least one* byte when data is available; it is **not** required to fill the entire buffer. For larger certificate chains (typical for Microsoft), one `read()` often returns only part of the decompressed data (e.g. 4096 bytes), so:

- The callback returned that partial count.
- BoringSSL expected the full `uncompressed_len` → mismatch → **CERT_DECOMPRESSION_FAILED**.

So the issue was **incomplete decompression** in the callback, not missing Brotli support or a generic TLS/SSL misconfiguration.

---

## 3. Fix

### 3.1 Approach

- Decompress from `in_buf` into `out_buf` by **repeatedly** calling `Read::read()` on the Brotli decompressor until either:
  - The output buffer is full (`written == out_buf.len()`), or
  - The decompressor returns `0` (end of stream).
- Return the number of bytes written **only if** it equals `out_buf.len()` (success); otherwise return `0` (failure).

This satisfies BoringSSL’s requirement that the decompressed result have exactly the expected length.

### 3.2 Code changes

The same logic was applied in **two** places where Brotli cert decompression is registered:

1. **Interception client config** (used for TLS interception / MITM upstream connections):
   - **File:** `lib/g3-types/src/net/openssl/client/intercept.rs`
   - **Function:** `build_set_cert_compression()`

2. **Default TLS client config** (used for non-interception TLS client connections):
   - **File:** `lib/g3-types/src/net/openssl/client/mod.rs`
   - **Function:** `OpensslClientConfigBuilder::build_with_alpn_protocols()` (inside the `#[cfg(any(awslc, boringssl, tongsuo))]` block)

**Before (conceptually):**

```rust
.add_cert_decompression_alg(CertCompressionAlgorithm::BROTLI, |in_buf, out_buf| {
    use std::io::Read;
    brotli::Decompressor::new(in_buf, 4096)
        .read(out_buf)
        .unwrap_or(0)
})
```

**After:**

```rust
.add_cert_decompression_alg(CertCompressionAlgorithm::BROTLI, |in_buf, out_buf| {
    use std::io::Read;

    let mut decompressor = brotli::Decompressor::new(in_buf, 4096);
    let mut written = 0;
    while written < out_buf.len() {
        match decompressor.read(&mut out_buf[written..]) {
            Ok(0) => break,
            Ok(n) => written += n,
            Err(_) => return 0,
        }
    }
    if written == out_buf.len() {
        written
    } else {
        0
    }
})
```

---

## 4. Verification

- Rebuild g3 (and the proxy) with the same features you use in production (e.g. `vendored-boringssl`).
- Reproduce traffic to `copilot.microsoft.com` through the proxy with TLS interception enabled.
- Confirm that the upstream handshake completes and that Copilot loads; log messages should no longer show `CERT_DECOMPRESSION_FAILED` or `InterceptionError` for that upstream.

---

## 5. References

- **TLS Certificate Compression:** RFC 8879.
- **BoringSSL:** Certificate compression/decompression is implemented via callbacks; the decompressed output must match the expected length.
- **Algorithm IDs:** Brotli = 2 (alg=2 in the error).
- **g3 docs:** `doc/openssl-variants.md` for BoringSSL and other OpenSSL variants used by g3.
