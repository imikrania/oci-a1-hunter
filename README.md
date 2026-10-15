# oci-a1-hunter

Keeps trying to launch an Oracle Cloud **Always Free Ampere A1** instance
(`VM.Standard.A1.Flex`) until capacity appears, then stops.

Runs every 5 minutes as a GitHub Actions workflow. **In this repo the
GitHub-native `schedule` trigger never fires** (0 scheduled runs observed over
hours while `workflow_dispatch` works fine), so the tick comes from a local
Hermes cron job that calls this workflow's dispatch API every 5 minutes — see
the note in `.github/workflows/hunt.yml`. The `schedule:` block stays as free
redundancy.

Trade-off: the hunt now needs the machine that runs Hermes to be up (locked is
fine; shut down or asleep is not). While it is down, no ticks fire.

## How it works

Each run:

1. **Idempotency** — if an instance named `OCI_DISPLAY_NAME` already exists and
   is not terminated, exit immediately. So once you win, later runs are no-ops.
2. **Availability domains** — list every AD in your tenancy.
3. **Launch** — try `oci compute instance launch` in each AD in turn.
   - `*Out of host capacity*` → next AD
   - `429 / 5xx / timeout` → back off and retry the same AD (×3)
   - anything else (`NotAuthorizedOrNotFound`, `LimitExceeded`, bad image…) → **fatal, exit 1**
4. No capacity anywhere → exit 0, wait for the next scheduled run.

A `concurrency` group prevents overlapping runs from creating two instances.

## Setup

### 1. Create an OCI API key

OCI Console → profile icon → **My profile** → **API keys** → **Add API key** →
*Generate API key pair* → download the private key (`.pem`) and copy the
**configuration file preview** (it contains user / fingerprint / tenancy / region).

Put the private key here as `oci_api_key.pem`.

### 2. Collect the remaining values

| Value | Where |
|---|---|
| `OCI_USER_OCID`, `OCI_TENANCY_OCID`, `OCI_FINGERPRINT`, `OCI_REGION` | the config preview from step 1 |
| `OCI_COMPARTMENT_OCID` | the compartment you'll create the instance in (often the root/tenancy) |
| `OCI_SUBNET_ID` | a **public** subnet in your VCN |
| `OCI_IMAGE_ID` | an **aarch64 / ARM** Ubuntu image (see below) |
| `OCI_SSH_PUBLIC_KEY` | your public key (`~/.ssh/id_ed25519.pub`) |

Find the ARM image OCID for your region:

```bash
oci compute image list \
  --compartment-id "$OCI_TENANCY_OCID" \
  --operating-system "Canonical Ubuntu" \
  --shape VM.Standard.A1.Flex \
  --sort-by TIMECREATED --query 'data[0].["display-name",id]' --output table
```

### 3. Push the secrets

```bash
cp oci.env.example oci.env      # fill it in
# put your private key at ./oci_api_key.pem
bash set-secrets.sh
gh secret list
```

### 4. Let it run

The workflow fires every 5 minutes. Watch it:

```bash
gh run list --workflow hunt.yml
gh run watch
```

When it wins, the run log says `LAUNCHED in <AD>`, and the instance shows up in
the OCI console. Stop the workflow once you have the instance:

```bash
gh workflow disable hunt.yml
```

## Tuning that actually helps

- **Ask for `1 OCPU / 6 GB`, not `2 / 12`.** The smaller shape fits into gaps the
  full free-tier maximum cannot. Raise it later only if you can spare the instance.
- **Never request more than 2 OCPU / 12 GB** on a Free Tier account — that is
  `LimitExceeded`, not capacity, and will never succeed.
- **Home region only.** Always Free compute must live in your tenancy's home
  region; you cannot switch regions after the fact.
- `*Out of host capacity*` is **not a bug** — it is the whole reason this exists.
  Popular regions can take hours or days.

## Heads-up

- GitHub's terms ask that Actions runners be used for work related to the
  repository. A personal capacity poller is a grey area; keep it low-frequency
  and stop the workflow once you have the instance.
- The repo is **public**, so standard-runner minutes are free and the workflow
  runs **every 5 minutes** (~288 runs/day). A private copy would exhaust the
  GitHub Free 2,000 min/month allowance in about a week and then cost ~$40/month.
- Public repos have scheduled workflows auto-disabled after **60 days with no
  repo activity**. The `keepalive` workflow makes one tiny commit a day so that
  never happens — delete `keepalive.yml` if you don't want that daily commit.
- Always Free A1 instances idle for 7 straight days (below ~20% utilisation) can
  be reclaimed by Oracle — put a real workload on it once you have it.
