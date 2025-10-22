#!/bin/bash

set -e

LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
  log "❌ ERROR: $1"
  exit 1
}

log "=== Starting Automated Deployment ==="

# Step 1: Collect Parameters
read -p "Git repository URL (HTTPS): " REPO_URL
read -p "Personal Access Token (PAT) (leave blank for SSH): " PAT
read -p "Branch name (default: main): " BRANCH
read -p "Remote server SSH username (e.g., ubuntu): " SSH_USER
read -p "Remote server IP: " SERVER_IP
read -p "SSH private key path: " SSH_KEY
read -p "Application port (internal container port, e.g., 80 or 3000): " APP_PORT

BRANCH=${BRANCH:-main}

log "Using repo: $REPO_URL (branch: $BRANCH)"
log "Server: $SSH_USER@$SERVER_IP"

# Step 2: Clone Repo
REPO_NAME=$(basename "$REPO_URL" .git)
if [ -d "$REPO_NAME" ]; then
  log "Repo exists — pulling latest changes"
  cd "$REPO_NAME" && git pull origin "$BRANCH"
else
  log "Cloning repository..."
  git clone -b "$BRANCH" "$REPO_URL" || error_exit "Failed to clone repository."
  cd "$REPO_NAME"
fi

# Step 3: Check for Dockerfile
if [ ! -f "Dockerfile" ]; then
  error_exit "No Dockerfile found. Please include one in your project."
fi

# Step 4: SSH Connection Test
log "Testing SSH connection..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo SSH connection successful" || error_exit "SSH connection failed."

# Step 5: Prepare Remote Environment
log "Preparing remote environment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
sudo apt update -y
sudo apt install -y docker.io nginx
sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl enable nginx
sudo systemctl start nginx
EOF

# Step 6: Deploy Application
log "Deploying Dockerized app..."
scp -i "$SSH_KEY" -r . "$SSH_USER@$SERVER_IP:/home/$SSH_USER/app"

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
cd /home/$SSH_USER/app
sudo docker stop hng-app || true
sudo docker rm hng-app || true
sudo docker build -t hng-app .
sudo docker run -d -p $APP_PORT:$APP_PORT --name hng-app hng-app
EOF

# Step 7: Configure Nginx Reverse Proxy
log "Configuring Nginx reverse proxy..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
sudo bash -c 'cat > /etc/nginx/sites-available/hng-app <<NGINX_CONF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX_CONF'
sudo ln -sf /etc/nginx/sites-available/hng-app /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
EOF

# Step 8: Validate Deployment
log "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "curl -I localhost" || error_exit "App validation failed."

log "✅ Deployment successful! Visit http://$SERVER_IP"
