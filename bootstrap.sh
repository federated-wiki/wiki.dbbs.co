#!/bin/bash -eu
set -o pipefail
IFS=$'\t\n\r'

readonly COMPOSE_DIR=$( cd $(dirname $0); pwd )

main() {
    create-droplet
    create-droplet-floating-ip
    create-fqdn
    create-wildcard-cname
}

create-environment() {
    source $COMPOSE_DIR/.env
    [ -n "${DROPLET:-}" ]    || { echo ".env missing DROPLET" ; FATAL=1; }
    [ -n "${TOKEN_FILE:-}" ] || { echo ".env missing TOKEN_FILE" ; FATAL=1; }
    [ -n "${REGION:-}" ]     || { echo ".env missing REGION" ; FATAL=1; }

    [ -z "${FATAL:-}" ] || exit 1
}

create-droplet() {
    droplet-exists || {
        docker-machine \
            create --driver digitalocean\
            --digitalocean-access-token=$(token) \
            --digitalocean-region=$REGION \
            $DROPLET
    }
}

create-droplet-floating-ip() {
    local IP=$(droplet-floating-ip)
    [ -n "$IP" ] || {
        local ID=$(droplet-list | awk "/$DROPLET\$/ {print \$1}")
        do-api -sS -X POST \
               -d "{\"droplet_id\":$ID}" \
               "https://api.digitalocean.com/v2/floating_ips"
    }
}

create-fqdn() {
    fqdn-exists || {
        do-api -X POST \
               -d "{\"name\":\"${DROPLET}\",\"ip_address\":$(droplet-floating-ip)}" \
               "https://api.digitalocean.com/v2/domains"
    }
}

create-wildcard-cname() {
    wildcard-cname-exists || {
        do-api -X POST \
               -d "{\"type\":\"CNAME\",\"name\":\"*\",\"data\":\"@\",\"priority\":null,\"port\":null,\"weight\":null}" \
               "https://api.digitalocean.com/v2/domains/${DROPLET}/records"
    }
}

droplet-list-json() {
    do-api -sS -X GET "https://api.digitalocean.com/v2/droplets?page=1&per_page=10"
}

droplet-list() {
    # memoize to self-regulate DO rate-limits
    if [ -z "${DROPLET_LIST:-}" ]; then
        local JSON="$(droplet-list-json)"
        echo $JSON
        <<<"$JSON" jq -r '.droplets[]'
        readonly DROPLET_LIST="$(<<<"$JSON" jq -r '.droplets[] | .id, .name' \
            | paste - -)"
    fi
    echo -e $DROPLET_LIST
}

droplet-exists() {
    droplet-list | grep -q "$DROPLET\$"
}

droplet-floating-ip() {
    do-api -sS -X GET "https://api.digitalocean.com/v2/floating_ips?page=1&per_page=20" \
        | jq ".floating_ips[] | select(.droplet.name == \"$DROPLET\") | .ip"
}

fqdn-exists() {
    # not_found is in the error payload if the domain doesn't exist
    # so this code is a double-negative: true if we don't find "not_found"
    do-api -sS -X GET "https://api.digitalocean.com/v2/domains/${DROPLET}" \
        | grep -qv not_found
}

wildcard-cname-exists() {
    list-cnames \
        | grep -q '^*'
}

list-cnames() {
    do-api -sS -X GET \
           "https://api.digitalocean.com/v2/domains/${DROPLET}/records" \
        | jq -r '.domain_records[] | select(.type == "CNAME") | .name, .data' \
        | paste - -
}

create-cname() {
    local SUBDOMAIN="${1:-*}"
    cname-exists $SUBDOMAIN || {
        local URL="https://api.digitalocean.com/v2/domains/${DROPLET}/records"
        do-api -X POST -d@- $URL <<EOF
{
  "type" : "CNAME",
  "name" : "$SUBDOMAIN",
  "data" : "@",
  "priority" : null,
  "port" : null,
  "weight" : null
}
EOF
    }
}

cname-exists() {
    local SUBDOMAIN="${1:-UNSPECIFIED}"
    list-cnames | grep -q "^$SUBDOMAIN"
}

do-api() {
    curl \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $(token)" \
        $@
}

token() {
    cat $TOKEN_FILE
}

case ${1:-} in
    list-cnames \
    | create-cname \
    | create-droplet \
    | create-droplet-floating-ip \
    | create-fqdn \
    | create-wildcard-cname \
    | wildcard-cname-exists \
    )
        readonly CMD=${1}
        shift
    ;;
    *)
        readonly CMD=main
    ;;
esac

create-environment
$CMD $@
