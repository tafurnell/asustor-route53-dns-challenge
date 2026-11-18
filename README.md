# Let's Encrypt on an Asustor NAS using the AWS Route 53 DNS challenge

This sets up an Asustor NAS to use a Let's Encrypt certificate for the ADM web interface. The certificate is
issued through the **DNS-01 challenge via AWS Route 53**. The NAS does **not** need to be reachable from
the internet; certbot proves you own the domain by creating a temporary `_acme-challenge` TXT record in Route 53.

**Tested on:** Asustor AS6706T with ADM 5.1.4. Other models running ADM 5 use the same file layout and should work.
Earlier ADM versions are untested.

> **Use at your own risk.** This changes system files on the NAS that ADM doesn't officially expect you to touch.
> The deploy hook backs up ADM's original certificate first, and the *Reverting* section below undoes everything.
> Back up anything important on the NAS before starting.
>
> This is an unofficial community project, not affiliated with or endorsed by ASUSTOR Inc. or Amazon Web Services.

Adapted from community guides that do the same with Cloudflare
([bergelfs](https://gist.github.com/bergelfs/ae1bae681d10ce37ec5645d362fcf9ef),
[troyfontaine](https://gist.github.com/troyfontaine/9febcc69f632330b3d462a2e14c57aa1)). Main differences:

| | Cloudflare version | This version |
|---|---|---|
| DNS plugin | `certbot-dns-cloudflare` | `certbot-dns-route53` |
| Credentials | `cloudflare.ini` (API token) | `aws-credentials` (IAM access key, limited to one hosted zone) |
| Where certbot lives | pip into system Python, reinstalled at every boot | Python virtual env on `/volume1`, so it survives reboots |
| Cert storage | ADM's own `/volume0/.../letsencrypt` | `/volume1/system/letsencrypt/etc`, kept separate from ADM's built-in renewer |
| Deploy hook | symlinked into `renewal-hooks/deploy` | registered with `--deploy-hook`, which certbot saves in the renewal config |

> The examples use `nas.mydomain.com`, `you@example.com` and `/volume1/system/letsencrypt`.
> Change them to your own values everywhere they appear.

## Files in this folder

| File | Purpose |
|---|---|
| `install.sh` | Creates a Python venv and installs `certbot` + `certbot-dns-route53` |
| `certbot.sh` | Wrapper: points certbot at the AWS credentials and this folder's config/log dirs |
| `adm-deploy.sh` | Deploy hook: installs a new/renewed cert into ADM's web server and restarts it |
| `route53-iam-policy.json` | Least-privilege IAM policy for the certbot user |
| `aws-credentials.example` | Template for the AWS access key file |

---

## Prerequisites

- Your domain's DNS is hosted in a **Route 53 public hosted zone**.
- A name such as `nas.mydomain.com` resolves to the NAS **on your LAN**. Use a local DNS or router entry, or a Route 53 A record
  pointing at the NAS's private IP. Without it, the browser can't match the certificate to the address you type.
- If your domain has a **CAA** record, it must allow `letsencrypt.org`.
- On the NAS:
  - **App Central → install "Python3"**.
  - **Services → Terminal → enable SSH**.

---

## Part 1 – AWS setup (in the AWS console)

1. **Get your Hosted Zone ID.**
   Route 53 → *Hosted zones* → click your domain → copy the **Hosted zone ID** (looks like `Z0123456789ABCDEFGHIJ`).

2. **Create the IAM policy.**
   IAM → *Policies* → *Create policy* → **JSON** tab → paste the contents of `route53-iam-policy.json`, then replace:
   - `YOUR_HOSTED_ZONE_ID` with the ID from step 1;
   - `_acme-challenge.nas.mydomain.com` with `_acme-challenge.` followed by your NAS hostname, all **lowercase**,
     no trailing dot. For a wildcard certificate (`*.mydomain.com`), also add `_acme-challenge.mydomain.com` to that list.

   This lets the key create and delete **only** the TXT records used for the challenge. Even if the key leaked,
   it couldn't change any other record in your domain.
   Name the policy e.g. `certbot-route53-mydomain`.

3. **Create an IAM user for the NAS.**
   IAM → *Users* → *Create user* → name `certbot-nas` (no console access) →
   *Attach policies directly* → select the policy from step 2 → create.

4. **Create an access key.**
   Open the user → *Security credentials* → *Create access key* → choose
   **"Application running outside AWS"** → create.
   Copy the **Access key ID** and **Secret access key** now. The secret is only shown once.

---

## Part 2 – NAS setup (over SSH)

### Step 1 – Copy the files to the NAS

The easiest route is to copy this folder to any NAS shared folder over the network. The commands below use
`Public` as the example (`\\NAS\Public\asustor-dns-challenge` from Windows); adjust the path if you use another share.
Then SSH in as an admin user and become root:

```shell
ssh admin@nas.mydomain.com
sudo -i
```

Create the working folder and copy the files in:

```shell
mkdir -p /volume1/system/letsencrypt
cp /volume1/Public/asustor-dns-challenge/*.sh /volume1/system/letsencrypt/
cp /volume1/Public/asustor-dns-challenge/aws-credentials.example /volume1/system/letsencrypt/aws-credentials
cd /volume1/system/letsencrypt

# Strip Windows line endings (scripts will fail with "not found" errors otherwise)
sed -i 's/\r$//' *.sh aws-credentials

chown -R root:root /volume1/system/letsencrypt
chmod 700 /volume1/system/letsencrypt
chmod 700 *.sh
chmod 600 aws-credentials
```

> Once everything is working, delete the copy in the shared folder, especially if you edited
> `aws-credentials.example` with your real keys.

### Step 2 – Add your AWS keys

```shell
vi /volume1/system/letsencrypt/aws-credentials
```

Put in the key from Part 1, step 4:

```ini
[default]
aws_access_key_id = AKIA................
aws_secret_access_key = ........................................
```

### Step 3 – Install certbot and the Route 53 plugin

```shell
/volume1/system/letsencrypt/install.sh
```

It should finish by printing a certbot version and listing `dns-route53` among the plugins.

### Step 4 – Test with a dry run (staging server, nothing is installed)

```shell
/volume1/system/letsencrypt/certbot.sh certonly --dry-run \
  --dns-route53 --preferred-challenges dns-01 \
  -m you@example.com --agree-tos --no-eff-email \
  -d nas.mydomain.com
```

Look for **"The dry run was successful."** If it fails, see *Troubleshooting* below.

### Step 5 – Issue the real certificate and install it into ADM

```shell
/volume1/system/letsencrypt/certbot.sh certonly \
  --dns-route53 --preferred-challenges dns-01 \
  --deploy-hook /volume1/system/letsencrypt/adm-deploy.sh \
  -m you@example.com --agree-tos --no-eff-email \
  -d nas.mydomain.com
```

Certbot saves the DNS plugin and the deploy hook in its renewal config. Renewals therefore need no extra arguments.
The deploy hook runs right after this first issue. It backs up ADM's current certificate files once
(to `/usr/builtin/etc/certificate/ssl_before_letsencrypt/`), writes the new `ssl.key`, `ssl.crt`, `ssl.pem`
and `ssl.chain` (the Let's Encrypt intermediate), and restarts ADM's web server.
Your browser session may drop briefly; reopen the browser or use a private window to see the new certificate.

> How ADM 5 serves its certificate: lighttpd reads `/usr/etc/lighttpd/lighttpd.pem` (a link to
> `/usr/builtin/etc/certificate/ssl.pem`) and the intermediate from `/usr/etc/lighttpd/lighttpd.chain` (a link to
> `/usr/builtin/etc/certificate/ssl.chain`). The stock Asustor certificate has no intermediate, so `ssl.chain`
> doesn't exist until the hook creates it. If it's missing, browsers show "Not secure" even with a valid certificate.
> `certificate.json` is only Certificate Manager's list and isn't changed.

To rerun the hook by hand at any time (for example after changing it):

```shell
RENEWED_LINEAGE=/volume1/system/letsencrypt/etc/live/nas.mydomain.com /volume1/system/letsencrypt/adm-deploy.sh
```

> Want a wildcard too? Add `-d '*.mydomain.com'` (keep the quotes). DNS-01 is the only challenge that supports wildcards.

### Step 6 – Schedule automatic renewal

```shell
( crontab -l 2>/dev/null; echo "17 4 * * * /volume1/system/letsencrypt/certbot.sh renew -q" ) | crontab -
crontab -l
```

Certbot runs daily but only renews when the certificate is within 30 days of expiry. On renewal it runs the deploy hook automatically.

To test the renewal path end to end without touching the real cert:

```shell
/volume1/system/letsencrypt/certbot.sh renew --dry-run
```

### Step 7 – Verify

Browse to `https://nas.mydomain.com:8001` (or whatever HTTPS port ADM uses). The certificate should be issued by Let's Encrypt.

---

## Ongoing maintenance

- **After an ADM firmware update or a Python3 App Central update:** run `install.sh` again. Then check that the cron
  entry is still there with `crontab -l` and re-add it (step 6) if it's missing.
- **Don't** also enable ADM's built-in Let's Encrypt for the same hostname. It would try an HTTP challenge and overwrite this certificate.
- ADM's *Certificate Manager* page will not list this certificate, because it's installed straight into the web server.
  That's expected.
- Logs: `/volume1/system/letsencrypt/logs/letsencrypt.log`.

## Security notes

- **The AWS key is the only secret.** It lives in `aws-credentials` in a root-only folder (`chmod 700`, file `chmod 600`).
  With the IAM policy above it can only add or remove `_acme-challenge` TXT records for your hostname.
  If you think it has leaked, delete the access key in IAM and create a new one.
- **Never commit `aws-credentials`** or the `etc/` folder (which holds your certificate's private key). The included
  `.gitignore` excludes them if you keep a working copy of this repo.
- **Delete the copy in your shared folder** once installed, especially if you put real keys in `aws-credentials.example` there.
- **ADM stores the web server key world-readable** (`ssl.key` is mode 755 by default). This is ADM's own default and is
  left unchanged here, because other ADM services may need to read it.
- **The NAS isn't exposed.** DNS-01 needs no inbound ports; only the NAS's outgoing HTTPS calls to Let's Encrypt
  and AWS are used. Your hostname does appear in public Certificate Transparency logs, like every publicly trusted certificate.

## Reverting to ADM's original certificate

```shell
cp -p /usr/builtin/etc/certificate/ssl_before_letsencrypt/* /usr/builtin/etc/certificate/
rm -f /usr/builtin/etc/certificate/ssl.chain
for s in /etc/init.d/S*lighttpd; do "$s" restart; done
crontab -l | grep -v 'letsencrypt/certbot.sh' | crontab -
```

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `/bin/sh^M: bad interpreter` or `not found` | Windows line endings. Run the `sed -i 's/\r$//' ...` line from step 1. |
| `Python 3 not found` | Install **Python3** from App Central, then rerun `install.sh`. |
| `Unable to locate credentials` / `NoCredentialsError` | `aws-credentials` is missing, has CRLF endings, or lacks the `[default]` header. Always run certbot via `certbot.sh`, which sets the path to the credentials file. |
| `AccessDenied` on `ChangeResourceRecordSets` | Wrong hosted zone ID in the IAM policy, or the `_acme-challenge.` name in the policy doesn't exactly match your hostname (it must be lowercase, with no trailing dot). |
| `Unable to find a Route53 hosted zone for ...` | The domain isn't in this AWS account, or `ListHostedZones` is missing from the policy. |
| Challenge fails with "incorrect TXT record" | Usually DNS propagation. Add `--dns-route53-propagation-seconds 60` to the certonly command. |
| pip fails building `cryptography` | Python3 from App Central is too old for prebuilt wheels. Update the Python3 app, delete `/volume1/system/letsencrypt/venv`, and rerun `install.sh`. |
| Browser still shows the Asustor certificate | Check `ls -la /usr/etc/lighttpd/lighttpd.pem` points to `/usr/builtin/etc/certificate/ssl.pem`, then restart lighttpd and fully close/reopen the browser (it reuses old connections). |
| Browser shows your certificate but "Not secure" / incomplete chain | `/usr/builtin/etc/certificate/ssl.chain` is missing or empty. Rerun the deploy hook by hand (step 5). |
| Restarting lighttpd prints an nftables `Range has zero or negative size` error | A typo in an ADM Defender trusted IP range (start address higher than end). Fix it under Settings → ADM Defender. It's unrelated to the certificate. |
| `ADM certificate folder ... not found` from the deploy hook | Your ADM version keeps the certificate elsewhere. Run `ls -la /usr/etc/lighttpd/` to see where `lighttpd.pem` and `lighttpd.chain` point, and change `CERTDIR` in `adm-deploy.sh` to match. |
