#!/bin/bash
# Automates the installation of the Splunk Universal Forwarder. Currently set to v9.1.1, but that is easily changed.
# Works with Debian, Ubuntu, CentOS, Fedora, and Oracle Linux. You need to run this as sudo

# This was put together as an amalgamation of code from my own work, other automatic installation scripts, and AI to tie everything together.
# Lots time went into this script. Be nice to it plz <3
#
# Samuel Brucker 2024-2025
#

# Define Splunk Forwarder variables
SPLUNK_VERSION="9.1.1"
SPLUNK_BUILD="64e843ea36b1"
SPLUNK_PACKAGE_TGZ="splunkforwarder-${SPLUNK_VERSION}-${SPLUNK_BUILD}-Linux-x86_64.tgz"
SPLUNK_DOWNLOAD_URL="https://download.splunk.com/products/universalforwarder/releases/${SPLUNK_VERSION}/linux/${SPLUNK_PACKAGE_TGZ}"
INSTALL_DIR="/opt/splunkforwarder"
INDEXER_IP="172.20.241.20"
RECEIVER_PORT="9997"
ADMIN_USERNAME="admin"
ADMIN_PASSWORD="Changeme1!"  # Replace with a secure password

# Make sure this is being ran as root or sudo
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root or with sudo."
    exit 1
fi

# Check the OS and install the necessary packageå
if [ -f /etc/os-release ]; then
  . /etc/os-release
else
  echo "Unable to detect the operating system. Aborting."
  exit 1
fi

# Output detected OS
echo "Detected OS ID: $ID"

# Function to create the Splunk user and group
create_splunk_user() {
  if ! id -u splunk &>/dev/null; then
    echo "Creating splunk user and group..."
    sudo groupadd splunk
    sudo useradd -r -g splunk -d $INSTALL_DIR splunk
  else
    echo "Splunk user already exists."
  fi
}

# Function to install Splunk Forwarder
install_splunk() {
  echo "Downloading Splunk Forwarder tarball..."
  wget -O $SPLUNK_PACKAGE_TGZ $SPLUNK_DOWNLOAD_URL

  echo "Extracting Splunk Forwarder tarball..."
  sudo tar -xvzf $SPLUNK_PACKAGE_TGZ -C /opt
  rm -f $SPLUNK_PACKAGE_TGZ

  echo "Setting permissions..."
  create_splunk_user
  sudo chown -R splunk:splunk $INSTALL_DIR
}

# Function to set admin credentials
set_admin_credentials() {
  echo "Setting admin credentials..."
  USER_SEED_FILE="$INSTALL_DIR/etc/system/local/user-seed.conf"
  sudo bash -c "cat > $USER_SEED_FILE" <<EOL
[user_info]
USERNAME = $ADMIN_USERNAME
PASSWORD = $ADMIN_PASSWORD
EOL
  sudo chown splunk:splunk $USER_SEED_FILE
  echo "Admin credentials set."
}

# Function to add basic monitors
setup_monitors() {
  echo "Setting up basic monitors for Splunk..."
  MONITOR_CONFIG="$INSTALL_DIR/etc/system/local/inputs.conf"

  sudo bash -c "cat > $MONITOR_CONFIG" <<EOL
[monitor:///var/log]
index = main
sourcetype = syslog

[monitor:///var/log/messages]
index = main
sourcetype = syslog

[monitor:///var/log/secure]
index = main
sourcetype = syslog

[monitor:///var/log/dmesg]
index = main
sourcetype = syslog

[monitor:///tmp/test.log]
index = main
sourcetype = test_log
EOL

  sudo chown splunk:splunk $MONITOR_CONFIG
  echo "Monitors added to inputs.conf."
}

# Function to configure the forwarder to send logs to the Splunk indexer
configure_forwarder() {
  echo "Configuring Splunk Universal Forwarder to send logs to $INDEXER_IP:$RECEIVER_PORT..."
  sudo $INSTALL_DIR/bin/splunk add forward-server $INDEXER_IP:$RECEIVER_PORT -auth $ADMIN_USERNAME:$ADMIN_PASSWORD
  echo "Forward-server configuration complete."
}

# Perform installation
install_splunk

# Set admin credentials before starting the service
set_admin_credentials

# Enable Splunk service and accept license agreement
if [ -d "$INSTALL_DIR/bin" ]; then
  echo "Starting and enabling Splunk Universal Forwarder service..."
  sudo $INSTALL_DIR/bin/splunk start --accept-license --answer-yes --no-prompt
  sudo $INSTALL_DIR/bin/splunk enable boot-start

  # Add basic monitors
  setup_monitors

  # Configure forwarder to send logs to the Splunk indexer
  configure_forwarder

  # Restart Splunk to apply configuration
  sudo $INSTALL_DIR/bin/splunk restart
else
  echo "Installation directory not found. Something went wrong."
  exit 1
fi

# Verify installation
sudo $INSTALL_DIR/bin/splunk version

echo "Splunk Universal Forwarder v$SPLUNK_VERSION installation complete with basic monitors and forwarder configuration!"

# CentOS-specific fixes
if [[ "$ID" == "centos" || "$ID_LIKE" == *"centos"* ]]; then
  echo "Applying CentOS-specific fixes..."
  
  # Remove AmbientCapabilities line from the systemd service file
  # This needs to be performed on every reboot, because CentOS. This section makes sure it's applied at install, so it can run immediately.
  SERVICE_FILE="/etc/systemd/system/SplunkForwarder.service"
  if [ -f "$SERVICE_FILE" ]; then
    sudo sed -i '/AmbientCapabilities/d' "$SERVICE_FILE"
    echo "Removed AmbientCapabilities line from $SERVICE_FILE"
  fi

# This makes turns the fix into a systemd service, which should hopefully catch the error on startup and eliminate any need to constantly implement the fix manually.
# Note that there is another Splunk error that I have not fixed. At least for my CentOS machines, if you turn off the Splunk service it will not turn back on without a reboot.
# Thus, for now, rebooting is the best way to fix the Splunk forwarder.

    # Create a systemd service to handle the fix
    FIX_SERVICE_FILE="/etc/systemd/system/splunk-fix.service"
  
# Create the service file
cat > "$FIX_SERVICE_FILE" <<EOL
[Unit]
Description=Splunk Fix Service
Before=network-online.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "/usr/bin/sed -i \'/AmbientCapabilities/d\' /etc/systemd/system/SplunkForwarder.service"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL

    # Enable and start the fix service
    echo "Enabling and starting the fix service"
    sudo systemctl daemon-reload
    sudo systemctl enable splunk-fix.service
    sudo systemctl start splunk-fix.service
    
    # Verify the fix service status
    echo "Verifying fix service status:"
    sudo systemctl status splunk-fix.service
    
    echo "Creating test log."
    echo "Test log entry" > /tmp/test.log
    sudo setfacl -m u:splunk:r /tmp/test.log
      
    # Reload systemd daemon
    echo "Reloading systemctl daemons"
    sudo systemctl daemon-reload
    
    # Run Splunk again  
    echo "Restarting the Splunk Forwarder"
    sudo systemctl restart SplunkForwarder
    
    echo "Restart complete, forwarder installation on CentOS complete" 
      
  else
      echo "Operating system not recognized as CentOS. Skipping CentOS fix."
  fi

# Fedora specific fix. The forwarder doesn't like to work when you install it. For some reason, rebooting just solves this so nicely
# I've looked for logs, tried starting it manually, etc. I couldn't figure it out and am running out of time. Therefore, this beautiful addition.
# This will reboot the machine after a 10 second timer. 
if [[ "$ID" == "fedora" ]]; then
    echo "Fedora system detected, initiating reboot in 10 seconds..."
    
    # Reboot with 10 second delay
    if ! sudo shutdown -r +0 "System will reboot in 10 seconds for Splunk configuration" & sleep 10; then
        echo "Warning: Graceful reboot failed, attempting forced reboot"
        if ! sudo reboot -f; then
            echo "Error: Unable to initiate reboot. Manual reboot required."
            exit 1
        fi
    fi
    exit 0
fi
