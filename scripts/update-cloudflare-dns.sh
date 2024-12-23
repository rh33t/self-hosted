# Set zoneid, cloudflare_zone_api_token, discord_webhook_url variables
#!/usr/bin/env bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Function for colored logging
log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

##### Configuration Settings
## Specify which IP address to use for DNS record:
## - "external": Uses the public IP address obtained from external service
## - "internal": Uses the primary network interface's local IP address
what_ip="external"

## DNS A record(s) to be updated
## Multiple records can be specified, separated by comma
## Example: "example.com,www.example.com,subdomain.example.com"
dns_record="triplea.top"

## Cloudflare Configuration
## Zone ID: Can be found on the overview page of your domain in Cloudflare
zoneid=""
## Cloudflare Zone API Token: Required for making DNS updates
cloudflare_zone_api_token=""

## DNS Record Configuration
## Whether to use Cloudflare's proxy service for the DNS record
## - "true": Enables Cloudflare's proxy (CDN, security features)
## - "false": Direct DNS resolution without Cloudflare proxy
proxied="false"

## TTL (Time To Live) for DNS record
## - 120-7200 seconds
## - 1 for automatic TTL
ttl=120

## Discord Webhook Notifications
## Send notification when DNS is updated
## - "yes": Send notification
## - "no": Disable notifications
notify_me_discord="yes"
## Full Discord webhook URL
discord_webhook_url=""

### Validate TTL parameter
if [ "${ttl}" -lt 120 ] || [ "${ttl}" -gt 7200 ] && [ "${ttl}" -ne 1 ]; then
  log_error "TTL out of range (120-7200) or not set to 1"
  exit 1
fi

### Validate proxied parameter
if [ "${proxied}" != "false" ] && [ "${proxied}" != "true" ]; then
  log_error 'Incorrect "proxied" parameter, choose "true" or "false"'
  exit 1
fi

### Validate what_ip parameter
if [ "${what_ip}" != "external" ] && [ "${what_ip}" != "internal" ]; then
  log_error 'Incorrect "what_ip" parameter, choose "external" or "internal"'
  exit 1
fi

### Check incompatible IP and proxy settings
if [ "${what_ip}" == "internal" ] && [ "${proxied}" == "true" ]; then
  log_error 'Internal IP cannot be proxied'
  exit 1
fi

### Valid IPv4 Regex for validation
REIP='^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])$'

### Get external IP from https://checkip.amazonaws.com
if [ "${what_ip}" == "external" ]; then
  ip=$(curl -4 -s -X GET https://checkip.amazonaws.com --max-time 10)
  if [ -z "$ip" ]; then
    log_error "Can't retrieve external IP from https://checkip.amazonaws.com"
    exit 1
  fi
  if ! [[ "$ip" =~ $REIP ]]; then
    log_error "Retrieved IP address is invalid!"
    exit 1
  fi
  log_info "External IP detected: ${CYAN}$ip${NC}"
fi

### Get Internal IP from primary network interface
if [ "${what_ip}" == "internal" ]; then
  ### Detect IP using 'ip' command (Linux)
  if which ip >/dev/null; then
    interface=$(ip route get 1.1.1.1 | awk '/dev/ { print $5 }')
    ip=$(ip -o -4 addr show ${interface} scope global | awk '{print $4;}' | cut -d/ -f 1)
    ### Fallback to 'ifconfig' (macOS, BSD)
  else
    interface=$(route get 1.1.1.1 | awk '/interface:/ { print $2 }')
    ip=$(ifconfig ${interface} | grep 'inet ' | awk '{print $2}')
  fi
  if [ -z "$ip" ]; then
    log_error "Unable to retrieve IP from ${interface}"
    exit 1
  fi
  log_info "Internal ${MAGENTA}${interface}${NC} IP detected: ${CYAN}$ip${NC}"
fi

### Process multiple DNS records
IFS=',' read -d '' -ra dns_records <<<"$dns_record,"
unset 'dns_records[${#dns_records[@]}-1]'
declare dns_records

for record in "${dns_records[@]}"; do
  log_info "Processing DNS record: ${MAGENTA}${record}${NC}"

  ### Resolve current DNS record IP when not using Cloudflare proxy
  if [ "${proxied}" == "false" ]; then
    ### Attempt DNS resolution using 'nslookup'
    if which nslookup >/dev/null; then
      dns_record_ip=$(nslookup ${record} 1.1.1.1 | awk '/Address/ { print $2 }' | sed -n '2p')
      ### Fallback to 'host' command
    else
      dns_record_ip=$(host -t A ${record} 1.1.1.1 | awk '/has address/ { print $4 }' | sed -n '1p')
    fi

    if [ -z "$dns_record_ip" ]; then
      log_error "Unable to resolve ${record} via 1.1.1.1 DNS server"
      exit 1
    fi
    is_proxed="${proxied}"
  fi

  ### Retrieve DNS record info from Cloudflare when using proxy
  if [ "${proxied}" == "true" ]; then
    dns_record_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records?type=A&name=$record" \
      -H "Authorization: Bearer $cloudflare_zone_api_token" \
      -H "Content-Type: application/json")
    if [[ ${dns_record_info} == *"\"success\":false"* ]]; then
      log_error "Unable to retrieve DNS record info from Cloudflare API"
      exit 1
    fi
    is_proxed=$(echo ${dns_record_info} | grep -o '"proxied":[^,]*' | grep -o '[^:]*$')
    dns_record_ip=$(echo ${dns_record_info} | grep -o '"content":"[^"]*' | cut -d'"' -f 4)
  fi

  ### Skip update if IP and proxy settings are unchanged
  if [ ${dns_record_ip} == ${ip} ] && [ ${is_proxed} == ${proxied} ]; then
    log_warning "No changes needed for DNS record ${MAGENTA}${record}${NC}. Current IP is ${CYAN}${dns_record_ip}${NC}."
    continue
  fi

  log_info "Updating DNS record for ${MAGENTA}${record}${NC}. Current IP: ${YELLOW}${dns_record_ip}${NC}"

  ### Retrieve DNS record details from Cloudflare
  cloudflare_record_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records?type=A&name=$record" \
    -H "Authorization: Bearer $cloudflare_zone_api_token" \
    -H "Content-Type: application/json")
  if [[ ${cloudflare_record_info} == *"\"success\":false"* ]]; then
    log_error "Unable to retrieve record information from Cloudflare API"
    exit 1
  fi

  ### Extract DNS record ID
  cloudflare_dns_record_id=$(echo ${cloudflare_record_info} | grep -o '"id":"[^"]*' | cut -d'"' -f4)

  ### Update DNS record via Cloudflare API
  update_dns_record=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records/$cloudflare_dns_record_id" \
    -H "Authorization: Bearer $cloudflare_zone_api_token" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$record\",\"content\":\"$ip\",\"ttl\":$ttl,\"proxied\":$proxied}")
  if [[ ${update_dns_record} == *"\"success\":false"* ]]; then
    log_error "DNS record update failed"
    exit 1
  fi

  log_success "$record DNS Record updated to: ${CYAN}$ip${NC}, TTL: ${GREEN}$ttl${NC}, Proxied: ${YELLOW}$proxied${NC}"

  ### Discord notification
  if [ ${notify_me_discord} == "no" ]; then
    continue
  fi

  if [ ${notify_me_discord} == "yes" ]; then
    discord_response=$(curl -s -X POST "${discord_webhook_url}" \
      -H "Content-Type: application/json" \
      -d "{\"content\":\"DNS Record for ${record} updated to: ${ip}, TTL: ${ttl}, Proxied: ${proxied}\"}")

    # Check Discord API response
    if [[ -z "${discord_response}" ]]; then
      log_success "Discord notification sent successfully"
    else
      log_error "Discord notification failed - API response: ${discord_response}"
    fi
  fi

done

log_success "DNS update process completed successfully!"
