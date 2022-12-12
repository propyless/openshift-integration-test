#!/bin/bash

# Integration testing Openshift Environment.

function unknown {
  local message="${@}"
  save_project_data
  destroy_project
  echo $message
  exit 3
}
function warn {
  local message="${@}"
  save_project_data
  destroy_project
  echo $message
  exit 2
}
function critical {
  local message="${@}"
  save_project_data
  destroy_project
  echo $message
  exit 1
}
function ok {
  local message="${@}"
  save_project_data
  destroy_project
  echo $message
  exit 0
}


# Check if logged in or needs to login
function login_ocp {
  local token=$1
  run_oc whoami
  if [[ "$?" -ne "0" ]]; then
    run_oc login $OCP_HOSTNAME
    local login_rc=$?
    if [[ "${login_rc}" -ne "0" ]]; then
      unknown "Can not log in to Openshift Cluster"
    else
      return $login_rc
    fi
  fi
}


# Create a Project
function create_project {
  run_oc new-project ${PROJECT_NAME}
  return $?
}


# create a app
function create_app {
  run_oc new-app "${@}"
  return $?
}


# Loop over the build name until its either "Complete" or "Failed".
# Will break after the build_timeout is reached.
function check_build_status {
  local app_name=$1; shift
  local build_timeout=$1; shift
  local end_time=$((SECONDS+build_timeout))

  # Loop over the build status to check if its done or not.
  while [[ $SECONDS -lt $end_time ]]; do
    local build_status=$(run_oc --output get build ${app_name}-1 --template={{.status.phase}})
    local build_rc=$(echo $build_status | cut -f 1 -d ' ')
    local build_op=$(echo $build_status | cut -f 2 -d ' ')

    if [[ "${build_op}" == "Complete" ]]; then
      return 0
    elif [[ "${build_op}" == "Failed" ]]; then
      return 1
    fi
    sleep 5
  done
  # If it exited out of the loop then the timeout hit.
  # Check if the build is still pending. It may not get a
  # pod placement.
  #
  # It could also be that its still running and is just
  # taking a long amount of time.
  # In that case alert a warning about slow build time.
}


# Find probable cause why build failed
# Will only be executed if the build failed.
function check_build_failure {
  local app_name=$1

  # Grab build logs
  local build_logs="$(run_oc --output logs --tail 1 build/${app_name}-1)"
  local build_rc=$(echo $build_logs | cut -f 1 -d ' ')
  local build_op=$(echo $build_logs | cut -f 2- -d ' ')

  # Check if its docker push related
  echo "${build_op}" \
    grep "Failed to push image:" 2>&1 >/dev/null
  if [[ "$?" -eq "0" ]]; then
    critical "Build failed to push to Registry: \"${build_op}\""
  fi

  # Check if its just a general build failure
  echo "${build_op}" \
    grep "error: build error:" 2>&1 >/dev/null
  if [[ "$?" -eq "0" ]]; then
    warn "Build failed to complete: \"${build_op}\""
  fi

  # We can't determine cause
  unknown "Build failure cause unhandled: \"${build_op}\""
}


# Expose the service to create a route.
# Should be same as the APPLICATION_NAME
function create_route {
  local app_name=$1
  run_oc expose service $app_name
}


# Get the FQDN of the route
function get_route {
  local app_name=$1; shift

  local route=$(run_oc --output get route $app_name --template="{{.spec.host}}")
  local route_rc=$(echo $route | cut -f 1 -d ' ')
  local route_op=$(echo $route | cut -f 2- -d ' ')

  # If failed to get route then return 1
  # otherwise return the route
  if [[ "${route_rc}" -ne "0" ]]; then
    return $route_rc
  else
    echo $route_op
  fi
}


# Polls AVI DNS to check if the route has been added
# and is activated.
function check_dns_resp {
  local route_fqdn=$1; shift
  local dns_ip=$1; shift
  local dns_timeout=$1

  local end_time=$((SECONDS+dns_timeout))
  while [[ $SECONDS -lt $end_time ]]; do
    # If debug is enabled print the command we intend to run
    if [[ "${DEBUG}" -eq "1" ]]; then
       (>&2 echo DEBUG: dig +short @${dns_ip} ${route_fqdn})
    fi

    local dig_result=$(dig +short @${dns_ip} ${route_fqdn})
    echo $dig_result | grep --silent -E '([0-9]{1,3}\.){3}[0-9]{1,3}'
    if [[ "$?" -eq "0" ]]; then
      return 0
    fi
    sleep 5
  done
  # If the loop runs until condition is met
  # then the DNS never managed to respond with
  # the A record for the FQDN.
  return 1

}

# Check if the route and app is responding.
# It could be nessecary to specify port if
# for example using AVI or custom HA proxy.
function check_app_reachable {
  local route_url=$1; shift
  local route_port=":$1"; shift
  local route_timeout=$1

  local end_time=$((SECONDS+route_timeout))

  # curl the route until response is recieved.
  # Should get result before timeout is reached.
  while [[ $SECONDS -lt $end_time ]]; do
    # curl the route, if return http code starts with 2 (success) then all is good :)
    if [[ "${DEBUG}" -eq "1" ]]; then
       (>&2 echo DEBUG curl ${route_url}${route_port} --max-time 2 --silent -o /dev/null -w "%{http_code}")
    fi

    local http_code=$(curl ${route_url}${route_port} \
      --max-time 2 \
      --silent \
      --output /dev/null \
      --write-out "%{http_code}"
    )
    # Check for http reponse starting with 2.
    echo "$http_code" | grep -E '^2' --silent
    if [[ "$?" -eq "0" ]]; then
      return 0
    fi
    sleep 5
  done
  # if the while loop continues until the condition is met..
  # then the route was never able to be reached
  # return 1 to say that this failed.
  return 1

}

# Save project data that could be relevant
# when troubleshooting the integ-test.
function save_project_data {
  local app_name=${T_APP_NAME}
  mkdir -p $LOG_PATH
  pushd $LOG_PATH >/dev/null 2>&1

  local exports=$(run_oc --output export all) #> all_resources.yaml
  local exports_op="$(echo "$exports" | cut -f 2- -d ' ')"
  echo "${exports_op}" > all_resources.yaml

  local build_log="$(run_oc --output logs build/${app_name}-1)" #> build.log
  local build_op="$(echo "$build_log" | cut -f 2- -d ' ')"
  echo "${build_op}" > build.log

  popd >/dev/null 2>&1
}


# Destroy the created project
function destroy_project {
  run_oc delete project $PROJECT_NAME
  return $?
}


# Run the OC command
# Will run commands verbosely when debug flag
# is enabled.
# Will return the oc commands return code by default
# unless "--output" is added as the first argument
# before the parameters to add to the OC command.
function run_oc {
  # Determine whether the oc command output should be returned.
  if [[ "$1" == "--output" ]]; then
    local RT_OUTPUT=1; shift
    local OC_ARGS=$@
  else
    local OC_ARGS=$@
  fi

  # TODO Fix this to be real debug
  if [[ "${DEBUG}" -eq "1" ]]; then
    if [[ "${RT_OUTPUT}" -eq "1" ]]; then
      echo_debug oc ${OC_CLI_PARAMS} ${OC_ARGS}
      local oc_cmd_output="$(oc ${OC_CLI_PARAMS} ${OC_ARGS} 2>&1)"
      local oc_cmd_rc=$?
      echo -ne "$oc_cmd_rc $oc_cmd_output"
    else
      echo_debug oc ${OC_CLI_PARAMS} ${OC_ARGS}
      oc ${OC_CLI_PARAMS} ${OC_ARGS} >/dev/null 2>&1
      return $?
    fi
  # Run as normal
  else
    if [[ "${RT_OUTPUT}" -eq "1" ]]; then
      local oc_cmd_output="$(oc ${OC_CLI_PARAMS} ${OC_ARGS} 2>&1)"
      local oc_cmd_rc=$?
      echo -ne "$oc_cmd_rc $oc_cmd_output"
    else
      oc ${OC_CLI_PARAMS} ${OC_ARGS} >/dev/null 2>&1
      return $?
    fi
  fi
}


function echo_debug {
  if [[ "${DEBUG}" -eq "1" ]]; then
    echo >&2 "DEBUG: ${@}"
  fi

}


function print_usage {
  cat << EOF
Usage example: $0
  -h | --hostname             - Hostname of the Openshift Cluster to connect to.
  -c | --auth_kubecfg         - Location of the .kubeconfig file. If you specify.
                                this you do not need to have token if the .kubeconfig.
                                already has a valid login.
  -L | --log_path             - Directory where log files should be placed.
  -l | --auth_token           - Authentication token to use when logging in to OCP cluster.
  -n | --project_name_prefix  - Specify if you want to change prefix of project name (default: integ-test).
  -a | --template             - Name of template you want to run.
  --context_dir               - Context dir used for new app source dir.
  --app_name                  - Name of the application created.
  2-r | --route_timeout        - Amount of time to pass before giving up route responding. Default: 120)
  -p | --route_port           - Port to connect when checking route. (Optional)

DNS Checks
  -d | --check_dns            - Enable DNS Checking.
  -i | --dns_ip               - IP Address of the DNS Server.
  -R | --dns_timeout          - Amount of time to pass before giving up checking hostname resolution (Default: 120).
EOF
}


function main {
  # Read integration test parameters
  while [[ $# -ge 1 ]]; do
    key="$1"
    case $key in
      -H | --hostname)
        local ocp_hostname="$2"
        shift # past argument=value
      ;;
      -c | --auth_kubecfg)
        local oc_cli_kubeconfig="--config=$2"
        shift # past argument=value
      ;;
      -l | --auth_token)
        local oc_cli_auth_token="--token='$2'"
        shift # past argument=value
      ;;
      -n | --project_name_prefix)
        local  pn_prefix="$2"
        shift # past argument=value
      ;;
      -a | --template)
        local template_name="$2"
        shift # past argument=value
      ;;
      --context_dir)
        local context_dir="--context-dir $2"
        shift # past argument=value
      ;;
      --app_name)
        local _app_name="--name $2"
        local app_name="$2"
        shift # past argument=value
      ;;
      -r | --route_timeout)
        local route_timeout="$2"
        shift # past argument=value
      ;;
      -b | --build_timeout)
        local build_timeout="$2"
        shift # past argument=value
      ;;
      -p | --route_port)
        local route_port="$2"
        shift # past argument=value
      ;;
      -d | --check_dns)
        local check_dns=1
      ;;
      -i | --avi_ip)
        local dns_ip="$2"
        shift # past argument=value
      ;;
      -R | --dns_timeout)
        local dns_timeout="$2"
        shift # past argument=value
      ;;
      -L | --log_path)
        local log_path="$2"
        shift # past argument=value
      ;;
      -P | --pretend)
        readonly PRETEND=1
      ;;
      -D| --debug)
        readonly DEBUG=1
      ;;
      -h | --help)
        print_usage
        exit 0
      ;;
      *)
        echo \"${key}\" is an invalid argument.
        print_usage
        exit 1
      ;;
    esac
  shift
  done
  # OC CLI Auth Parameters
  readonly OC_CLI_PARAMS=${oc_cli_kubeconfig}\ ${oc_cli_auth_token} # hostname + token + kubectl inputs
  readonly OCP_HOSTNAME="${ocp_hostname}"

  # Integration test parameters
  readonly PROJECT_NAME="${pn_prefix:-integ-test}-$(openssl rand -hex 3)" # project_name_prefix
  local T_NAME="${template_name}" # template it should use
  local _T_APP_NAME="${_app_name}" # template parameters to use together with oc-new app
  readonly T_APP_NAME="${app_name}" # template parameters to use together with oc-new app
  local T_CONTEXT_DIR="${context_dir}" # template parameters to use together with oc-new app
  local BUILD_TIMEOUT="${build_timeout:-180}" # time before build is deemed to not work - default 180 seconds
  local ROUTE_TIMEOUT="${route_timeout:-120}" # time before route is deemed to not work - default 120 seconds
  local ROUTE_PORT="${route_port}" # port to curl when checking route response

  # DNS Parameters
  local CHECK_DNS="${check_dns:-0}"
  local DNS_IP="${dns_ip}"
  local DNS_TIMEOUT="${dns_timeout:-120}"

  # Log directory setting
  readonly LOG_PATH="${log_path:-/var/log/integ-test-logs}/$(date +%F_%R)-${PROJECT_NAME}"


  echo_debug "oc_cli_auth:     $OC_CLI_PARAMS"
  echo_debug "Log Path:        $LOG_PATH"
  echo_debug "Project name:    $PROJECT_NAME"
  echo_debug "Template name:   $T_NAME"
  echo_debug "Source Context:  $T_CONTEXT_DIR"
  echo_debug "App Name:        $T_APP_NAME"
  echo_debug "Build Timeout:   $BUILD_TIMEOUT"
  echo_debug "Route Timeout:   $ROUTE_TIMEOUT"
  echo_debug "Check DNS:       $CHECK_DNS"
  echo_debug "DNS IP:          $DNS_IP"
  echo_debug "DNS Timeout:     $DNS_TIMEOUT"

  echo_debug "Login to Openshift"
  login_ocp

  echo_debug "Create Project"
  create_project
  if [[ "$?" -eq "1" ]]; then
    warn "Failed at creating project."
  fi

  echo_debug "Create App"
  create_app $T_NAME $_T_APP_NAME $T_CONTEXT_DIR
  if [[ "$?" -eq "1" ]]; then
    warn "Failed at creating new-app in project."
  fi

  echo_debug "Check build status"
  check_build_status $T_APP_NAME $BUILD_TIMEOUT

  # If build failed - Make alert
  if [[ "$?" -eq "1" ]]; then
    echo_debug "Build failed. Checking cause"
    check_build_failure $T_APP_NAME
  fi

  echo_debug "Expose the service"
  create_route $T_APP_NAME
  if [[ "$?" -eq "1" ]]; then
    warn "Failed at creating route."
  fi
  #fetch the route after its created.
  local ROUTE=$(get_route $T_APP_NAME)


  # check if the DNS gives proper response to fqdn query
  if [[ "$CHECK_DNS" -eq "1" ]]; then
    echo_debug "Check DNS responds to query"
    check_dns_resp "$ROUTE" "$DNS_IP" "$DNS_TIMEOUT"
    if [[ "$?" -eq "1" ]]; then
      critical "Route can not be found in DNS."
    fi
  fi

  echo_debug "Curl the Route"
  check_app_reachable "$ROUTE" "$ROUTE_PORT" "$ROUTE_TIMEOUT"
  if [[ "$?" -eq "1" ]]; then
    critical "Route is not reachable."
  fi

  #######################
  ## Everything is ok! ##
  #######################
  ok "Integration Test Passed"
}


main $@

