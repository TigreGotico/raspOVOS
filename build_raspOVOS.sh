#!/bin/bash
# Exit on error
# If something goes wrong just stop.
# it allows the user to see issues at once rather than having
# scroll back and figure out what went wrong.
set -e

# Rename the default 'pi' user if the current user is not 'pi'.
# Updates system configurations related to user, home directory, password, and group.
if [ "$USER" != "pi" ]; then
  # 1. Change the username in /etc/passwd
  echo "Renaming user in /etc/passwd..."
  sed -i "s/^pi:/$USER:/g" "/etc/passwd"

  # 2. Change the group name in /etc/group
  echo "Renaming user in /etc/group..."
  sed -i "s/\bpi\b/$USER/g" "/etc/group"

  # 3. Rename the home directory from /home/pi to /home/newuser
  echo "Renaming home directory..."
  # replace "pi"" with "$USER" in /etc/passwd
  sed -i "s|pi:|$USER:|g" "/etc/passwd"
  mv "/home/pi" "/home/$USER"

  # 4. Change ownership of the new home directory
  echo "Updating file ownership..."
  chown -R 1000:1000 "/home/$USER"

  # 5. Change the password in /etc/shadow
  echo "Changing user password to $PASSWORD..."
  NEW_HASHED_PASSWORD=$(openssl passwd -6 "$PASSWORD")
  echo "hashed password: $NEW_HASHED_PASSWORD..."
  sed -i "s#^pi:.*#$USER:$NEW_HASHED_PASSWORD:18720:0:99999:7:::#g" "/etc/shadow"

  # 6. don't let raspbian force to change username on first boot
  echo "Disabling first boot user setup wizard..."
  echo "$USER:$NEW_HASHED_PASSWORD" > /boot/firmware/userconf.txt
  chmod 600 /boot/firmware/userconf.txt

  # 7. Add the new user to the sudo group
  echo "Adding $USER to the sudo group..."
  sed -i "/^sudo:/s/pi/$USER/" /etc/group

  echo "User has been renamed, added to sudo group, and password updated."
fi

# Function to add a user to a specific group in /etc/group.
# If the group does not exist, it outputs an error message.
# If the user is not already a member of the group, it adds the user.
add_user_to_group() {
    local user=$1
    local group=$2

    # Check if the group exists
    if ! grep -q "^$group:" /etc/group; then
        echo "Group $group doesn't exist"
        return 1
    fi

    # Add the user to the group if not already a member
    if ! grep -q "^$group:.*\b$user\b" /etc/group; then
        echo "Adding $user to $group"
        sed -i "/^$group:/s/$/,$user/" /etc/group
    else
        echo "$user is already in $group"
    fi
}

# Add the current user to the 'ovos' group.
echo "Adding $USER to the ovos group..."
# Create the 'ovos' group if it doesn't exist
if ! getent group ovos > /dev/null; then
    groupadd ovos
fi
add_user_to_group $USER ovos

# Retrieve the GID of the 'ovos' group
GROUP_FILE="/etc/group"
TGID=$(awk -F: -v group="ovos" '$1 == group {print $3}' "$GROUP_FILE")

# Check if GID was successfully retrieved
if [[ -z "$TGID" ]]; then
    echo "Error: Failed to retrieve GID for group 'ovos'. Exiting..."
    exit 1
fi

echo "The GID for 'ovos' is: $TGID"

# Parse the UID of the current user from /etc/passwd
PASSWD_FILE="/etc/passwd"
TUID=$(awk -F: -v user="$USER" '$1 == user {print $3}' "$PASSWD_FILE")

# Check if UID was successfully retrieved
if [[ -z "$TUID" ]]; then
    echo "Error: Failed to retrieve UID for user '$USER'. Exiting..."
    exit 1
fi

echo "The UID for '$USER' is: $TUID"

# Update package list and install necessary system tools.
# Installs required packages and purges unnecessary ones.
echo "Updating base system..."
apt-get update
# NOTE: zram and mpd need to be installed here otherwise the cmd will hang prompting user about replacing files from overlays
apt-get install -y --no-install-recommends jq git unzip curl build-essential fake-hwclock userconf-pi fbi mosh systemd-zram-generator mpd

# Copy raspOVOS overlay to the system.
echo "Copying raspOVOS overlay..."
cp -rv /mounted-github-repo/overlays/base/* /
# Ensure the correct permissions for binaries
chmod +x /usr/libexec/ovos*
chmod +x /usr/local/bin/ovos*

echo "Installing audio packages..."
apt-get install -y --no-install-recommends pipewire pipewire-alsa alsa-utils portaudio19-dev libpulse-dev libasound2-dev

# NOTE: upmpdcli will only work after the overlays due to trusted keys being added there
echo "Installing extra system packages..."
apt-get install -y --no-install-recommends swig python3-dev python3-pip libssl-dev libfann-dev dirmngr python3-libcamera python3-kms++ libcap-dev kdeconnect mpv i2c-tools

# Install dependencies for system OVOS and related tools.
echo "Installing uv and sdnotify..."
pip install sdnotify uv --break-system-packages

# Modify /etc/fstab for performance optimization.
echo "Tuning /etc/fstab..."
bash /mounted-github-repo/scripts/setup_fstab.sh

echo "Updating ovos-i2csound and raspovos-audio-setup"
bash /mounted-github-repo/scripts/update.sh

# Install admin phal package and its dependencies.
echo "Installing admin phal..."
pip install ovos-bus-client ovos-phal ovos-PHAL-plugin-system -c $CONSTRAINTS --break-system-packages

# Create and activate a virtual environment for OVOS.
echo "Creating virtual environment..."
mkdir -p /home/$USER/.venvs
python3 -m venv --system-site-packages /home/$USER/.venvs/ovos
source /home/$USER/.venvs/ovos/bin/activate

# Install additional Python dependencies within the virtual environment.
uv pip install --no-progress wheel cython -c $CONSTRAINTS

# Install ggwave in the virtual environment.
echo "Installing ggwave..."
# NOTE: update this wheel if python version changes
uv pip install --no-progress https://whl.smartgic.io/ggwave-0.4.2-cp311-cp311-linux_aarch64.whl

# Install OVOS dependencies in the virtual environment.
echo "Installing OVOS..."
uv pip install --no-progress --pre ovos-docs-viewer ovos-utils[extras] ovos-dinkum-listener[extras,linux,onnx] tflite_runtime ovos-audio-transformer-plugin-ggwave ovos-phal ovos-audio[extras] ovos-gui ovos-core[lgpl,plugins] -c $CONSTRAINTS

# Install essential skills for OVOS.
echo "Installing skills..."
uv pip install --no-progress --pre ovos-core[skills-essential,skills-audio,skills-media,skills-internet,skills-extra] -c $CONSTRAINTS

# Install PHAL plugins for OVOS.
echo "Installing PHAL plugins..."
uv pip install --no-progress --pre ovos-phal[extras,linux,mk1] ovos-PHAL-plugin-dotstar ovos-phal-plugin-camera -c $CONSTRAINTS

# Install Spotify-related plugins for OVOS.
echo "Installing OVOS Spotify..."
uv pip install --no-progress --pre ovos-media-plugin-spotify ovos-skill-spotify -c $CONSTRAINTS

# Install deprecated OVOS packages for compatibility with older skills.
echo "Installing deprecated OVOS packages for compat..."
uv pip install --no-progress --pre ovos-lingua-franca ovos-backend-client -c $CONSTRAINTS

# Configure user groups for audio management.
echo "Configuring audio..."
add_user_to_group $USER audio
add_user_to_group $USER pipewire
if getent group rtkit > /dev/null 2>&1; then
    add_user_to_group $USER rtkit
fi

# Enable necessary system services.
echo "Enabling system services..."
chmod 644 /etc/systemd/system/kdeconnect.service
chmod 644 /etc/systemd/system/ovos-admin-phal.service
chmod 644 /etc/systemd/system/i2csound.service
chmod 644 /etc/systemd/system/splashscreen.service
ln -s /etc/systemd/system/ovos-admin-phal.service /etc/systemd/system/multi-user.target.wants/ovos-admin-phal.service
ln -s /etc/systemd/system/i2csound.service /etc/systemd/system/multi-user.target.wants/i2csound.service
ln -s /etc/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/
ln -s /etc/systemd/system/splashscreen.service /etc/systemd/system/multi-user.target.wants/splashscreen.service
ln -s /etc/systemd/system/kdeconnect.service /etc/systemd/system/multi-user.target.wants/kdeconnect.service
ln -s /usr/lib/systemd/system/mpd.service /etc/systemd/system/multi-user.target.wants/mpd.service
ln -s /usr/lib/systemd/system/systemd-zram-setup@.service /etc/systemd/system/multi-user.target.wants/systemd-zram-setup@zram0.service

# TODO - investigate better audio setup mechanism
# ln -s /etc/systemd/system/autoconfigure_soundcard.service /etc/systemd/system/multi-user.target.wants/autoconfigure_soundcard.service

# Enable user systemd services.
chmod 644 /home/$USER/.config/systemd/user/*.service
mkdir -p /home/$USER/.config/systemd/user/default.target.wants/
ln -s /home/$USER/.config/systemd/user/ovos.service /home/$USER/.config/systemd/user/default.target.wants/ovos.service
ln -s /home/$USER/.config/systemd/user/ovos-skills.service /home/$USER/.config/systemd/user/default.target.wants/ovos-skills.service
ln -s /home/$USER/.config/systemd/user/ovos-messagebus.service /home/$USER/.config/systemd/user/default.target.wants/ovos-messagebus.service
ln -s /home/$USER/.config/systemd/user/ovos-audio.service /home/$USER/.config/systemd/user/default.target.wants/ovos-audio.service
ln -s /home/$USER/.config/systemd/user/ovos-listener.service /home/$USER/.config/systemd/user/default.target.wants/ovos-listener.service
ln -s /home/$USER/.config/systemd/user/ovos-phal.service /home/$USER/.config/systemd/user/default.target.wants/ovos-phal.service
ln -s /home/$USER/.config/systemd/user/ovos-gui.service /home/$USER/.config/systemd/user/default.target.wants/ovos-gui.service
ln -s /home/$USER/.config/systemd/user/ovos-ggwave.service /home/$USER/.config/systemd/user/default.target.wants/ovos-ggwave.service
ln -s /home/$USER/.config/systemd/user/ovos-spotify.service /home/$USER/.config/systemd/user/default.target.wants/ovos-spotify.service

echo "Enabling messagebus signals..."
ln -s /etc/systemd/system/ovos-reboot-signal.service /etc/systemd/system/multi-user.target.wants/ovos-reboot-signal.service
ln -s /etc/systemd/system/ovos-shutdown-signal.service /etc/systemd/system/multi-user.target.wants/ovos-shutdown-signal.service

echo "Ensuring log file permissions for ovos group..."
mkdir -p /home/$USER/.local/state/mycroft
chown -R $TUID:$TGID /home/$USER/.local/state/mycroft
chmod -R 2775 /home/$USER/.local/state/mycroft

echo "Ensuring permissions for $USER user..."
chown -R $TUID:$TGID /home/$USER
chmod +x /usr/libexec/*
chmod 644 /home/$USER/.asoundrc

# Enable lingering for the user
echo "Enabling lingering for $USER user ..."
mkdir -p /var/lib/systemd/linger
touch /var/lib/systemd/linger/$USER
# Ensure correct permissions
chown root:root /var/lib/systemd/linger/$USER
chmod 644 /var/lib/systemd/linger/$USER

echo "Cleaning up apt packages..."
apt-get --purge autoremove -y && apt-get clean