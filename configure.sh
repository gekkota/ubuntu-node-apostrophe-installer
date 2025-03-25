#!/bin/bash
# Launch Script for Apostrophe CMS on Ubuntu 24.4 (AWS Lightsail)
# This script installs Node.js, nginx, varnish, PM2; creates (or reconfigures) an app user,
# sets up a Bitbucket deploy key, and writes a deploy script for your repository.
#
# NOTE: This script must be run with sudo.
# Customize the variables below as needed.

# Check if script is running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run with sudo or as root. Please run: sudo $0"
    exit 1
fi

#############################
# CONFIGURATION VARIABLES   #
#############################
REPO_URL="git@bitbucket.org:lev_lev/entertainers.git"  # Use SSH URL for Bitbucket
BRANCH="production"                                    # Branch to deploy from
PM2_INSTANCES=1                                        # Number of PM2 instances (1 or 2)
APP_USER="apos"                                        # Application user for running the CMS
APP_DIR="/var/www/apostrophe"                          # Directory for the Apostrophe CMS code
ENV_DIR="/opt/env"                                     # Directory for environment configuration
ENV_FILE="$ENV_DIR/apostrophe.env"                     # Environment file path
DEPLOY_SCRIPTS_DIR="/home/apos/deploy-scripts"         # Directory for deployment scripts
LOG_FILE="/var/log/apostrophe_setup.log"               # Log file location

# load environment variables from .env file
set -o allexport
[[ -f .env ]] && source .env
set +o allexport

#############################
# LOGGING FUNCTIONS         #
#############################
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

run_command() {
    log_message "EXECUTING: $1"
    eval "$1"
    local status=$?
    if [ $status -eq 0 ]; then
        log_message "SUCCESS: Command executed successfully"
    else
        log_message "ERROR: Command failed with status $status"
    fi
    return $status
}

log_message "==== APOSTROPHE CMS SETUP SCRIPT STARTED ===="
log_message "Log file is located at: $LOG_FILE"

#############################
# SYSTEM UPDATE & NODE.JS   #
#############################
log_message "SECTION: System update and Node.js installation"
# Set noninteractive mode for apt
export DEBIAN_FRONTEND=noninteractive
run_command "apt update && apt upgrade -y"
log_message "Installing Node.js 22.x..."
run_command "curl -sL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh"
run_command "bash /tmp/nodesource_setup.sh"
run_command "apt install nodejs -y"

#############################
# INSTALL NGINX & VARNISH   #
#############################
log_message "SECTION: Installing and configuring nginx and varnish"
run_command "apt install nginx varnish -y"

#############################
# CONFIGURE NPM GLOBAL PATH (for root) #
#############################
log_message "SECTION: Configuring NPM global path for root"
run_command "mkdir -p /root/.npm-global"
run_command "npm config set prefix '/root/.npm-global'"
run_command "echo 'export PATH=/root/.npm-global/bin:\$PATH' >> /root/.profile"
run_command "source /root/.profile"

#############################
# INSTALL PM2 (for root, temporary)  #
#############################
log_message "SECTION: Installing PM2 globally for root"
run_command "npm install -g pm2"

#############################
# CREATE APP USER & DIRECTORIES    #
#############################
log_message "SECTION: Creating application user and directories"
# If the user already exists, this command may warn – that is acceptable.
run_command "adduser --disabled-password --gecos \"\" --home /home/apos \"$APP_USER\""
# Ensure /home/apos exists and is owned by apos
run_command "mkdir -p /home/apos"
run_command "chown -R \"$APP_USER\":\"$APP_USER\" /home/apos"
run_command "mkdir -p \"$APP_DIR\""
run_command "chown -R \"$APP_USER\":\"$APP_USER\" \"$APP_DIR\""

#############################
# SETUP NPM GLOBAL FOR APOS  #
#############################
log_message "SECTION: Setting up npm global directory for $APP_USER"
run_command "sudo -u \"$APP_USER\" mkdir -p /home/apos/.npm-global"
run_command "sudo -u \"$APP_USER\" npm config set prefix '/home/apos/.npm-global'"
# Create .bashrc (if not exists) and add the npm bin path
run_command "touch /home/apos/.bashrc"
run_command "chown $APP_USER:$APP_USER /home/apos/.bashrc"
run_command "echo 'export PATH=/home/apos/.npm-global/bin:\$PATH' | sudo tee -a /home/apos/.profile"
run_command "echo 'export PATH=/home/apos/.npm-global/bin:\$PATH' | sudo tee -a /home/apos/.bashrc"
run_command "mkdir -p /home/apos/.npm"
run_command "chown -R \"$APP_USER\":\"$APP_USER\" /home/apos/.npm"

#############################
# INSTALL PM2 AS APOS      #
#############################
log_message "SECTION: Installing PM2 for $APP_USER"
run_command "sudo -u \"$APP_USER\" bash -c 'export PATH=/home/apos/.npm-global/bin:\$PATH && npm install -g pm2'"
run_command "sudo -u \"$APP_USER\" bash -c 'export PATH=/home/apos/.npm-global/bin:\$PATH && pm2 --version'"

#############################
# SETUP SSH FOR APOS        #
#############################
log_message "SECTION: Setting up SSH authorized_keys for $APP_USER"
run_command "mkdir -p /home/$APP_USER/.ssh"
if [ -f /root/.ssh/authorized_keys ]; then
    log_message "Copying root's authorized_keys to $APP_USER"
    run_command "cp /root/.ssh/authorized_keys /home/$APP_USER/.ssh/"
fi
run_command "chown -R \"$APP_USER\":\"$APP_USER\" /home/$APP_USER/.ssh"
run_command "chmod 700 /home/$APP_USER/.ssh"
run_command "chmod 600 /home/$APP_USER/.ssh/authorized_keys"

#############################
# VARNISH CONFIGURATION     #
#############################
log_message "SECTION: Configuring Varnish"
cat <<'EOF' > /etc/default/varnish
# Default settings for varnish
START=yes
NFILES=131072
MEMLOCK=82000
DAEMON_OPTS="-a :80 \
-T localhost:6082 \
-f /etc/varnish/default.vcl \
-S /etc/varnish/secret \
-s malloc,256m"
EOF

cat <<'EOF' > /etc/varnish/default.vcl
vcl 4.0;

backend default {
    .host = "127.0.0.1";
    .port = "3000";
}
EOF

if [ ! -f /etc/varnish/secret ]; then
    log_message "Creating Varnish secret file"
    run_command "echo \"randomsecret\" > /etc/varnish/secret"
    run_command "chmod 600 /etc/varnish/secret"
fi

log_message "Restarting and enabling Varnish service"
run_command "systemctl daemon-reload"
run_command "systemctl restart varnish"
run_command "systemctl enable varnish"

#############################
# SETUP ENVIRONMENT FILE    #
#############################
log_message "SECTION: Creating environment file for Apostrophe CMS"
run_command "mkdir -p \"$ENV_DIR\""
log_message "Writing environment variables to $ENV_FILE"
cat <<EOF > "$ENV_FILE"
NODE_ENV=production
PORT=3000
# Add ENV_VARS below:
ENVIRONMENT=$ENVIRONMENT
PROJECT_SHORTNAME=$PROJECT_SHORTNAME
BASE_URL=$BASE_URL
MONGODB_URI=$MONGODB_URI
APOS_STORAGE=$APOS_STORAGE
S3_BUCKET_NAME=$S3_BUCKET_NAME
S3_BUCKET_REGION=$S3_BUCKET_REGION
S3_ACCESS_KEY=$S3_ACCESS_KEY
S3_SECRET=$S3_SECRET
CDN_ADDRESS=$CDN_ADDRESS
EOF
if [ -n "$NEW_RELIC_LICENSE_KEY" ]; then
    echo "NEW_RELIC_LICENSE_KEY=$NEW_RELIC_LICENSE_KEY" >> "$ENV_FILE"
fi
run_command "chmod 600 \"$ENV_FILE\""
run_command "chown apos:apos \"$ENV_FILE\""

#############################
# CREATE DEPLOY SCRIPT      #
#############################
log_message "SECTION: Writing deployment script"
run_command "mkdir -p \"$DEPLOY_SCRIPTS_DIR\""
run_command "chown -R \"$APP_USER\":\"$APP_USER\" \"$DEPLOY_SCRIPTS_DIR\""
log_message "Creating deployment script at $DEPLOY_SCRIPTS_DIR/deploy.sh"
cat <<'EOF' > "$DEPLOY_SCRIPTS_DIR/deploy.sh"
#!/bin/bash
# Deployment Script for Apostrophe CMS
# Run as the apos user. This script pulls the latest code from the repository,
# installs dependencies, links the environment file, and restarts the app using PM2.

# Ensure the correct PATH so that pm2 is found (using apos' npm global directory)
export PATH="/home/apos/.npm-global/bin:$PATH"

REPO_URL="__REPO_URL__"
BRANCH="__BRANCH__"
APP_DIR="/var/www/apostrophe"
# The environment file will be substituted by the setup script
ENV_FILE="__ENV_FILE__"
DEPLOY_LOG="/home/apos/apostrophe_deploy.log"

mkdir -p "$(dirname "$DEPLOY_LOG")"
touch "$DEPLOY_LOG"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$DEPLOY_LOG"
}

run_command() {
    log_message "EXECUTING: $1"
    eval "$1"
    local status=$?
    if [ $status -eq 0 ]; then
        log_message "SUCCESS: Command executed successfully"
    else
        log_message "ERROR: Command failed with status $status"
    fi
    return $status
}

log_message "==== APOSTROPHE CMS DEPLOYMENT STARTED ===="
log_message "Deploying branch $BRANCH from $REPO_URL"

if [ ! -d "$APP_DIR/.git" ]; then
    log_message "Repository not found. Cloning for the first time..."
    run_command "git clone -b \"$BRANCH\" \"$REPO_URL\" \"$APP_DIR\""
else
    log_message "Repository exists. Updating to latest version..."
    run_command "cd \"$APP_DIR\" && git fetch"
    run_command "cd \"$APP_DIR\" && git checkout \"$BRANCH\""
    run_command "cd \"$APP_DIR\" && git pull origin \"$BRANCH\""
fi

log_message "Linking environment file into application directory..."
run_command "ln -sf \"__ENV_FILE__\" \"$APP_DIR/.env\""
run_command "chown -h \"$APP_USER\":\"$APP_USER\" \"$APP_DIR/.env\""

log_message "Installing dependencies..."
run_command "cd \"$APP_DIR\" && npm install"

log_message "Restarting application with PM2..."
run_command "pm2 delete apostrophe 2>/dev/null || true"
# Use app.js as the entry point for your application
run_command "pm2 start app.js --name apostrophe -i __PM2_INSTANCES__"

log_message "==== APOSTROPHE CMS DEPLOYMENT COMPLETED ===="
EOF

log_message "Configuring the deployment script with custom variables"
run_command "sed -i \"s|__REPO_URL__|$REPO_URL|g\" \"$DEPLOY_SCRIPTS_DIR/deploy.sh\""
run_command "sed -i \"s|__BRANCH__|$BRANCH|g\" \"$DEPLOY_SCRIPTS_DIR/deploy.sh\""
run_command "sed -i \"s|__PM2_INSTANCES__|$PM2_INSTANCES|g\" \"$DEPLOY_SCRIPTS_DIR/deploy.sh\""
run_command "sed -i \"s|__ENV_FILE__|$ENV_FILE|g\" \"$DEPLOY_SCRIPTS_DIR/deploy.sh\""
run_command "chmod +x \"$DEPLOY_SCRIPTS_DIR/deploy.sh\""

#############################
# SETUP SSH CONFIG FOR APOS #
#############################
log_message "SECTION: Setting up SSH config for $APP_USER"
cat <<'EOF' > /home/apos/.ssh/config
Host bitbucket.org
    IdentityFile ~/.ssh/bitbucket_deploy_key
    StrictHostKeyChecking no
EOF
run_command "chown $APP_USER:$APP_USER /home/apos/.ssh/config"
run_command "chmod 600 /home/apos/.ssh/config"

#############################
# SETUP BITBUCKET DEPLOY KEY#
#############################
log_message "SECTION: Setting up Bitbucket deploy key for $APP_USER"
if [ ! -f /home/apos/.ssh/bitbucket_deploy_key ]; then
    log_message "Generating new SSH deploy key for Bitbucket"
    run_command "sudo -u \"$APP_USER\" ssh-keygen -t ed25519 -C \"aws-lightsail-deploy\" -f /home/apos/.ssh/bitbucket_deploy_key -N \"\""
    log_message "Bitbucket deploy key generated."
    log_message "The public key is saved at /home/apos/.ssh/bitbucket_deploy_key.pub."
    log_message "Please add its contents to your Bitbucket repository's deployment keys:"
    cat /home/apos/.ssh/bitbucket_deploy_key.pub
    read -p "Press Enter to continue after adding the deploy key to Bitbucket..."
fi

#############################
# RUN DEPLOY SCRIPT         #
#############################
log_message "SECTION: Running the deployment script as $APP_USER"
run_command "sudo -u \"$APP_USER\" \"$DEPLOY_SCRIPTS_DIR/deploy.sh\""

#############################
# CLEAN UP                  #
#############################
log_message "SECTION: Cleaning up"
run_command "apt autoremove -y"

log_message "==== APOSTROPHE CMS SETUP SCRIPT COMPLETED ===="
log_message "Your Apostrophe CMS site should now be set up and running."
echo "Setup completed successfully! A detailed log has been saved to: $LOG_FILE"