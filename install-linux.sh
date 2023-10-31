#!/usr/bin/env bash


CYRAL_CONTROL_PLANE_HTTPS_PORT=443
CYRAL_CONTROL_PLANE_GRPC_PORT=443
NL=$'\n'

get_os_type () {
  local detected_os
  detected_os=$(cat /etc/*ease 2>/dev/null|awk '/^ID=/{ print $0}'|awk -F= '{print $2}'| tr -d '"')
  echo "$detected_os"
}

# This is our usage details
print_usage () {
  echo "
******************************************************************************************

NOTE: This script assumes that you have superuser privileges on the target machine.

******************************************************************************************  
Prerequisites:

When you ran the sidecar Generate function in the Cyral control plane UI, it provided a set 
of export commands to set parameters needed by this script. If you have not set these parameters 
in your environment, set them now:

    CYRAL_CONTROL_PLANE: This is the host where your Cyral control plane runs. 
    For example, if your control plane UI runs at https://example.cyral.com/app/home then your hostname is example.cyral.com.

    CYRAL_SIDECAR_ID: Unique identifier for the sidecar. 
    This was generated by Cyral when you created the sidecar in the Cyral control plane UI.

    CYRAL_SIDECAR_CLIENT_ID: Generated by Cyral when you created the sidecar in the Cyral control plane UI.

    CYRAL_SIDECAR_CLIENT_SECRET: Shared secret used to secure control plane-sidecar communication. 
    Generated by Cyral when you created the sidecar in the Cyral control plane UI.

    CYRAL_SIDECAR_VERSION: Sidecar binary version to be deployed, for instance: v2.32.2

    CYRAL_REPOSITORIES_SUPPORTED: a space seperated list of wires you'd like enabled. if not set all wires are enabled.
    For example the value "pg oracle" would only enable the postgres and oracle wires.

IMPORTANT: You must run the export commands as superuser!

On some OS, you may need to install curl (https://curl.se/download.html) and jq (https://stedolan.github.io/jq/download/) too.

------------------------------------------------------------------------------------------  

Usage:

bash install-linux

If you have already downloaded the binaries and do not want to download them again, use the --local_package argument to provide the location of the downloaded binaries, as shown below:

bash install-linux --local_package=<binary_path>

IMPORTANT: You must run the script as superuser!

------------------------------------------------------------------------------------------  

Arguments:

--local_package : specify path to an already-downloaded Cyral sidecar RPM/DEB package, and prevent the script from downloading a new one

------------------------------------------------------------------------------------------  

Example installation on RedHat/CentOS after executing commands:

bash install-linux

Example installation on Debian/Ubuntu using a binary that was already downloaded:

bash install-linux --local_package=/tmp/cyral-sidecar-v2.26.1.deb
"
}

# We'll run this if we fail in the install for some reason
install_error () {
  echo "
#####################################
#   Installation Failure : 
#
#####################################
"
  if [ $# -eq 0 ]
  then
    echo "Unknown Failure"
  else
    echo "$1"
  fi
  echo ""
  exit 2
}

pre_update_tasks () { # double check echos   
  # We need some additional configuration values in the exporter config.yaml
  if ! grep -q sidecar-id /etc/cyral/cyral-sidecar-exporter/config.yaml; then
    echo "sidecar-id:" >> /etc/cyral/cyral-sidecar-exporter/config.yaml
  fi
  
  if ! grep -q controlplane-host /etc/cyral/cyral-sidecar-exporter/config.yaml; then
    echo "controlplane-host: localhost" >> /etc/cyral/cyral-sidecar-exporter/config.yaml
  fi
  
  if ! grep -q controlplane-port /etc/cyral/cyral-sidecar-exporter/config.yaml; then
    echo "controlplane-port: 8068" >> /etc/cyral/cyral-sidecar-exporter/config.yaml
  fi

}

post_update_tasks () { 
  # The port is wrong here so it needs to be corrected
  sed -i "s/8050/8069/" /etc/default/cyral-push-client

  # We need to add a sleep in the push proxy service file so it doesn't come up before the forward proxy connects
  # TODO :: Figure out proper way to do this in the push-client repo
  sed -i "/^ExecStartPre=/c\ExecStartPre=/bin/sh -c \"/bin/touch /var/log/cyral/cyral-push-client.log;/bin/sleep 60\"" /usr/lib/systemd/system/cyral-push-client.service

  # Making sure we add in our file descriptor limits to the wires and dispatcher - ENG-8504
  sed -i '/^\[Service\]/a LimitNOFILE=65535' /usr/lib/systemd/system/cyral-dispatcher.service
  sed -i '/^\[Service\]/a LimitNOFILE=65535' /usr/lib/systemd/system/cyral-*wire.service
}

# This is to check the /etc/ directory for any "release" related files to find the Linux distribution version
get_os_major_version_id () {
  local detected_version_id
  detected_version_id=$(cat /etc/*ease 2>/dev/null|awk '/^VERSION_ID=/{ print $0}'|awk -F= '{print $2}'| tr -d '"'|awk -F\. '{print $1}')
  echo "$detected_version_id"
}

do_rpm_install(){
  get_package "rpm"
  sleep 2
  if rpm -q cyral-sidecar > /dev/null 2>&1; then
    echo "Removing existing installation..."
    rpm -e --erase cyral-sidecar > /dev/null 2>&1
    rm -f "$(grep "discovery-database" /etc/cyral/cyral-service-monitor/config.yaml 2>/dev/null| awk '{print $2}')"
    rm -f /etc/cyral/conf.d/sidecar.db
  fi
  echo "Installing sidecar..."
   rpm -U --force "${INSTALL_PACKAGE}" 2>/dev/null
}

do_dpkg_install(){
  get_package "deb"
  sleep 2
  if dpkg -s cyral-sidecar > /dev/null 2>&1; then
    echo "Removing existing installation..."
    dpkg -r cyral-sidecar > /dev/null 2>&1
    rm -f "$(grep "discovery-database" /etc/cyral/cyral-service-monitor/config.yaml 2>/dev/null| awk '{print $2}')"
    rm -f /etc/cyral/conf.d/sidecar.db
  fi
  echo "Installing sidecar..."
  dpkg -i --force-all "${INSTALL_PACKAGE}" 2>/dev/null
}

# Perform an install of the sidecar package
do_install () {
  if [ "$1" = "rhel" ]; then
    echo "Doing a Red Hat Install"
    do_rpm_install
  elif [ "$1" = "ubuntu" ]; then
    echo "Doing an Ubuntu Install"
    do_dpkg_install
  elif [ "$1" = "centos" ]; then
    echo "Doing a Centos Install"
    do_rpm_install
  elif [ "$1" = "amzn" ]; then
    echo "Doing a Amazon Linux Install"
    do_rpm_install
  elif [ "$1" = "rocky" ]; then # rocky - cent based
    echo "Doing a Rocky Linux Install"
    do_rpm_install
  elif [ "$1" = "ol" ]; then # oracle
    OS_VERSION="$(get_os_major_version_id)"
    if [ "$OS_VERSION" -lt 8 ]; then
	    install_error "Unsupported OracleLinux Version: Detected Version < 8.x"
    fi
    do_rpm_install
  else
    install_error "Unsupported Platform"
  fi
  do_post_install
}

log_detected_advanced_vars () {
    local var_names="$1"
    local var_val
    for var_name in $var_names; do
        var_val="${!var_name}"
        if [ -n "$var_val" ]; then
            echo "Advanced config variable $var_name detected"
        fi
    done
}

set_config_var () {
    local env_varname="$1"
    local config_varname="$2"
    local service_name="$3"
    local env_varval="${!env_varname}"
    local config_fpath="/etc/cyral/cyral-${service_name}/config.yaml"
    # If var is empty don't touch the config
    [ -z "$env_varval" ] && return

    if [ -n "$(cat "$config_fpath" | grep -E "^${config_varname}:")" ]; then
        # Variable already exists in config file, just override
        sed -i "s/^${config_varname}:.*/${config_varname}: ${env_varval}/g" \
            "$config_fpath"
    else
        # Variable does not exist, append it to config file
        printf "${config_varname}: ${env_varval}\n" >> "$config_fpath"
    fi
}

set_advanced_config () {
    local cert_advanced_env_vars=(CYRAL_SIDECAR_TLS_CERT CYRAL_SIDECAR_TLS_PRIVATE_KEY CYRAL_SIDECAR_CA_CERT CYRAL_SIDECAR_CA_PRIVATE_KEY)
    local cert_advanced_config_vars=(tls-cert tls-key ca-cert ca-key)
    local cert_advanced_config_service='certificate-manager'
    local advanced_vars="${cert_advanced_env_vars[*]}"
    log_detected_advanced_vars "${advanced_vars[*]}"

    i=0
    while [ "$i" -lt "${#cert_advanced_env_vars[@]}" ]; do
        set_config_var "${cert_advanced_env_vars[$i]}" \
                       "${cert_advanced_config_vars[$i]}" \
                       "$cert_advanced_config_service"
        i=$(( i + 1 ))
    done
}

# For installs we need to bring in the tar files and add in the sidecar specific details
update_config_files () {
  echo "Updating Configuration Files..."
  local CYRAL_SIDECAR_CLIENT_ID_CLEAN
  local SPECIAL_QUOTE='\\\"'
  CYRAL_SIDECAR_CLIENT_ID_CLEAN=${CYRAL_SIDECAR_CLIENT_ID//\//\\/}

  local META_STRING="\{${SPECIAL_QUOTE}clientId${SPECIAL_QUOTE}:${SPECIAL_QUOTE}${CYRAL_SIDECAR_CLIENT_ID_CLEAN}${SPECIAL_QUOTE},${SPECIAL_QUOTE}clientSecret${SPECIAL_QUOTE}:${SPECIAL_QUOTE}${CYRAL_SIDECAR_CLIENT_SECRET}${SPECIAL_QUOTE}\}"

  pre_update_tasks
  sed -i "/^secret-manager-type:/c\secret-manager-type: \"direct\"" /etc/cyral/cyral-forward-proxy/config.yaml
  sed -i "/^secret-manager-meta:/c\secret-manager-meta: \"${META_STRING}\"" /etc/cyral/cyral-forward-proxy/config.yaml

  sed -i "/^grpc-gateway-address:/c\grpc-gateway-address: \"${CYRAL_CONTROL_PLANE}:$CYRAL_CONTROL_PLANE_GRPC_PORT\"" /etc/cyral/cyral-forward-proxy/config.yaml
  sed -i "/^http-gateway-address:/c\http-gateway-address: \"${CYRAL_CONTROL_PLANE}:$CYRAL_CONTROL_PLANE_HTTPS_PORT\"" /etc/cyral/cyral-forward-proxy/config.yaml
  sed -i "/^token-url:/c\token-url: \"https://${CYRAL_CONTROL_PLANE}:$CYRAL_CONTROL_PLANE_HTTPS_PORT/v1/users/oidc/token\"" /etc/cyral/cyral-forward-proxy/config.yaml


  for config_file in /etc/cyral/*/config.yaml; do
    sed -i "/^sidecar-id:/c\sidecar-id: \"${CYRAL_SIDECAR_ID}\"" "$config_file"
  done

  sed -i "/^SIDECAR_ID=/c\SIDECAR_ID=\"${CYRAL_SIDECAR_ID}\"" /etc/default/cyral-sidecar-exporter
  sed -i "/^CYRAL_PUSH_CLIENT_FQDN=/c\CYRAL_PUSH_CLIENT_FQDN=\"${CYRAL_SIDECAR_ID}\"" /etc/default/cyral-push-client

  
  if [ -f "/etc/cyral/cyral-sidecar-exporter/config.yaml" ]; then
    sed -i "/^sidecar-version:/c\sidecar-version: \"${CYRAL_SIDECAR_VERSION}\"" /etc/cyral/cyral-sidecar-exporter/config.yaml
  fi
  
  # Configure service monitor
  if [ -f "/etc/cyral/cyral-service-monitor/config.yaml" ]; then
   
    if [ -n "$SIDECAR_INSTANCE_ID" ]; then
      primary_ip="$SIDECAR_INSTANCE_ID"
    else
      # Attempt to get the primary IP address using hostname -I
      if ! primary_ip=$(hostname -I | awk '{print $1}'); then
          # If hostname -I fails, try ifconfig
          if ! primary_ip=$(ifconfig | awk '/inet / {print $2; exit}' | cut -d':' -f2); then
              primary_ip="No_IP"
          fi
      fi
    fi

    sed -i "/^instance-id:/c\instance-id: \"${primary_ip}\"" /etc/cyral/cyral-service-monitor/config.yaml
    sed -i "/^deployed-version:/c\deployed-version: \"${CYRAL_SIDECAR_VERSION}\"" /etc/cyral/cyral-service-monitor/config.yaml
  fi

  # Fixes for multiple services using the same repo
  if [ -f "/etc/cyral/cyral-dynamodb-wire/config.yaml" ]; then
    sed -i "/^metrics-port:/c\metrics-port: 9038" /etc/cyral/cyral-dynamodb-wire/config.yaml
  fi
  
  if [ -f "/etc/cyral/cyral-s3-wire/config.yaml" ]; then
    sed -i "/^metrics-port:/c\metrics-port: 9024" /etc/cyral/cyral-s3-wire/config.yaml
  fi

  # Just in case tls is disabled we'll force it enabled
  sed -i "/^tls-type:/c\tls-type: \"tls\"" /etc/cyral/cyral-forward-proxy/config.yaml

  set_advanced_config
  post_update_tasks
}

disable_unsupported_services () {
  echo "Disable unsupported wires"
  readarray -t WIRES < <(find /etc/cyral/ -type d -name "*-wire" -printf "%f\n")
  wires_to_disable=$(for wire in "${WIRES[@]}"; do if [[ ! "$CYRAL_REPOSITORIES_SUPPORTED" =~ $(echo "$wire"|cut -d- -f2) ]]; then echo -n "$wire "; fi; done)

  for wire in "${WIRES[@]}"; do
    if [[ -n "$wires_to_disable" ]] && [[ " ${wires_to_disable} " = *" ${wire} "* ]]; then
      if [[ $(systemctl is-enabled "${wire}") == "enabled" ]]; then
        echo "Disabling ${wire}..."
        systemctl disable "${wire}"
      else
        echo "already disabled $wire"
      fi
    else
      if [[ $(systemctl is-enabled "${wire}") == "disabled" ]]; then
        echo "Enabling ${wire}..."
        systemctl enable "${wire}"
      else
        echo "already enabled $wire"
      fi
    fi
  done
}

# After performing everything we need to restart the cyral services
restart_services () {
  # We need to reload any of our changes to the systemd files before restarting
  systemctl daemon-reload
  (cd /;systemctl restart cyral-*) # without this it will use the filenames local to it
}

# TODO :: Remove this once Epic complete
pre_epic_tasks () {
  # We need to remove the CYRAL_SIDECAR_EXPORTER_ from the beginning of the env vars in cyral-sidecar-exporter
  sed -i "s/^CYRAL_SIDECAR_EXPORTER_//" /etc/default/cyral-sidecar-exporter

  # We need to add a sleep in the push proxy service file so it doesn't come up before the forward proxy connects
  # TODO :: Figure out proper way to do this in the push-client repo
  sed -i "/^ExecStartPre=/c\ExecStartPre=/bin/sh -c \"/bin/touch /var/log/cyral/cyral-push-client.log;/bin/sleep 30\"" /usr/lib/systemd/system/cyral-push-client.service

  # Need to fix the variable for control plane host and port Ref, ENG-7352
  sed -i "s/^controlplane_host:/controlplane-host:/" /etc/cyral/cyral-sidecar-exporter/config.yaml
  sed -i "s/^controlplane_port:/controlplane-port:/" /etc/cyral/cyral-sidecar-exporter/config.yaml

  # We need to get rid of the CYRAL_PUSH_CLIENT_STORAGE_ from push-client
  sed -i "s/^CYRAL_PUSH_CLIENT_STORAGE_//" /etc/default/cyral-push-client
}

# Perform all Post Installation Tasks
do_post_install () {
  echo "Running Post Install Tasks..."
  pre_epic_tasks
  if [ -n "$CYRAL_REPOSITORIES_SUPPORTED" ]; then
    disable_unsupported_services
  fi
  update_config_files
  restart_services
}

get_argument_value () {
  local argument_value
  argument_value=$(echo "$1"|awk -F= '{print $2}'| tr -d '"')
  echo "$argument_value"
}

generate_post_data () {
  cat <<EOF
{
  "TemplateReference":"$CYRAL_SIDECAR_VERSION", 
  "TemplateVars":{"sidecarId":"$CYRAL_SIDECAR_ID", 
  "clientId":"$CYRAL_SIDECAR_CLIENT_ID",
  "clientSecret":"$CYRAL_SIDECAR_CLIENT_SECRET",
  "controlPlaneHost":"$CYRAL_CONTROL_PLANE"}
}
EOF
}

get_package () {
  if [ -z "$INSTALL_PACKAGE" ] ; then
  ROUTE=$1
  BINARIES_NAME=cyral-sidecar.$ROUTE
  download_package
  else
    echo "Using provided package $INSTALL_PACKAGE"
  fi
}

download_package () {
  echo "Getting access to the Control Plane"
  
  if ! TOKEN=$(curl --fail --silent --request POST "https://$CYRAL_CONTROL_PLANE:$CYRAL_CONTROL_PLANE_HTTPS_PORT/v1/users/oidc/token" -d grant_type=client_credentials -d client_id="$CYRAL_SIDECAR_CLIENT_ID" -d client_secret="$CYRAL_SIDECAR_CLIENT_SECRET" 2>&1) ; then
    #attempt with previous ports
    CYRAL_CONTROL_PLANE_HTTPS_PORT=8000
    CYRAL_CONTROL_PLANE_GRPC_PORT=9080
    if ! TOKEN=$(curl --fail --silent --request POST "https://$CYRAL_CONTROL_PLANE:$CYRAL_CONTROL_PLANE_HTTPS_PORT/v1/users/oidc/token" -d grant_type=client_credentials -d client_id="$CYRAL_SIDECAR_CLIENT_ID" -d client_secret="$CYRAL_SIDECAR_CLIENT_SECRET" 2>&1) ; then
      echo "Failed to retrieve control plane token."
      echo "$TOKEN"
      exit 1
    fi
  fi

  ACCESS_TOKEN=$(echo "$TOKEN" | jq -r .access_token)
  if [[ -z "$ACCESS_TOKEN" ]] ; then
    echo "Error: Could not connect to the Control Plane. Check CYRAL_SIDECAR_CLIENT_ID and CYRAL_SIDECAR_CLIENT_SECRET and try again"
    exit 1
  fi

  echo "Downloading the binaries"
  DOWNLOAD_STATUS=$(curl --write-out "%{http_code}" "https://$CYRAL_CONTROL_PLANE:$CYRAL_CONTROL_PLANE_HTTPS_PORT/v1/templates/download/$ROUTE/$CYRAL_SIDECAR_VERSION" -H "authorization: Bearer $ACCESS_TOKEN" --output $BINARIES_NAME)
  
  if [[ "$DOWNLOAD_STATUS" -ne 200 ]] ; then
    echo "Error: Status code $DOWNLOAD_STATUS when downloading binaries"
    exit 1
  else
    echo "Binaries were successfully downloaded."
  fi
  INSTALL_PACKAGE=$BINARIES_NAME
}

get_config () {
  # Check to make sure required env variables are set
  local sidecarId jsonsecret clientId clientSecret controlPlane unsetVar
  configFile='/etc/cyral/cyral-forward-proxy/config.yaml'
  if [[ -r "$configFile" ]]; then
    sidecarId=$(awk -F '^sidecar-id: "|"' '/sidecar-id:/{print $2}' "$configFile")
    jsonsecret=$(sed -n '/^secret-manager-meta:/ s/.*: "\(.*\)"/\1/p' "$configFile" | sed 's/\\"/"/g')
    clientId=$(echo "$jsonsecret" | jq -r '.clientId')
    clientSecret=$(echo "$jsonsecret" | jq -r '.clientSecret')
    controlPlane=$(awk -F':' '/^grpc-gateway-address/ {print $2}' "$configFile" | awk '{gsub(/"/, "", $1); print $1}')
  fi
  #sidecar version
  if [[ -z "$CYRAL_SIDECAR_VERSION" ]]; then
    unsetVar="CYRAL_SIDECAR_VERSION"
  fi
  # control plane
  if [[ -z "$CYRAL_CONTROL_PLANE" ]]; then
    if [[ -z "$controlPlane" ]]; then
      unsetVar+="${NL}CYRAL_CONTROL_PLANE"
    else
      CYRAL_CONTROL_PLANE="$controlPlane"
    fi
  fi
  #sidecar id
  if [[ -z "$CYRAL_SIDECAR_ID" ]]; then
    if [[ -z "$sidecarId" ]]; then
      unsetVar+="${NL}CYRAL_SIDECAR_ID"
    else
      CYRAL_SIDECAR_ID="$sidecarId"
    fi
  fi
  #client id
  if [[ -z "$CYRAL_SIDECAR_CLIENT_ID"  ]]; then
    if [[ -z "$clientId" ]]; then
      unsetVar+="${NL}CYRAL_SIDECAR_CLIENT_ID"
    else
      CYRAL_SIDECAR_CLIENT_ID="$clientId"
    fi
  fi
  #client secret
  if [[ -z "$CYRAL_SIDECAR_CLIENT_SECRET"  ]]; then
    if [[ -z "$clientSecret" ]]; then
      unsetVar+="${NL}CYRAL_SIDECAR_CLIENT_SECRET"
    else
      CYRAL_SIDECAR_CLIENT_SECRET="$clientSecret"
    fi
  fi
  
  if [[ -n "$unsetVar" ]]; then
    print_usage
    echo "-----------"
    echo "ERROR - Unable to obtain values for the following variables:"
    echo "$unsetVar"
    exit 1
  fi
}

##main

if [ "$EUID" -ne 0 ] && [ "$(id -un)" != "root" ]; then
  echo "This script requires elevated permissions. Please execute with sudo."
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "Please install jq first"
  exit 1
fi

OS_TYPE="$(get_os_type)"


# Handle the arguments that were provided
while test $# -gt 0; do
  case "$1" in
      --local_package=*) INSTALL_PACKAGE=$(get_argument_value "$1")
          ;;
      *) print_usage
        exit
          ;;
  esac
  shift
done

get_config



do_install "$OS_TYPE"
