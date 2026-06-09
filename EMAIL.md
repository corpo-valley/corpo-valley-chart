# Email

Kratos sends transactional mail (password recovery, login codes, account
verification) via SMTP. The chart wires this through one Secret + two values:

```yaml
# values.yaml
email:
  fromAddress: noreply@corpo-valley.com
  fromName: Corpo Valley
```

```
# kratos-smtp Secret in <prefix>ory namespace, key:
COURIER_SMTP_CONNECTION_URI=smtps://USER:PASS@HOST:PORT/?disable_starttls=false
```

The chart's `generate-secrets.sh --smtp-uri ...` script seals this. The
connection URI follows Kratos's
[courier syntax](https://www.ory.sh/docs/kratos/emails-sms/sending-emails-smtp):
`smtps://` for implicit TLS on 465, or `smtp://` with `?disable_starttls=true`
for plain (don't).

## Why you need an SMTP relay (not your own server)

**Hetzner blocks outbound port 25** by default to prevent abuse. You can ask
support to unblock it after running a clean server for a while, but until
then a self-hosted Postfix that talks directly to recipient MX servers will
not work. You need a relay (smarthost) on 465 or 587.

The same is true on most other clouds — AWS, GCP, Azure all block 25 by
default. The relay model is the standard answer.

## Picking a provider

Any provider that gives you SMTP credentials works. The four sensible options:

| Provider | Free tier | Reputation | Setup |
|---|---|---|---|
| [Mailgun](https://www.mailgun.com/) | 5k/mo for 3 months then $15/mo | Excellent | Verify domain → SMTP creds |
| [AWS SES](https://aws.amazon.com/ses/) | 62k/mo free (from EC2) | Excellent but sandbox-by-default | Verify domain → SES creds → request prod access |
| [SMTP2GO](https://www.smtp2go.com/) | 1k/mo free | Good | Verify domain → SMTP creds |
| [Postmark](https://postmarkapp.com/) | 100/mo free, $15/mo for 10k | Excellent (transactional-only) | Verify domain → server token (SMTP) |
| [Resend](https://resend.com/) | 100/day free, $20/mo for 50k | Newer, good | Verify domain → API key (SMTP supported) |

For corpo-valley scale (100 users, mostly verification + recovery codes), any
of these are vastly more than enough.

## DNS records you'll need

Whichever provider you pick, three records go in **your Cloudflare zone for
`<domain>`** so recipients accept the mail:

### SPF — say which servers can send for you

```
TXT  @  v=spf1 include:<provider-spf-domain> -all
```

e.g. `v=spf1 include:mailgun.org -all` or `include:amazonses.com`. The `-all`
makes it strict; recipients reject mail from any other server.

### DKIM — cryptographically sign each message

The provider gives you 1-3 CNAME records like:

```
CNAME  k1._domainkey.corpo-valley.com  →  k1.<provider-cname>
```

Add them as the provider's setup wizard tells you.

### DMARC — tell receivers what to do on auth failure

```
TXT  _dmarc  v=DMARC1; p=quarantine; rua=mailto:dmarc@corpo-valley.com
```

`p=quarantine` is the sensible default (marks failing mail as spam). Use
`p=none` for the first week if you want to see what breaks before enforcing.

## Verifying

After DNS propagates (5 min – 24h on Cloudflare):

```bash
# Pull the user-registered email from Kratos:
kubectl exec -n cv-ory deploy/ory-kratos -- \
  kratos identity get <id> --endpoint http://localhost:4434

# Trigger a recovery flow:
curl -X POST https://auth.corpo-valley.com/self-service/recovery/api \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@elsewhere.com","method":"link"}'

# Watch kratos courier the message:
kubectl logs -n cv-ory deploy/ory-kratos | grep courier
# -> ... msg="Courier mail with subject \"Recover access to your account\" was sent" status=sent
```

If you see `status=queued` and it never moves to `sent`, the SMTP creds are
wrong. If you see `status=sent` but no mail arrives, check the provider's
suppression list (DMARC failure / bounced address / first-send reputation
hit).

## Common gotchas

- **Provider sandbox mode.** AWS SES starts every new account in "sandbox" —
  you can only send to verified addresses. Request production access before
  you trust it for user mail.
- **From-address mismatch.** `email.fromAddress` MUST be at a domain you've
  added to the provider. Sending `noreply@corpo-valley.com` through a relay
  that only knows about `dev.cobl.io` → instant rejection.
- **Cloudflare proxying.** SPF/DKIM TXT records do NOT need to be proxied
  (gray cloud). DKIM as a CNAME is fine to leave gray.
- **First-send reputation.** New domains start with low reputation; Gmail
  may slot the first few mails into spam. Have the test recipient mark "not
  spam" once and it sticks.
- **`disable_starttls`.** STARTTLS providers (587) need `?disable_starttls=false`.
  Implicit-TLS providers (465) use `smtps://` and the flag doesn't matter.
  Don't ever ship `smtp://` without TLS for outbound — your creds go over
  the wire in plain text.

## What the chart doesn't do (yet)

- **Bounce / complaint webhooks.** When SES tells you a recipient hard-bounced,
  Kratos should mark that identity's email unverified. Not wired today.
- **Outbound rate limiting.** A buggy Kratos hook that triggers 10k recovery
  flows would burn through your provider quota. The chart has no Kratos-side
  throttle. Phase 2.
- **Inbound (replies).** If a user replies to a Kratos email, nothing reads
  it. Wire the `from` address to a real mailbox (or set it to a no-reply
  domain) so users don't email a black hole.
