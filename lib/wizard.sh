# shellcheck shell=bash

# wizard_options <listing> <kind>
# <listing> is cmd_list's tab-separated output; every option the wizard offers
# comes from there rather than a list of its own. A second copy of what the
# adapters and services already declare is what broke scripts/adapter-matrix.sh
# on the previous branch — it parsed `scaffold list` while the workflow beside
# it carried its own list.
wizard_options() {
  local listing="$1" kind="$2"

  case "$kind" in
    web|api|app)
      awk -F'\t' -v role="$kind" \
        '$2 == role { printf "%s\ttier %s\n", $1, $3 }' <<< "$listing"
      # A shape that asked for this role wants one, but the frontend of a
      # web+api project is still optional in a way the api is not — the flags
      # allow it, so the wizard does too.
      #
      # `if`, not `&&`: this is the case branch's last command, and `&&`
      # would make the whole function return 1 whenever kind != web.
      if [ "$kind" = "web" ]; then
        printf 'none\tno frontend\n'
      fi
      ;;
    database)
      awk -F'\t' '$2 == "database" { printf "%s\t%s\n", $1, $2 }' <<< "$listing"
      printf 'none\tno database service\n'
      ;;
    cache)
      awk -F'\t' '$2 == "cache" { printf "%s\t%s\n", $1, $2 }' <<< "$listing"
      printf 'none\tno cache service\n'
      ;;
    *) die "unknown question kind: ${kind}" ;;
  esac
}

# wizard_order_options <kind> <listing> — wizard_options' rows for <kind>,
# with cmd_new's own unset-flag default moved first. database and cache are
# only ever asked where cmd_new would already default them (DEFAULT_DATABASE_
# SERVICE once there's a backend, none otherwise), so a plain Enter picks
# what the flags would have picked unset, instead of whatever wizard_options
# happened to list first.
wizard_order_options() {
  local kind="$1" listing="$2" default="" line

  case "$kind" in
    database) default="$DEFAULT_DATABASE_SERVICE" ;;
    cache) default="none" ;;
  esac

  if [ -z "$default" ]; then
    wizard_options "$listing" "$kind"
    return
  fi

  while IFS= read -r line; do
    if [ "${line%%$'\t'*}" = "$default" ]; then
      printf '%s\n' "$line"
    fi
  done <<< "$(wizard_options "$listing" "$kind")"
  while IFS= read -r line; do
    if [ "${line%%$'\t'*}" != "$default" ]; then
      printf '%s\n' "$line"
    fi
  done <<< "$(wizard_options "$listing" "$kind")"
  # the loop's own status is read's EOF failure, not this function's; without
  # this the default branch always reports failure on an otherwise-fine run.
  return 0
}

# wizard_shapes — the project shapes the wizard's first menu offers, one per
# line as name<TAB>description. cmd_wizard builds its menu from this, and
# wizard_questions accepts only what it lists — the single place either side
# reads, so a shape added to one and not the other fails a test instead of
# reaching a user four screens in.
wizard_shapes() {
  printf 'web+api\tseparate frontend and backend, one repository\n'
  printf 'app\tone application serving both pages and data\n'
  printf 'api\tbackend only\n'
  printf 'web\tfrontend only\n'
}

# wizard_questions <shape>
# The order the answers constrain each other in. `web` asks nothing about a
# database because `scaffold new` refuses --db without an api or app adapter,
# and a refusal the user can walk into is worse than one they cannot.
wizard_questions() {
  local shape="$1"

  wizard_shapes | cut -f1 | grep -qx "$shape" || die "unknown project shape: ${shape}"

  case "$shape" in
    web+api) printf 'web\napi\ndatabase\ncache\n' ;;
    app) printf 'app\ndatabase\ncache\n' ;;
    api) printf 'api\ndatabase\ncache\n' ;;
    web) printf 'web\n' ;;
    *) die "wizard_shapes lists ${shape} but wizard_questions has no case for it" ;;
  esac
}

# wizard_command <name> <kind=value>...
# What the answers would have been typed as. Printed before the run so the
# second project is scripted rather than clicked.
wizard_command() {
  local name="$1"; shift
  local out="scaffold new ${name}" pair kind value

  for pair in "$@"; do
    kind="${pair%%=*}"
    value="${pair#*=}"
    case "$kind" in
      web|api|app) [ "$value" = none ] || out+=" --${kind} ${value}" ;;
      database) out+=" --db ${value}" ;;
      cache) out+=" --cache ${value}" ;;
      *) die "unknown answer: ${pair}" ;;
    esac
  done

  printf '%s\n' "$out"
}
