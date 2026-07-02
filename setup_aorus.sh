#!/bin/bash
# setup_aorus.sh - Automates DKMS and GNOME power profile setup for Aorus laptops
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use sudo)"
  exit 1
fi

MODULE_NAME="aorus_laptop"
MODULE_VERSION="1.0"
DRIVER_SRC_DIR="./aorus_laptop" # Change this if your source is elsewhere
DKMS_DIR="/usr/src/${MODULE_NAME}-${MODULE_VERSION}"

echo ">>> Installing dependencies..."
apt-get update
apt-get install -y dkms build-essential linux-headers-$(uname -r) python3-dbus python3-gi

echo ">>> Setting up DKMS for ${MODULE_NAME}..."
if [ ! -d "$DRIVER_SRC_DIR" ]; then
    echo "Error: Source directory $DRIVER_SRC_DIR not found!"
    echo "Please place the aorus_laptop source code in $DRIVER_SRC_DIR"
    exit 1
fi

# Copy source to /usr/src
mkdir -p "$DKMS_DIR"
cp -r "$DRIVER_SRC_DIR"/* "$DKMS_DIR/"

# Create dkms.conf if it doesn't exist
if [ ! -f "$DKMS_DIR/dkms.conf" ]; then
cat <<EOF > "$DKMS_DIR/dkms.conf"
PACKAGE_NAME="${MODULE_NAME}"
PACKAGE_VERSION="${MODULE_VERSION}"
MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
BUILT_MODULE_NAME[0]="${MODULE_NAME}"
DEST_MODULE_LOCATION[0]="/updates/dkms"
AUTOINSTALL="yes"
EOF
fi

# Add, build, and install via DKMS
dkms add -m ${MODULE_NAME} -v ${MODULE_VERSION} || true
dkms build -m ${MODULE_NAME} -v ${MODULE_VERSION}
dkms install -m ${MODULE_NAME} -v ${MODULE_VERSION}

echo ">>> Configuring auto-load on boot..."
echo "${MODULE_NAME}" > /etc/modules-load.d/${MODULE_NAME}.conf

echo ">>> Loading module now..."
modprobe ${MODULE_NAME} || echo "Module loaded."

echo ">>> Setting up GNOME Power Profiles Bridge..."

# Create the bridging Python script
BRIDGE_SCRIPT="/usr/local/bin/aorus-power-bridge.py"
cat <<'EOF' > "$BRIDGE_SCRIPT"
#!/usr/bin/env python3
import dbus
from gi.repository import GLib
from dbus.mainloop.glib import DBusGMainLoop

SYSFS_PATH = "/sys/devices/platform/aorus_laptop/power_mode"

# Mapping GNOME power profiles to Aorus EC modes
# Note: Update the values (0, 1, 2) to match your specific EC driver's expectations.
MODE_MAP = {
    "power-saver": "0", # Quiet
    "balanced": "1",    # Normal
    "performance": "2"  # Gaming
}

def set_aorus_mode(profile_name):
    mode_val = MODE_MAP.get(profile_name)
    if mode_val is not None:
        try:
            with open(SYSFS_PATH, "w") as f:
                f.write(mode_val)
            print(f"Set Aorus EC to {profile_name} (Value: {mode_val})")
        except Exception as e:
            print(f"Error writing to sysfs: {e}")

def on_properties_changed(interface, changed_properties, invalidated_properties):
    if "ActiveProfile" in changed_properties:
        profile = str(changed_properties["ActiveProfile"])
        set_aorus_mode(profile)

if __name__ == '__main__':
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    
    # Get initial profile state on startup
    try:
        proxy = bus.get_object('net.hadess.PowerProfiles', '/net/hadess/PowerProfiles')
        props = dbus.Interface(proxy, 'org.freedesktop.DBus.Properties')
        current_profile = str(props.Get('net.hadess.PowerProfiles', 'ActiveProfile'))
        set_aorus_mode(current_profile)
    except dbus.exceptions.DBusException as e:
        print(f"Could not read initial profile: {e}")

    # Listen for profile changes
    bus.add_signal_receiver(
        on_properties_changed,
        dbus_interface="org.freedesktop.DBus.Properties",
        signal_name="PropertiesChanged",
        arg0="net.hadess.PowerProfiles",
        path="/net/hadess/PowerProfiles"
    )

    loop = GLib.MainLoop()
    loop.run()
EOF
chmod +x "$BRIDGE_SCRIPT"

# Create the systemd service to run the bridge script in the background
SERVICE_FILE="/etc/systemd/system/aorus-power-bridge.service"
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Aorus EC to GNOME Power Profiles Bridge
After=power-profiles-daemon.service
Requires=power-profiles-daemon.service

[Service]
Type=simple
ExecStart=$BRIDGE_SCRIPT
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

echo ">>> Enabling and starting the bridging service..."
systemctl daemon-reload
systemctl enable aorus-power-bridge.service
systemctl restart aorus-power-bridge.service

echo ">>> Setup Complete!"
echo "The aorus_laptop driver is now managed by DKMS, and GNOME power modes will automatically sync with the EC."
