#!/bin/bash
# Install Wazuh agent using Cloudformation template
# Support for Amazon Linux
agent_name=$(cat /tmp/wazuh_cf_settings | grep '^agent_name:' | cut -d' ' -f2)
ssh_username=$(cat /tmp/wazuh_cf_settings | grep '^SshUsername:' | cut -d' ' -f2)
master_ip=$(cat /tmp/wazuh_cf_settings | grep '^WazuhMasterIP:' | cut -d' ' -f2)
elb_wazuh_dns=$(cat /tmp/wazuh_cf_settings | grep '^ElbWazuhDNS:' | cut -d' ' -f2)
ssh_password=$(cat /tmp/wazuh_cf_settings | grep '^SshPassword:' | cut -d' ' -f2)
wazuh_server_port=$(cat /tmp/wazuh_cf_settings | grep '^WazuhServerPort:' | cut -d' ' -f2)
wazuh_registration_password=$(cat /tmp/wazuh_cf_settings | grep '^WazuhRegistrationPassword:' | cut -d' ' -f2)
wazuh_version=$(cat /tmp/wazuh_cf_settings | grep '^Elastic_Wazuh:' | cut -d' ' -f2 | cut -d'_' -f2)
manager_config='/var/ossec/etc/ossec.conf'
# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Adding Wazuh repository
wazuh_major_version=$(echo ${wazuh_version} | cut -d'.' -f1)

curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | apt-key add -
echo "deb https://packages.wazuh.com/${wazuh_major_version}.x/apt/ stable main" | tee /etc/apt/sources.list.d/wazuh.list

# Install Wazuh agent
apt-get update
apt-get install curl apt-transport-https lsb-release -y


# Install Wazuh agent
apt-get update
apt-get install wazuh-agent-${wazuh_version} -y

# Register agent using authd
/var/ossec/bin/agent-auth -m ${master_ip} -A ubuntu-ag
sed -i 's:MANAGER_IP:'${elb_wazuh_dns}
# Enable and restart the Wazuh agent
systemctl daemon-reload
systemctl enable wazuh-agent
systemctl restart wazuh-agent