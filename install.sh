#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# ----------------------------
# Color Codes for Echo Messages
# ----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

echo -e "${CYAN}----------------------------------------------------------"
echo "----------------------------------------------------------"
echo "              Kamikazce - Frappe/ERPNext v16              "
echo "----------------------------------------------------------"
echo -e "----------------------------------------------------------${NC}"

# ----------------------------
# Generate Unique Identifier
# ----------------------------
UNIQUE_ID=$(date +%s%N | sha256sum | head -c 8)
echo -e "${BLUE}Generated Unique ID: $UNIQUE_ID${NC}"

# ----------------------------
# Function Definitions
# ----------------------------

# Function to prompt for MariaDB password
prompt_for_mariadb_password() {
    while true; do
        echo -ne "${YELLOW}Enter the desired password for MariaDB root user:${NC} "
        read -s mariadb_password
        echo
        echo -ne "${YELLOW}Confirm the MariaDB root password:${NC} "
        read -s mariadb_password_confirm
        echo
        if [ "$mariadb_password" = "$mariadb_password_confirm" ]; then
            break
        else
            echo -e "${RED}Passwords do not match. Please try again.${NC}"
        fi
    done
}

# Function to prompt for administrator password
prompt_for_admin_password() {
    while true; do
        echo -ne "${YELLOW}Enter the desired Frappe administrator password:${NC} "
        read -s admin_password
        echo
        echo -ne "${YELLOW}Confirm the Frappe administrator password:${NC} "
        read -s admin_password_confirm
        echo
        if [ "$admin_password" = "$admin_password_confirm" ]; then
            break
        else
            echo -e "${RED}Passwords do not match. Please try again.${NC}"
        fi
    done
}

# ----------------------------
# Check Root Privileges
# ----------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root. Please run with sudo or as root.${NC}"
    exit 1
fi

# ----------------------------
# Collect All Inputs at the Start
# ----------------------------

# Prompt to create a new user
echo -ne "${YELLOW}Do you want to create a new user? (yes/no):${NC} "
read create_user
if [ "$create_user" = "yes" ]; then
    echo -ne "${YELLOW}Enter the new username:${NC} "
    read new_username
    if id "$new_username" &>/dev/null; then
        echo -e "${YELLOW}User '$new_username' already exists.${NC}"
    else
        adduser "$new_username"
        usermod -aG sudo "$new_username"
        echo -e "${GREEN}New user '$new_username' created and added to the sudo group.${NC}"
    fi
    username="$new_username"
else
    username=$(logname 2>/dev/null || echo "$SUDO_USER")
fi

# ----------------------------
# MariaDB: Check existing installation
# ----------------------------
MARIADB_ALREADY_INSTALLED=false
MARIADB_HAS_ROOT_PASSWORD=false

if command -v mariadb &>/dev/null || command -v mysql &>/dev/null; then
    echo -e "${YELLOW}MariaDB is already installed on this system.${NC}"
    MARIADB_ALREADY_INSTALLED=true

    # Check if root can connect without password
    if mysql -u root --connect-timeout=5 -e "SELECT 1;" &>/dev/null 2>&1; then
        echo -e "${YELLOW}MariaDB root has no password set (or uses unix_socket auth).${NC}"
        MARIADB_HAS_ROOT_PASSWORD=false
    else
        echo -e "${YELLOW}MariaDB root already has a password configured.${NC}"
        MARIADB_HAS_ROOT_PASSWORD=true
        echo -ne "${YELLOW}Enter the existing MariaDB root password:${NC} "
        read -s mariadb_password
        echo
        # Verify the provided password
        if ! mysql -u root -p"$mariadb_password" --connect-timeout=5 -e "SELECT 1;" &>/dev/null 2>&1; then
            echo -e "${RED}Incorrect MariaDB root password. Aborting.${NC}"
            exit 1
        fi
        echo -e "${GREEN}MariaDB root password verified successfully.${NC}"
    fi
else
    echo -e "${BLUE}MariaDB not found. Will install MariaDB 11.8.${NC}"
fi

# Prompt for new MariaDB password only if not already set
if [ "$MARIADB_HAS_ROOT_PASSWORD" = false ] && [ "$MARIADB_ALREADY_INSTALLED" = false ]; then
    prompt_for_mariadb_password
elif [ "$MARIADB_HAS_ROOT_PASSWORD" = false ] && [ "$MARIADB_ALREADY_INSTALLED" = true ]; then
    echo -e "${YELLOW}No root password is set. Please set a new MariaDB root password:${NC}"
    prompt_for_mariadb_password
fi

# Prompt for Frappe admin password
prompt_for_admin_password

# Prompt for site name
echo -ne "${YELLOW}Enter the name of the site to create:${NC} "
read site_name

# Optional Installation of ERPNext
echo -ne "${YELLOW}Do you want to install ERPNext? (yes/no):${NC} "
read install_erpnext

# Optional Installation of HRMS
echo -ne "${YELLOW}Do you want to install HRMS? (yes/no):${NC} "
read install_hrms

# ----------------------------
# Export Variables
# ----------------------------
export username
export mariadb_password
export admin_password
export site_name
export install_erpnext
export install_hrms
export UNIQUE_ID

# ----------------------------
# Update and Upgrade System
# ----------------------------
echo -e "${BLUE}Updating and upgrading the system...${NC}"
apt-get update -y
apt-get upgrade -y
apt-get install -y apt-transport-https curl lsb-release gnupg ca-certificates \
    software-properties-common git pkg-config libmariadb-dev

# ----------------------------
# Install MariaDB 11.8 (skip if already installed)
# ----------------------------
install_mariadb() {
    echo -e "${BLUE}Installing MariaDB Server 11.8...${NC}"
    curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup -o mariadb_repo_setup
    chmod +x mariadb_repo_setup
    bash ./mariadb_repo_setup --mariadb-server-version="mariadb-11.8"
    rm mariadb_repo_setup
    apt-get update -y
    apt-get install -y mariadb-server mariadb-backup mariadb-client
    echo -e "${GREEN}MariaDB 11.8 installed successfully.${NC}"
}

if [ "$MARIADB_ALREADY_INSTALLED" = false ]; then
    install_mariadb
else
    echo -e "${YELLOW}Skipping MariaDB installation (already installed).${NC}"
    # Ensure MariaDB service is running
    systemctl start mariadb 2>/dev/null || true
fi

# ----------------------------
# Configure MariaDB (charset + secure)
# ----------------------------
configure_mariadb() {
    echo -e "${BLUE}Configuring MariaDB settings...${NC}"

    CUSTOM_CNF="/etc/mysql/mariadb.conf.d/99-frappe.cnf"
    cat <<EOF > "$CUSTOM_CNF"
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
character-set-client-handshake = FALSE
bind-address = 127.0.0.1

[client]
default-character-set = utf8mb4
EOF

    systemctl restart mariadb
    sleep 3
    echo -e "${GREEN}MariaDB configured.${NC}"
}

configure_mariadb

# ----------------------------
# Secure MariaDB (only if no password was set before)
# ----------------------------
secure_mariadb() {
    echo -e "${BLUE}Securing MariaDB installation...${NC}"
    mysql -u root <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
ALTER USER 'root'@'localhost' IDENTIFIED BY '$mariadb_password';
FLUSH PRIVILEGES;
EOF
    echo -e "${GREEN}MariaDB secured successfully.${NC}"
}

if [ "$MARIADB_HAS_ROOT_PASSWORD" = false ]; then
    secure_mariadb
else
    echo -e "${YELLOW}Skipping MariaDB secure step (password already configured).${NC}"
fi

# ----------------------------
# Install Redis
# ----------------------------
echo -e "${BLUE}Installing Redis...${NC}"
apt-get install -y redis-server
systemctl enable redis-server
systemctl start redis-server

# ----------------------------
# Install wkhtmltopdf
# ----------------------------
echo -e "${BLUE}Installing wkhtmltopdf...${NC}"
apt-get install -y xvfb libfontconfig

ARCH=$(dpkg --print-architecture)
DISTRO_CODENAME=$(lsb_release -cs)

# Map codename for supported builds
case "$DISTRO_CODENAME" in
    noble|jammy|focal)
        WKHTML_DEB="wkhtmltox_0.12.6.1-2.${DISTRO_CODENAME}_${ARCH}.deb"
        WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/${WKHTML_DEB}"
        ;;
    *)
        # Fallback to jammy build
        WKHTML_DEB="wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
        WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/${WKHTML_DEB}"
        ;;
esac

if ! command -v wkhtmltopdf &>/dev/null; then
    wget -q "$WKHTML_URL" -O "$WKHTML_DEB"
    apt-get install -y "./$WKHTML_DEB"
    rm -f "$WKHTML_DEB"
    echo -e "${GREEN}wkhtmltopdf installed.${NC}"
else
    echo -e "${YELLOW}wkhtmltopdf already installed, skipping.${NC}"
fi

# ----------------------------
# Install nvm + Node.js 24 + yarn
# ----------------------------
echo -e "${BLUE}Installing nvm, Node.js 24, and yarn for user '$username'...${NC}"

USER_HOME=$(eval echo "~$username")

# Install nvm for the target user
sudo -H -u "$username" bash -c "
  export HOME=$USER_HOME
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
"

# Source nvm and install node 24
sudo -H -u "$username" bash -c "
  export HOME=$USER_HOME
  export NVM_DIR=\"$USER_HOME/.nvm\"
  source \"\$NVM_DIR/nvm.sh\"
  nvm install 24
  nvm alias default 24
  npm install -g yarn
  echo 'Node version:' \$(node -v)
  echo 'Yarn version:' \$(yarn -v)
"

# Make node/yarn available system-wide via symlinks
NODE_BIN=$(sudo -H -u "$username" bash -c "
  export HOME=$USER_HOME
  export NVM_DIR=\"$USER_HOME/.nvm\"
  source \"\$NVM_DIR/nvm.sh\"
  which node
")
YARN_BIN=$(sudo -H -u "$username" bash -c "
  export HOME=$USER_HOME
  export NVM_DIR=\"$USER_HOME/.nvm\"
  source \"\$NVM_DIR/nvm.sh\"
  which yarn
")

ln -sf "$NODE_BIN" /usr/local/bin/node 2>/dev/null || true
ln -sf "$YARN_BIN" /usr/local/bin/yarn 2>/dev/null || true
echo -e "${GREEN}Node.js 24 and yarn installed.${NC}"

# ----------------------------
# Install uv + Python 3.14
# ----------------------------
echo -e "${BLUE}Installing uv and Python 3.14 for user '$username'...${NC}"

sudo -H -u "$username" bash -c "
  export HOME=$USER_HOME
  curl -LsSf https://astral.sh/uv/install.sh | sh
"

# Add uv to PATH and install Python 3.14
sudo -H -u "$username" bash -c "
  export HOME=$USER_HOME
  export PATH=\"$USER_HOME/.local/bin:\$PATH\"
  uv python install 3.14 --default
  echo 'Python version:' \$(uv run python --version)
"

# Symlink python3 to uv-managed python if needed
PYTHON_BIN=$(sudo -H -u "$username" bash -c "
  export HOME=$USER_HOME
  export PATH=\"$USER_HOME/.local/bin:\$PATH\"
  uv python find 3.14
" 2>/dev/null || echo "")

if [ -n "$PYTHON_BIN" ]; then
    ln -sf "$PYTHON_BIN" /usr/local/bin/python3.14 2>/dev/null || true
    echo -e "${GREEN}Python 3.14 available at: $PYTHON_BIN${NC}"
fi

# ----------------------------
# Install Bench CLI via uv
# ----------------------------
echo -e "${BLUE}Installing frappe-bench via uv tool...${NC}"

sudo -H -u "$username" bash -c "
  export HOME=$USER_HOME
  export PATH=\"$USER_HOME/.local/bin:\$PATH\"
  uv tool install frappe-bench
  echo 'Bench version:' \$(bench --version 2>/dev/null || echo 'check PATH')
"

# Symlink bench globally
BENCH_BIN="$USER_HOME/.local/bin/bench"
ln -sf "$BENCH_BIN" /usr/local/bin/bench 2>/dev/null || true

# ----------------------------
# Set Up Bench Directory
# ----------------------------
echo -e "${BLUE}Setting up Bench environment...${NC}"

if [ ! -d "/var/bench" ]; then
    mkdir /var/bench
fi
chown -R "$username":"$username" /var/bench

# ----------------------------
# Initialize Frappe Bench v16
# ----------------------------
echo -e "${BLUE}Initializing Frappe Bench Version 16...${NC}"

BENCH_DIR="frappe-bench16_${UNIQUE_ID}"

sudo -H -u "$username" bash -c "
  export HOME=$USER_HOME
  export PATH=\"$USER_HOME/.local/bin:$USER_HOME/.nvm/versions/node/\$(ls $USER_HOME/.nvm/versions/node/ | sort -V | tail -1)/bin:\$PATH\"
  export NVM_DIR=\"$USER_HOME/.nvm\"
  source \"\$NVM_DIR/nvm.sh\" 2>/dev/null || true
  cd /var/bench
  bench init --verbose \
    --frappe-path https://github.com/frappe/frappe \
    --frappe-branch version-16 \
    --python \$(uv python find 3.14 2>/dev/null || echo python3.14) \
    $BENCH_DIR
"

echo -e "${GREEN}Frappe Bench v16 initialized at /var/bench/$BENCH_DIR${NC}"

# ----------------------------
# Create New Site
# ----------------------------
echo -e "${BLUE}Creating new site '$site_name'...${NC}"

sudo -H -u "$username" bash -c "
  export HOME=$USER_HOME
  export PATH=\"$USER_HOME/.local/bin:$USER_HOME/.nvm/versions/node/\$(ls $USER_HOME/.nvm/versions/node/ | sort -V | tail -1)/bin:\$PATH\"
  export NVM_DIR=\"$USER_HOME/.nvm\"
  source \"\$NVM_DIR/nvm.sh\" 2>/dev/null || true
  cd /var/bench/$BENCH_DIR
  bench new-site '$site_name' \
    --db-root-password '$mariadb_password' \
    --admin-password '$admin_password'
  bench use '$site_name'
  bench enable-scheduler
  bench set-config developer_mode 1
  bench --site '$site_name' set-maintenance-mode off
"

echo -e "${GREEN}Site '$site_name' created successfully.${NC}"

# ----------------------------
# Install ERPNext v16 (optional)
# ----------------------------
if [ "$install_erpnext" = "yes" ]; then
    echo -e "${BLUE}Installing ERPNext for Frappe Version 16...${NC}"
    sudo -H -u "$username" bash -c "
      export HOME=$USER_HOME
      export PATH=\"$USER_HOME/.local/bin:$USER_HOME/.nvm/versions/node/\$(ls $USER_HOME/.nvm/versions/node/ | sort -V | tail -1)/bin:\$PATH\"
      export NVM_DIR=\"$USER_HOME/.nvm\"
      source \"\$NVM_DIR/nvm.sh\" 2>/dev/null || true
      cd /var/bench/$BENCH_DIR
      bench get-app erpnext --branch version-16
      bench --site '$site_name' install-app erpnext
    "
    echo -e "${GREEN}ERPNext v16 installed successfully.${NC}"
else
    echo -e "${YELLOW}Skipping ERPNext installation.${NC}"
fi

# ----------------------------
# Install HRMS v16 (optional)
# ----------------------------
if [ "$install_hrms" = "yes" ]; then
    echo -e "${BLUE}Installing HRMS for Frappe Version 16...${NC}"
    sudo -H -u "$username" bash -c "
      export HOME=$USER_HOME
      export PATH=\"$USER_HOME/.local/bin:$USER_HOME/.nvm/versions/node/\$(ls $USER_HOME/.nvm/versions/node/ | sort -V | tail -1)/bin:\$PATH\"
      export NVM_DIR=\"$USER_HOME/.nvm\"
      source \"\$NVM_DIR/nvm.sh\" 2>/dev/null || true
      cd /var/bench/$BENCH_DIR
      bench get-app hrms --branch version-16
      bench --site '$site_name' install-app hrms
    "
    echo -e "${GREEN}HRMS v16 installed successfully.${NC}"
else
    echo -e "${YELLOW}Skipping HRMS installation.${NC}"
fi

# ----------------------------
# Configure System for Redis
# ----------------------------
echo -e "${BLUE}Configuring system for Redis optimizations...${NC}"
echo 'never' | tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null 2>&1 || true

grep -qxF 'vm.overcommit_memory = 1' /etc/sysctl.conf || echo 'vm.overcommit_memory = 1' | tee -a /etc/sysctl.conf
sysctl -w vm.overcommit_memory=1 > /dev/null

grep -qxF 'net.core.somaxconn = 511' /etc/sysctl.conf || echo 'net.core.somaxconn = 511' | tee -a /etc/sysctl.conf
sysctl -w net.core.somaxconn=511 > /dev/null

# ----------------------------
# Installation Summary
# ----------------------------
echo -e "${MAGENTA}#######################"
echo "##  Installation Complete  ##"
echo -e "#######################${NC}"
echo -e "${GREEN}✔  Frappe / ERPNext version  : 16"
echo "✔  MariaDB                   : 11.8"
echo "✔  Python                    : 3.14 (via uv)"
echo "✔  Node.js                   : 24 (via nvm)"
echo "✔  Bench directory           : /var/bench/$BENCH_DIR"
echo "✔  Site                      : $site_name"
echo ""
echo "To start the bench, switch to user '$username' and run:"
echo -e "${NC}${YELLOW}  sudo su - $username"
echo "  cd /var/bench/$BENCH_DIR"
echo -e "  bench start${NC}"
echo -e "${MAGENTA}#######################${NC}"
