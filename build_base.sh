#!/bin/bash
# Exit on error
# If something goes wrong just stop.
# it allows the user to see issues at once rather than having
# scroll back and figure out what went wrong.
set -e

# if $USER is different from "pi"  (the default) rename "pi" to "$USER"
if [ "$USER" != "pi" ]; then
  # 1. Change the username in /etc/passwd
  echo "Renaming user in /etc/passwd..."
  sed -i "s/^pi:/^$USER:/g" "/etc/passwd"

  # 2. Change the group name in /etc/group
  echo "Renaming user in /etc/group..."
  sed -i "s/^pi:/^$USER:/g" "/etc/group"

  # 3. Rename the home directory from /home/pi to /home/newuser
  echo "Renaming home directory..."
  mv "/home/pi" "/home/$USER"

  # 4. Change ownership of the new home directory
  echo "Updating file ownership..."
  chown -R 1000:1000 "/home/$USER"    # Replace 1000:1000 with the correct UID:GID if needed

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
  
  # 8. Allow autologin of user
  echo "Creating autologin for $USER"
  # NOTE: Not sure that the link is needed
  ln -fs /lib/systemd/system/getty@.service /etc/systemd/system/getty.target.wants/getty@tty1.service
  cp -v /mounted-github-repo/autologin.conf /etc/systemd/system/getty@tty1.service.d/autologin.conf
  sed -i "s/\bovos\b/${USER}/g" /etc/systemd/system/getty@tty1.service.d/autologin.conf
  

  echo "User has been renamed, added to sudo group, and password updated."
fi

echo "Changing system hostname to $HOSTNAME..."
# Update /etc/hostname
echo "$HOSTNAME" > /etc/hostname
# Update /etc/hosts to reflect the new hostname
sed -i "s/127.0.1.1.*$/127.0.1.1\t$HOSTNAME/" /etc/hosts

echo "Enabling ssh..."
touch /boot/firmware/ssh

# Update package list and install necessary tools
echo "Updating base system..."
apt-get update
apt-get install -y --no-install-recommends git unzip curl build-essential

echo "Installing Pipewire..."
bash /mounted-github-repo/setup_pipewire.sh

echo "Tuning base system..."
cp -v /mounted-github-repo/boot_config.txt /boot/firmware/config.txt
bash /mounted-github-repo/setup_ramdisk.sh
bash /mounted-github-repo/setup_zram.sh
bash /mounted-github-repo/setup_cpugovernor.sh
bash /mounted-github-repo/setup_wlan0power.sh
bash /mounted-github-repo/setup_fstab.sh
bash /mounted-github-repo/setup_sysctl.sh
bash /mounted-github-repo/setup_udev.sh
bash /mounted-github-repo/setup_kernel_modules.sh
bash /mounted-github-repo/setup_nmanager.sh
# make boot faster by printing less stuff and skipping file system checks
grep -q "quiet fastboot" /boot/cmdline.txt || sed -i 's/$/ quiet fastboot/' /boot/cmdline.txt

echo "Ensuring permissions for $USER user..."
# Replace 1000:1000 with the correct UID:GID if needed
chown -R 1000:1000 /home/$USER

# Enable lingering for the user
echo "Enabling lingering for $USER user ..."
# Enable lingering by creating the directory
mkdir -p /var/lib/systemd/linger

# Create an empty file with the user's name
touch /var/lib/systemd/linger/$USER

# Ensure correct permissions
chown root:root /var/lib/systemd/linger/$USER
chmod 644 /var/lib/systemd/linger/$USER

echo "Cleaning up apt packages..."
apt-get --purge autoremove -y && apt-get clean