# G3 Proxy + ICAP troubleshooting

## Sites like YouTube or ChatGPT return errors (400, broken pages)

### What the logs tell you

From your proxy logs:

- **`origin_status: 400`** on URLs such as:
  - `https://www.youtube.com/api/jnn/v1/GenerateIT`
  - `https://www.youtube.com/youtubei/v1/player?prettyPrint=false`
  - `https://www.youtube.com/youtubei/v1/get_watch?prettyPrint=false`
- **`http2: timeout to handshake with client`** and **`http2: client connection closed: ssl read: unexpected EOF`** on various hosts.

The **400** is returned by the **origin server** (e.g. YouTube), not by the proxy. So the request that **reached the origin** is invalid or malformed in their eyes. The proxy and TLS interception are working; the problem is the **content of the request** sent to the origin.

### Likely cause: ICAP reqmod changing the request

With **inspection and auditing** enabled, every intercepted HTTP request is sent to your ICAP server for **reqmod**. If the ICAP server:

- Changes headers (e.g. `Content-Length`, `Content-Type`, `Host`, encoding headers),
- Modifies or re-encodes the body,
- Or returns a slightly different request,

then the **origin** (YouTube, ChatGPT, etc.) may respond with **400 Bad Request** or break the page. So the issue is almost certainly **how your ICAP server handles reqmod**, not the proxy setup itself.

The **http2 timeout** and **ssl read: unexpected EOF** entries are often a consequence: the browser gets 400s, retries or navigates away, and connections are closed.

### How to confirm

1. **Temporarily disable ICAP reqmod** (keep inspection if you want):
   - In `config/g3proxy.yaml`, under the `ai_governance` auditor, comment out or remove the `icap_reqmod_service` block, e.g.:
     ```yaml
     auditor:
       - name: ai_governance
         protocol_inspection: {}
         tls_cert_agent: { ... }
         # icap_reqmod_service:
         #   url: "icap://host.docker.internal:1344/reqmod"
         application_audit_ratio: 1.0
     ```
   - Restart: `docker compose restart` (from `deploy/`).
   - Test YouTube / ChatGPT again. If they work, the problem is the ICAP reqmod behavior.

2. **Or temporarily disable auditing (no inspection, no ICAP)**:
   - Set `application_audit_ratio: 0` for that auditor so no traffic is audited/intercepted.
   - Test again. If sites work, the issue is in the interception/ICAP path (again, likely reqmod).

### What to fix on the ICAP side

- Implement **reqmod** so that it either:
  - Returns **204 No Content** (no changes), or
  - Returns the **exact same** request (same headers and body bytes) when you only need to log/audit.
- Avoid:
  - Changing `Content-Length` or body length.
  - Re-encoding or altering the body for POST/PUT.
  - Dropping or altering headers that origins rely on (e.g. `Content-Type`, encoding, `Host`).

### Optional: bypass on ICAP failure

If you want traffic to still go through when the ICAP server is down or unreachable, you can set **bypass** in the ICAP service config:

```yaml
icap_reqmod_service:
  url: "icap://host.docker.internal:1344/reqmod"
  bypass: true
```

This does **not** fix 400s when ICAP is up and returns a modified request; it only helps when ICAP is unavailable.

---

**Summary:** The proxy setup (inspection + auditing pointing at your local ICAP server) is functioning. The 400s indicate the **origin** is rejecting the request. That almost always means your **ICAP reqmod** is modifying requests in a way that breaks strict sites like YouTube or ChatGPT. Test with reqmod disabled; if the sites work, adjust your ICAP server so reqmod does not change the request (or returns 204 when no change is needed).
