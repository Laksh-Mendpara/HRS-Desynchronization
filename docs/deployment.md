# VM Deployment Guide

This guide details how to deploy the HRS-Desynchronization lab on a remote Virtual Machine for public demonstrations.

Deploying on a VM lets you point an audience to a live public IP address while running the exploit remotely from your laptop — exactly as a real attacker would.

---

## 1. Cloud Provider Setup

Spin up a VM on any major provider (AWS EC2, DigitalOcean Droplets, GCP Compute, Azure VM):

- **OS:** Ubuntu 24.04 LTS (or 22.04)
- **Size:** 1 vCPU / 1 GB RAM is sufficient for this stack
- **Networking/Firewall:** open the following ports:

| Port | Purpose |
|---|---|
| `22` | SSH for management |
| `80` | HTTP — Nginx frontend |

---

## 2. Server Provisioning

SSH into your VM:

```bash
ssh user@<VM_PUBLIC_IP>
```

Install Docker and the Compose v2 plugin:

```bash
# Update package lists
sudo apt-get update

# Install prerequisites
sudo apt-get install -y ca-certificates curl gnupg git

# Install Docker Engine + Compose plugin
sudo apt-get install -y docker.io docker-compose-v2

# (Optional) run docker without sudo
sudo usermod -aG docker $USER && newgrp docker
```

---

## 3. Deploy the Lab

Clone the repo and start the stack:

```bash
git clone https://github.com/Laksh-Mendpara/HRS-Desynchronization.git
cd HRS-Desynchronization

# Ensure vulnerable configs are active
cp vulnerable_configs/nginx.conf nginx/nginx.conf
cp vulnerable_configs/default.vcl varnish/default.vcl

# Build and start all containers
docker compose up --build -d

# Verify all 4 containers are running
docker compose ps
```

Sanity-check that the stack is responding:

```bash
curl -i http://localhost/
curl -i http://localhost/js/app.js
```

---

## 4. Run the Exploit (from your Local Machine)

You do **not** need to SSH back into the server. Run the exploit from your laptop, replacing `<VM_PUBLIC_IP>` with the server's public IP.

```bash
# One-time setup (local machine)
uv sync
source .venv/bin/activate

# Run the exploit
python exploit/attack.py \
  --host <VM_PUBLIC_IP> \
  --port 80 \
  --target-path "/js/app.js?cb=live_demo" \
  --payload "<script>console.log('poisoned'); alert('owned');</script>"
```

### Verification

Once the exploit reports `[+] SUCCESS`, share this URL with your audience:

```
http://<VM_PUBLIC_IP>/js/app.js?cb=live_demo
```

Every browser that requests that URL will receive the attacker's payload directly from Varnish's cache — no further interaction with the origin required.

---

## 5. Demonstrating the Mitigation on the VM

After showing the attack, apply the mitigations live:

```bash
# On the VM:
cp mitigation/nginx.conf nginx/nginx.conf
cp mitigation/default.vcl varnish/default.vcl
docker compose down && docker compose up --build -d
```

Re-run the exploit from your local machine:

```bash
python exploit/attack.py \
  --host <VM_PUBLIC_IP> \
  --port 80 \
  --target-path "/js/app.js?cb=mit_demo"
```

The Phase 1 attack request will now be met with:

```
HTTP/1.1 400 Bad Request
Ambiguous request rejected – dual length headers
```

To restore the lab to vulnerable mode:

```bash
# On the VM:
cp vulnerable_configs/nginx.conf nginx/nginx.conf
cp vulnerable_configs/default.vcl varnish/default.vcl
docker compose down && docker compose up --build -d
```

---

## 6. Teardown

Shut down the lab after your demonstration:

```bash
cd HRS-Desynchronization
docker compose down
```

To free disk space from Docker images:

```bash
docker image prune -a
```
