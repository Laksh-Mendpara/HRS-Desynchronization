# VM Deployment Guide

This guide details how to deploy the HRS-Desynchronization lab on a remote Virtual Machine (VM) for public demonstrations.

Deploying to a VM allows you to point attendees to a live IP address securely, while performing the HTTP Request Smuggling exploit remotely from your local laptop to seamlessly inject poisoned payloads.

## 1. Cloud Provider Setup

1. **Spin up a Virtual Machine**
   Use AWS EC2, DigitalOcean Droplets, Azure, or Google Cloud Compute. 
   - **OS:** Ubuntu 24.04 (or 22.04) LTS is recommended.
   - **Size:** 1vCPU / 1GB RAM is completely fine for this lightweight stack.

2. **Configure Networking (Security Groups/Firewalls)**
   Ensure the following ports are open to the internet (or restricted to specific IP blocks if doing an internal demo):
   - `Port 22` (SSH for management)
   - `Port 80` (HTTP for the Nginx frontend)

## 2. Server Provisioning

Log into your VM via SSH:

```bash
ssh user@<VM_PUBLIC_IP>
```

Once inside, install Docker and the Docker Compose v2 plugin:

```bash
# Update repositories
sudo apt-get update

# Install prerequisites
sudo apt-get install -y ca-certificates curl gnupg git

# Install Docker Engine and Compose plugin
sudo apt-get install -y docker.io docker-compose-v2
```

> **Note:** If you want to run `docker` without `sudo`, you can add your user to the docker group:
> ```bash
> sudo usermod -aG docker $USER
> newgrp docker
> ```

## 3. Deploy the Lab

Clone the repository and launch the Docker stack:

```bash
# Clone the repository
git clone https://github.com/Laksh-Mendpara/HRS-Desynchronization.git
cd HRS-Desynchronization

# Switch to the deployment branch (if required)
git switch deployment

# Build and start the environment in detached mode
sudo docker compose up --build -d
```

Verify everything is running gracefully on port 80:

```bash
sudo docker compose ps
```

## 4. Run the Exploit (From your Local Machine)

Once the VM is humming along, you do **not** need to SSH back into the server. You can execute the cache-poisoning payload straight from your laptop.

On your **local machine**, sync dependencies and run `attack.py` replacing `<VM_PUBLIC_IP>` with the public IP of your server:

```bash
uv sync 
source .venv/bin/activate

python exploit/attack.py \
  --host <VM_PUBLIC_IP> \
  --port 80 \
  --target-path '/js/app.js?cb=live_demo' \
  --payload "<script>console.log('poisoned_script ran successfully'); alert('owned');</script>"
```

### Verification

Once successfully executed, share the URL with your audience:

```text
http://<VM_PUBLIC_IP>/js/app.js?cb=live_demo
```

Instead of standard javascript, anyone clicking the link globally will receive your malicious HTML/JavaScript payload!

## 5. Teardown

To shut down the lab post-demonstration securely on your VM:

```bash
cd HRS-Desynchronization
sudo docker compose down
```
