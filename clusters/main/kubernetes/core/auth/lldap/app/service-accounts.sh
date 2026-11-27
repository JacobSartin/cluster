#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
shopt -s inherit_errexit

sa=/var/run/secrets/kubernetes.io/serviceaccount

api() {
  curl -sSf --cacert "$sa/ca.crt" -H "Authorization: Bearer $(cat "$sa/token")" "https://kubernetes.default.svc$1"
}

graphql() {
  jq -cn --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}' |
    curl -sSf "$LLDAP_URL/api/graphql" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data @- |
    jq -ce 'if .errors then error(.errors | map(.message) | join("; ")) else .data end'
}

desired_accounts() {
  local clients managers
  # Only namespaces with the guarded LLDAP client label get an account.
  clients=$(api "/api/v1/namespaces?labelSelector=network.jacobsartin.com%2Flldap%3Dclient" |
    jq -c '[.items[].metadata.name]')
  managers=$(api "/api/v1/namespaces?labelSelector=auth.jacobsartin.com%2Flldap-password-manager%3Dtrue" |
    jq -c '[.items[].metadata.name]')
  api "/api/v1/secrets?fieldSelector=metadata.name%3Dlldap-service-account" |
    jq -c --argjson clients "$clients" --argjson managers "$managers" '[.items[] |
      select(.metadata.namespace | IN($clients[])) | {
      id: ("svc-" + .metadata.namespace),
      password: ((.data.password // "") | @base64d),
      group: (
        if .metadata.namespace | IN($managers[]) then "lldap_password_manager"
        elif ((.data.readonly // "") | @base64d) == "true" then "lldap_strict_readonly"
        else null end)
    }] | sort_by(.id)'
}

apply() {
  local desired="$1" account id password groups users want have group
  token=$(jq -cn --arg u "$LLDAP_ADMIN_USERNAME" --arg p "$LLDAP_ADMIN_PASSWORD" '{username: $u, password: $p}' |
    curl -sSf "$LLDAP_URL/auth/simple/login" -H 'Content-Type: application/json' --data @- | jq -er .token)
  groups=$(graphql 'query { groups { id displayName } }' '{}')
  users=$(graphql 'query { users { id groups { id } } }' '{}')

  while read -r account; do
    id=$(jq -r .id <<<"$account")
    password=$(jq -r .password <<<"$account")
    if ((${#password} < 8)); then
      echo "skipping $id: password key missing or shorter than 8 characters" >&2
      continue
    fi
    if ! jq -e --arg id "$id" 'any(.users[]; .id == $id)' <<<"$users" >/dev/null; then
      graphql 'mutation ($u: CreateUserInput!) { createUser(user: $u) { id } }' \
        "$(jq -cn --arg id "$id" '{u: {id: $id, email: ($id + "@lldap.invalid"), displayName: ($id + " service account")}}')" >/dev/null
      echo "created $id"
    fi
    /app/lldap_set_password --base-url "$LLDAP_URL" --token "$token" --username "$id" --password "$password" >/dev/null

    want=$(jq -c --argjson g "$groups" '[.group // empty | . as $n | $g.groups[] | select(.displayName == $n) | .id]' <<<"$account")
    have=$(jq -c --arg id "$id" '[.users[] | select(.id == $id) | .groups[].id]' <<<"$users")
    for group in $(jq -nr --argjson w "$want" --argjson h "$have" '$w - $h | .[]'); do
      graphql 'mutation ($u: String!, $g: Int!) { addUserToGroup(userId: $u, groupId: $g) { ok } }' \
        "$(jq -cn --arg u "$id" --argjson g "$group" '{u: $u, g: $g}')" >/dev/null
      echo "added $id to group $group"
    done
    for group in $(jq -nr --argjson w "$want" --argjson h "$have" '$h - $w | .[]'); do
      graphql 'mutation ($u: String!, $g: Int!) { removeUserFromGroup(userId: $u, groupId: $g) { ok } }' \
        "$(jq -cn --arg u "$id" --argjson g "$group" '{u: $u, g: $g}')" >/dev/null
      echo "removed $id from group $group"
    done
  done < <(jq -c '.[]' <<<"$desired")

  for id in $(jq -r --argjson d "$desired" '[.users[].id | select(startswith("svc-"))] - [$d[].id] | .[]' <<<"$users"); do
    graphql 'mutation ($u: String!) { deleteUser(userId: $u) { ok } }' "$(jq -cn --arg u "$id" '{u: $u}')" >/dev/null
    echo "deleted $id"
  done
}

last=""
last_at=0
while true; do
  desired=$(desired_accounts)
  digest=$(sha256sum <<<"$desired")
  if [[ $digest != "$last" ]] || ((SECONDS - last_at >= 3600)); then
    apply "$desired"
    echo "synced $(jq length <<<"$desired") lldap-service-account Secrets"
    last=$digest
    last_at=$SECONDS
  fi
  sleep 30
done
