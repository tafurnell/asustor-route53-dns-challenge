# Let's Encrypt on an Asustor NAS using the AWS Route 53 DNS challenge

This sets up an Asustor NAS (written for an AS6706T running ADM 4.x/5.x) to use a Let's Encrypt certificate
issued through the **DNS-01 challenge via AWS Route 53**. The NAS does **not** need to be reachable from
the internet; certbot proves you own the domain by creating a temporary `_acme-challenge` TXT record in Route 53.

Adapted from the Cloudflare version (`ASUStor NAS LetsEncrypt DNS for Cloudflare.txt`). Main differences:

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
   IAM → *Policies* → *Create policy* → **JSON** tab → paste the contents of `route53-iam-policy.json`,
   replacing `YOUR_HOSTED_ZONE_ID` with the ID from step 1.
   Name it e.g. `certbot-route53-mydomain`.

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

The easiest route is to copy this folder to a NAS shared folder from Windows (e.g. `\\NAS\Public\asustor-dns-challenge`).
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
(to `/usr/builtin/etc/certificate/ssl_before_letsencrypt/`), writes the new `ssl.key`, `ssl.crt` and `ssl.pem`,
sets `"default": false` in `certificate.json` so ADM uses them, and restarts ADM's web server.
Your browser session may drop briefly.

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

## Reverting to ADM's original certificate

```shell
cp -p /usr/builtin/etc/certificate/ssl_before_letsencrypt/* /usr/builtin/etc/certificate/
for s in /etc/init.d/S*lighttpd; do "$s" restart; done
crontab -l | grep -v 'letsencrypt/certbot.sh' | crontab -
```

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `/bin/sh^M: bad interpreter` or `not found` | Windows line endings. Run the `sed -i 's/\r$//' ...` line from step 1. |
| `Python 3 not found` | Install **Python3** from App Central, then rerun `install.sh`. |
| `Unable to locate credentials` / `NoCredentialsError` | `aws-credentials` is missing, has CRLF endings, or lacks the `[default]` header. Always run certbot via `certbot.sh`, which sets the path to the credentials file. |
| `AccessDenied` on `ChangeResourceRecordSets` | Wrong hosted zone ID in the IAM policy, or the domain is in a different zone. |
| `Unable to find a Route53 hosted zone for ...` | The domain isn't in this AWS account, or `ListHostedZones` is missing from the policy. |
| Challenge fails with "incorrect TXT record" | Usually DNS propagation. Add `--dns-route53-propagation-seconds 60` to the certonly command. |
| pip fails building `cryptography` | Python3 from App Central is too old for prebuilt wheels. Update the Python3 app, delete `/volume1/system/letsencrypt/venv`, and rerun `install.sh`. |
| Browser still shows the Asustor certificate | Check `grep default /usr/builtin/etc/certificate/certificate.json` says `false`, and that `openssl x509 -in /usr/builtin/etc/certificate/ssl.crt -noout -subject -issuer` shows your hostname and Let's Encrypt. Then restart lighttpd and hard-refresh the browser. |
| `ADM certificate folder ... not found` from the deploy hook | Very old ADM (3.x) keeps it at `/volume0/usr/etc/lighttpd/lighttpd.pem` instead. |
