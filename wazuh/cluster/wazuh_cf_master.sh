#!/bin/bash
# Install Wazuh master instance using Cloudformation template
# Support for Amazon Linux
touch /tmp/deploy.log
echo "Starting process." > /tmp/deploy.log

load_env_vars(){
	wazuh_version=$(cat /tmp/wazuh_cf_settings | grep '^Elastic_Wazuh:' | cut -d' ' -f2 | cut -d'_' -f2)
	wazuh_server_port=$(cat /tmp/wazuh_cf_settings | grep '^WazuhServerPort:' | cut -d' ' -f2)
	wazuh_registration_port=$(cat /tmp/wazuh_cf_settings | grep '^WazuhRegistrationPort:' | cut -d' ' -f2)
	wazuh_registration_password=$(cat /tmp/wazuh_cf_settings | grep '^WazuhRegistrationPassword:' | cut -d' ' -f2)
	wazuh_api_user=$(cat /tmp/wazuh_cf_settings | grep '^WazuhApiAdminUsername:' | cut -d' ' -f2)
	wazuh_api_password=$(cat /tmp/wazuh_cf_settings | grep '^WazuhApiAdminPassword:' | cut -d' ' -f2)
	wazuh_api_port=$(cat /tmp/wazuh_cf_settings | grep '^WazuhApiPort:' | cut -d' ' -f2)
	wazuh_cluster_key=$(cat /tmp/wazuh_cf_settings | grep '^WazuhClusterKey:' | cut -d' ' -f2)
	eth0_ip=$(/sbin/ifconfig eth0 | grep 'inet' | head -1 | sed -e 's/^[[:space:]]*//' | cut -d' ' -f2)
	EnvironmentType=$(cat /tmp/wazuh_cf_settings | grep '^EnvironmentType:' | cut -d' ' -f2)
	TAG="v$wazuh_version"
	echo "Added env vars." >> /tmp/deploy.log
}

get_repo(){

if [[ ${EnvironmentType} == 'staging' ]]
then
	# Adding Wazuh pre_release repository
	echo -e '[wazuh_pre_release]\ngpgcheck=1\ngpgkey=https://s3-us-west-1.amazonaws.com/packages-dev.wazuh.com/key/GPG-KEY-WAZUH\nenabled=1\nname=EL-$releasever - Wazuh\nbaseurl=https://s3-us-west-1.amazonaws.com/packages-dev.wazuh.com/pre-release/yum/\nprotect=1' | tee /etc/yum.repos.d/wazuh_pre.repo
elif [[ ${EnvironmentType} == 'production' ]]
then
cat > /etc/yum.repos.d/wazuh.repo <<\EOF
[wazuh_repo]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=Wazuh repository
baseurl=https://packages.wazuh.com/3.x/yum/
protect=1
EOF
elif [[ ${EnvironmentType} == 'devel' ]]
then
	echo -e '[wazuh_staging]\ngpgcheck=1\ngpgkey=https://s3-us-west-1.amazonaws.com/packages-dev.wazuh.com/key/GPG-KEY-WAZUH\nenabled=1\nname=EL-$releasever - Wazuh\nbaseurl=https://s3-us-west-1.amazonaws.com/packages-dev.wazuh.com/staging/yum/\nprotect=1' | tee /etc/yum.repos.d/wazuh_staging.repo
else
	echo 'no repo' >> /tmp/stage
fi
}


install_manager(){
	# Installing wazuh-manager
	yum -y install wazuh-manager
	chkconfig --add wazuh-manager
	manager_config="/var/ossec/etc/ossec.conf"
	local_rules="/var/ossec/etc/rules/local_rules.xml"
	# Enable registration service (only for master node)

	echo "Installed wazuh manager package" >> /tmp/deploy.log
}

config_manager(){
	# Change manager protocol to tcp, to be used by Amazon ELB
	sed -i "s/<protocol>udp<\/protocol>/<protocol>tcp<\/protocol>/" ${manager_config}

	# Set manager port for agent communications
	sed -i "s/<port>1514<\/port>/<port>${wazuh_server_port}<\/port>/" ${manager_config}

	# Configuring registration service 
	sed -i '/<auth>/,/<\/auth>/d' ${manager_config}

cat >> ${manager_config} << EOF
<ossec_config>
  <auth>
    <disabled>no</disabled>
    <port>${wazuh_registration_port}</port>
    <use_source_ip>no</use_source_ip>
    <force_insert>yes</force_insert>
    <force_time>0</force_time>
    <purge>yes</purge>
    <use_password>yes</use_password>
    <limit_maxagents>yes</limit_maxagents>
    <ciphers>HIGH:!ADH:!EXP:!MD5:!RC4:!3DES:!CAMELLIA:@STRENGTH</ciphers>
    <!-- <ssl_agent_ca></ssl_agent_ca> -->
    <ssl_verify_host>no</ssl_verify_host>
    <ssl_manager_cert>/var/ossec/etc/sslmanager.cert</ssl_manager_cert>
    <ssl_manager_key>/var/ossec/etc/sslmanager.key</ssl_manager_key>
    <ssl_auto_negotiate>no</ssl_auto_negotiate>
  </auth>
</ossec_config>
EOF

	# Setting password for agents registration
	echo "${wazuh_registration_password}" > /var/ossec/etc/authd.pass
	echo "Set registration password." > /tmp/deploy.log

}


config_cluster(){
	# Installing Python Cryptography module for the cluster
	pip install cryptography

	# Configuring cluster section
	sed -i '/<cluster>/,/<\/cluster>/d' ${manager_config}

cat >> ${manager_config} << EOF
<ossec_config>
  <cluster>
    <name>wazuh</name>
    <node_name>wazuh-master</node_name>
    <node_type>master</node_type>
    <key>${wazuh_cluster_key}</key>
    <port>1516</port>
    <bind_addr>0.0.0.0</bind_addr>
    <nodes>
        <node>${eth0_ip}</node>
    </nodes>
    <hidden>no</hidden>
    <disabled>no</disabled>
  </cluster>
</ossec_config>
EOF

	# Restart wazuh-manager
	systemctl restart wazuh-manager
	echo "Restarted Wazuh manager." >> /tmp/deploy.log
}

install_api(){

	# Installing NodeJS
	curl --silent --location https://rpm.nodesource.com/setup_8.x | bash -
	yum -y install nodejs
	echo "Installed NodeJS." >> /tmp/deploy.log

	# Installing wazuh-api
	yum -y install wazuh-api
	chkconfig --add wazuh-api
	echo "Installed Wazuh API." >> /tmp/deploy.log

	# Configuring Wazuh API user and password
	cd /var/ossec/api/configuration/auth
	node htpasswd -b -c user ${wazuh_api_user} ${wazuh_api_password}

	# Enable Wazuh API SSL and configure listening port
	api_ssl_dir="/var/ossec/api/configuration/ssl"
	openssl req -x509 -batch -nodes -days 3650 -newkey rsa:2048 -keyout ${api_ssl_dir}/server.key -out ${api_ssl_dir}/server.crt
	sed -i "s/config.https = \"no\";/config.https = \"yes\";/" /var/ossec/api/configuration/config.js
	sed -i "s/config.port = \"55000\";/config.port = \"${wazuh_api_port}\";/" /var/ossec/api/configuration/config.js
	echo "Setting port and SSL to Wazuh API." >> /tmp/deploy.log

	# Restart wazuh-api
	systemctl restart wazuh-api 
	echo "Restarted Wazuh API." >> /tmp/deploy.log
}


install_filebeat(){
	# Install Filebeat module
	curl -s "https://packages.wazuh.com/3.x/filebeat/wazuh-filebeat-0.1.tar.gz" | tar -xvz -C /usr/share/filebeat/module

	# Get Filebeat configuration file
	curl -so /etc/filebeat/filebeat.yml https://raw.githubusercontent.com/wazuh/wazuh/${TAG}/extensions/filebeat/7.x/filebeat.yml

	# Elasticsearch template
	curl -so /etc/filebeat/wazuh-template.json https://raw.githubusercontent.com/wazuh/wazuh/${TAG}/extensions/elasticsearch/7.x/wazuh-template.json

	# File permissions
	chmod go-w /etc/filebeat/filebeat.yml
	chmod go-w /etc/filebeat/wazuh-template.json

	# Point to Elasticsearch cluster
	sed -i "s|'http://YOUR_ELASTIC_SERVER_IP:9200'|'$elastic_ip'|" /etc/filebeat/filebeat.yml

	systemctl restart filebeat

}


main(){
	
# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi
	# Check if running as root
	if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root"
	exit 1
	fi
	load_env_vars
	get_repo
	install_manager
	config_manager
	config_cluster
	install_api
	install_filebeat
}

main