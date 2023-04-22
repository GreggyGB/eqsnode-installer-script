#!/usr/bin/env bash
# by Mister R

set -o errexit
set -o nounset
set -euo pipefail

script_basedir=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")
readonly script_basedir

source "${script_basedir}/common.sh"
source "${script_basedir}/discovery.sh"

installer_home=
auto_find_result=

#—disable-zmq

typeset -A command_options_set
command_options_set=(
  [help]=0
  [copy_blockchain]=0
  [inspect_auto_magic]=0
  [multi_node]=0
  [nodes]=0
  [ports]=0
  [skip_prepare_sn]=0
  [user]=0
  [version]=0
)
copy_blockchain_option_value=
nodes_option_value=
ports_option_value=
user_option_value=
version_option_value=

declare -A system_info


main() {
  install_dependencies
  print_splash_screen
  discover_system system_info
  process_command_line_args "$@"

  exit 0
  init
  install_checks
  install_manager
  finish_install
}

print_splash_screen () {
  cat <<'SPLASHMSG'

  _____            _ _ _ _          _
 | ____|__ _ _   _(_) (_) |__  _ __(_) __ _
 |  _| / _` | | | | | | | '_ \| '__| |/ _` |
 | |__| (_| | |_| | | | | |_) | |  | | (_| |
 |_____\__, |\__,_|_|_|_|_.__/|_|  |_|\__,_|
          |_|

SPLASHMSG
  echo -e "Service node installer script ${eqnode_installer_version}\n"
}

install_manager() {
  local idx=1

  while [ "${idx}" -le "${config[nodes]}" ]; do
    setup_running_user "${config["snode${idx}__running_user"]}"
    copy_installer_or_continue_session
    install_with_running_user

    idx=$((idx + 1))
  done

}

install_dependencies() {
  if ! [[ -x "$(command -v netstat)" && -x "$(command -v natsort)" && -x "$(command -v bc)" && -x "$(command -v grep)" && -x "$(command -v getopt)" && -x "$(command -v gawk)" ]]; then
    echo -e "\n\033[1mFixing required dependencies....\033[0m"
    sudo apt -y install net-tools python3-natsort bc grep util-linux gawk
  fi
}

process_command_line_args() {
  parse_command_line_args "$@"
  validate_parsed_command_line_args
  set_config_and_execute_info_commands
}

parse_command_line_args() {
  args="$(getopt -a -n installer -o "himc:n:p:u:v:" --long help,inspect-auto-magic,skip-prepare-sn,copy-blockchain:,nodes:,ports:,user:,version: -- "$@")"
  eval set -- "${args}"

  while :
  do
    case "$1" in
      -h | --help)                  command_options_set[help]=1 ; shift ;;
      -c | --copy-blockchain)       command_options_set[copy_blockchain]=1; copy_blockchain_option_value="$2"; shift 2 ;;
      -i | --inspect-auto-magic)    command_options_set[inspect_auto_magic]=1; shift ;;
      -n | --nodes)                 command_options_set[nodes]=1; nodes_option_value="$2"; shift 2 ;;
      -p | --ports)                 command_options_set[ports]=1; ports_option_value="$2"; shift 2 ;;
      --skip-prepare-sn)            command_options_set[skip_prepare_sn]=1 ; shift ;;
      -u | --user)                  command_options_set[user]=1; user_option_value="$2"; shift 2 ;;
      -v | --version)               command_options_set[version]=1; version_option_value="$2"; shift 2 ;;
      --)                           shift ; break ;;
      *)                            echo "Unexpected option: $1" ;
                                    usage
                                    exit 0 ;;
    esac
  done
}

set_config_and_execute_info_commands() {
  [[ "${command_options_set[help]}" -eq 1 ]] && usage && exit 0

  # set options first that effect other options and the parsing of their option value(s)
  if [[ "${command_options_set[nodes]}" -eq 1 ]]; then nodes_option_handler "${nodes_option_value}"; else nodes_option_handler 1; fi


  # info commands, exit 0 must be first listed options in this function
  [[ "${command_options_set[inspect_auto_magic]}" -eq 1 ]] && inspect_auto_magic_option_handler && exit 0

  # direct set config
  [[ "${command_options_set[skip_prepare_sn]}" -eq 1 ]] && config[skip_prepare_sn]=1

  # process more complex set config

  if [[ "${command_options_set[version]}" -eq 1 ]]; then version_option_handler "${version_option_value}"; else version_option_handler "auto"; fi
  if [[ "${command_options_set[ports]}" -eq 1 ]]; then ports_option_handler "${ports_option_value}"; else ports_option_handler "auto"; fi
  if [[ "${command_options_set[user]}" -eq 1 ]]; then user_option_handler "${user_option_value}"; else user_option_handler "auto"; fi
  if [[ "${command_options_set[copy_blockchain]}" -eq 1 ]]; then copy_blockchain_option_handler "${copy_blockchain_option_value}"; else copy_blockchain_option_handler "auto"; fi

  local keys=( $( echo ${!config[@]} | tr ' ' $'\n' | natsort) )
  for key in "${keys[@]}"
  do
    echo -e "${key}=${config[${key}]}"
  done
  exit 0
  # necessary return 0
  return 0
}

validate_parsed_command_line_args() {
  local friendly_option_groupings group_option_count command_options_set_string unique_count valid_option_combi_found
  valid_option_combi_found=0

  friendly_option_groupings=(
    "<no_options_set>"
    "copy_blockchain nodes ports user skip_prepare_sn version"
    "inspect_auto_magic nodes"
    "help"
  )
  command_options_set_string="$(generate_set_options_string)"
  [[ "${command_options_set_string}" = '' ]] && command_options_set_string='<no_options_set>'

  for option_string in "${friendly_option_groupings[@]}"
  do
    group_option_count="$(echo "${option_string}" | egrep -o '[^ ]+' | wc -l)"
    unique_count="$(echo "${option_string} ${command_options_set_string}" | egrep -o '[^ ]+' | natsort | uniq | wc -l)"

    [[ "${unique_count}" -le "${group_option_count}" ]] && valid_option_combi_found=1 && break
  done

  if [[ "${valid_option_combi_found}" -eq 0 && "${command_options_set_string}" != '<no_options_set>' ]]; then
    echo -e "\033[0;33merror: invalid parameter combination\033[0m\n"
    usage
    exit 1
  fi
}

generate_set_options_string() {
  local result=''
  for option in "${!command_options_set[@]}"
  do
    [[ "${command_options_set[$option]}" -eq 1 ]] && result+="${option} "
  done
  echo "${result}"
}

nodes_option_handler() {
  local max_nodes_by_free_space max_nodes_by_memory max_nodes

  if ! [[ "$1" =~ ^[0-9]+$ ]]; then
    echo -e "\033[0;33merror: invalid --nodes option value. Numbers only.\033[0m\n"
    exit 1
  fi

  max_nodes_by_free_space="$((system_info[free_space_home_mount] / 1024 / 50000))"
  max_nodes_by_memory="$((system_info[memory] / 1024 / 4000))"
  [[ "${max_nodes_by_memory}" -gt "$max_nodes_by_free_space" ]] && max_nodes="${max_nodes_by_memory}" || max_nodes="${max_nodes_by_free_space}"

  if [[ "$1" -gt "${max_nodes}" ]]; then
    echo -e "\033[0;33merror: Too many nodes set as --nodes option value. Max nodes: ${max_nodes}. Check system specifications (memory/disk space).\033[0m\n"
    exit 1
  fi
  config[nodes]="$1"

  # init node specific config placeholders
  local idx=1
  while [ "${idx}" -le "${config[nodes]}" ]; do
    config["snode${idx}__running_user"]=
    config["snode${idx}__copy_blockchain"]=
    config["snode${idx}__p2p_bind_port"]=0
    config["snode${idx}__rpc_bind_port"]=0
    idx=$((idx + 1))
  done

  return 0
}

copy_blockchain_option_handler() {
  local blockchain fixed_value
  local idx=1
  local option_value="$1"

  if [[ "${option_value}" = "auto" ]]; then
    blockchain="$(discover_biggest_blockchain)"
    if [[ -d "${blockchain}" ]]; then option_value="${blockchain}"; else option_value="no,auto"; fi
  fi

  # TODO: check directory contains blockchain
  if [[ "${option_value}" = "no" || -d "${option_value}" ]]; then
      while [ "${idx}" -le "${config[nodes]}" ]; do
        config["snode${idx}__copy_blockchain"]="${option_value}"
        idx=$((idx + 1))
      done
  elif [[ "${option_value}" = "no,auto" ]]; then
      while [ "${idx}" -le "${config[nodes]}" ]; do
        if [[ "${idx}" -eq 1 ]]; then
            config["snode${idx}__copy_blockchain"]="no"
        else
            config["snode${idx}__copy_blockchain"]="/home/${config["snode1__running_user"]}/.equilibria"
        fi
        idx=$((idx + 1))
      done
  else
    echo -e "\n\033[0;33merror: invalid --copy-blockchain value or directory '$1'\033[0m\n"
    usage
    exit 1
  fi

  idx=1
  echo -e "\n\033[1mBlockchain copy status...\033[0m"
  while [ "${idx}" -le "${config[nodes]}" ]; do
    [[ "${config[nodes]}" -gt 1 ]] && echo -e "\nService Node ${idx}:"
    echo -e "Copy blockchain: ${config["snode${idx}__copy_blockchain"]}"
    idx=$((idx + 1))
  done
}

auto_search_blockchain() {
  local blockchain
  blockchain="$(discover_biggest_blockchain)"

  if [[ -d "${blockchain}" ]]; then
    config[copy_blockchain]="${blockchain}"
  else
    config[copy_blockchain]="no>auto"
  fi
}

version_option_handler() {
  if [[ "$1" = "auto" ]]; then
    echo -e "\n\033[1mAuto-detecting latest Equilibria version...\033[0m"
    config[install_version]="$(get_latest_equilibria_version_number)"
  elif [[ "$1" =~ $version_regex} ]]; then
    config[install_version]="$1"
    echo -e "\n\033[1mInstalling manually set Equilibria version:\033[0m"
  else
    echo -e "Invalid --version value '$1'\n"
    usage
    exit 1
  fi
  echo -e "Version -> ${config[install_version]}"
}

auto_ports_option_handler() {
  echo -e "\n\033[1mAuto-detecting available ports...\033[0m"
  declare -A discovered_sets
  discover_free_port_sets discovered_sets "${config[nodes]}"

  local idx=1
  while [ "${idx}" -le "${config[nodes]}" ]; do
    config["snode${idx}__p2p_bind_port"]="${discovered_sets["set${idx}__p2p_bind_port"]}"
    config["snode${idx}__rpc_bind_port"]="${discovered_sets["set${idx}__rpc_bind_port"]}"

    [[ "${config[nodes]}" -gt 1 ]] && echo -e "\nService Node ${idx}:"
    echo -e "Detected available p2p_bind_port -> port ${config["snode${idx}__p2p_bind_port"]}"
    echo -e "Detected available rpc_bind_port -> port ${config["snode${idx}__rpc_bind_port"]}"

    idx=$((idx + 1))
  done
}

inspect_auto_magic_option_handler() {
  version_option_handler "auto"
  ports_option_handler "auto"
  user_option_handler "auto"
  copy_blockchain_option_handler "auto"

  echo -e "\nIf needed you can alter these settings manually by one of the following commands (or combination):\n\033[0;33m"
  echo -e "    bash install.sh -v ${config[install_version]}"
  echo -e "    bash install.sh -p p2p:9330,rpc:9331,zmq:9332"
  echo -e "    bash install.sh -u mysnodeuser\033[0m\n"
}

user_option_handler() {
  if [[ "$1" = "auto" ]]; then
    auto_search_available_username

  elif validate_manual_user_string_format "$1"; then
    validate_manual_users_and_set_config_if_valid "$1"
  else
    echo -e "\nInvalid --user value '$1'\n"
    usage
    exit 1
  fi
}

validate_manual_user_string_format() {
  [[ "$(echo "$1" | grep -oP -e "(?<=,|^)+[a-zA-Z][a-zA-Z0-9]+(?=,|$)+" | natsort | uniq | wc -l)" -eq "${config[nodes]}" ]]
}

validate_manual_users_and_set_config_if_valid() {
  local usernames idx
  read -a usernames <<< "${1//,/ }"

#  echo "${usernames[@]}"
  idx=1
  for username in "${usernames[@]}"
  do
    if running_user_has_active_daemon "${username}"; then
      echo -e "\n\033[0;33mSAFETY POLICY VIOLATION: User '${username}' is already running an active service node daemon. Please install with a different user!\033[0m"
      echo -e "\nInstallation aborted."
      exit 1
    elif running_user_has_active_installation "${username}"; then
      echo -e "\n\033[0;33mSAFETY POLICY VIOLATION: User '${username}' is running an active installation. Please install with a different user!\033[0m"
      echo -e "\nInstallation aborted."
      exit 1
    fi
    config["snode${idx}__running_user"]="${username}"
    idx=$((idx + 1))
  done
}

ports_option_handler() {
  if [[ "$1" = "auto" ]]; then
    auto_ports_option_handler
  elif valid_manual_port_string_format "$1" ; then
    parse_manual_port_string_and_set_config_if_valid "$1"
  else
    echo -e "Invalid --ports config format '$1'\n"
    usage
  fi
}

# TODO: can probably be simplified
valid_manual_port_string_format() {
  [[
    # check if basic format is valid either p2p:[0-9+],rpc:[0-9]+ or in reversed order rpc:[0-9+],p2p:[0-9]+
    "$(echo "$1" | grep -oP -e "^[a-z2]{3}:[0-9+]+,[a-z2]{3}:[0-9+]+$" | grep -oE -e "p2p:[0-9+]+" -e "rpc:[0-9+]+" | wc -l )" -eq 2 &&

    # check if number of p2p: ports equals the number of nodes
    "$(echo "$1" | grep -oP -e 'p2p:[0-9+]+' | grep -oP -e "(?<=p2p:|\+)[0-9]+" | wc -l )" -eq "${config[nodes]}" &&

    # check if number of rpc: ports equals the number of nodes
    "$(echo "$1" | grep -oP -e 'rpc:[0-9+]+' | grep -oP -e "(?<=rpc:|\+)[0-9]+" | wc -l )" -eq "${config[nodes]}" &&

    # Since all ports should be unique. Check if total number of unique ports equals (number of nodes * 2 ports(p2p+rpc) each)
    "$(echo "$1" | grep -oP -e '(?<=p2p:|rpc:|\+)+[0-9]+' | natsort | uniq | wc -l)" -eq "(${config[nodes]} * 2)"
  ]]
}

running_user_has_active_installation() {
   [[ "$(sudo ps aux | grep '[b]ash.*eqsnode.sh' | grep -v '[s]udo' | gawk '{ printf("%s\n", $1) }' | grep -c "$1")" -gt 0 ]]
}

parse_manual_port_string_and_set_config_if_valid() {
  typeset -A key_to_config_param
  key_to_config_param=(
    [p2p]='p2p_bind_port'
    [rpc]='rpc_bind_port'
  )
  local params validation_result port_error port_key port_values port_value_string single_port_value

  # shellcheck disable=SC2207
  # basically split manual port string on separator ','
  read -a params <<< "${1//,/ }"
  port_error=0

  echo -e "\n\033[1mAnalyzing manual port configuration...\033[0m"

  for key_value in "${params[@]}"
  do
    local idx=1
    # split key_value pair on divider ':'
    read -r port_key port_value_string <<< "${key_value//:/ }"

    read -a port_values <<< "${port_value_string//+/ }"

    for single_port_value in "${port_values[@]}"
    do
      validation_result="$(validate_port "${single_port_value}")"

      case "${validation_result}" in
        'outside_port_range') printf "%s: %d \t-> \033[0;33mOut of range [allowed between 5000-49151]\033[0m\n" "${key_to_config_param[${port_key}]}" "${single_port_value}"
                              port_error=1 ;;

        'port_used')          printf "%s: %d \t-> \033[0;33mIn use\033[0m\n" "${key_to_config_param[${port_key}]}" "${single_port_value}"
                              port_error=1 ;;

        'free_port')          printf "%s: %d \t-> OK\n" "${key_to_config_param[${port_key}]}" "${single_port_value}"
                              config["snode${idx}__${key_to_config_param[${port_key}]}"]="${single_port_value}" ;;

        *)                    echo "Unknown port validation result" ; exit 1 ;;
      esac
      idx=$((idx + 1))
    done
  done
  if [[ "${port_error}" -eq 1 ]]; then
    exit 1
  fi
}

auto_search_available_username() {
  echo -e "\n\033[1mAuto-searching for an unused username to run the service node...\033[0m"

  declare -A discovered_usernames
  discover_available_usernames discovered_usernames "${config[nodes]}" "${config[running_user]}"

  local idx=1
  while [ "${idx}" -le "${config[nodes]}" ]; do
    config["snode${idx}__running_user"]="${discovered_usernames["${idx}"]}"
    [[ "${config[nodes]}" -gt 1 ]] && echo -e "\nService Node ${idx}:"
    echo -e "Detected unused username -> ${discovered_usernames["${idx}"]}"
    idx=$((idx + 1))
  done
}

init() {
  [[ "${config[running_user]}" = "root" ]] && homedir='/root' || homedir="/home/${config[running_user]}"
  installer_home="${homedir}/eqnode_installer"
}

install_checks () {
  echo -e "\n\033[1mExecuting pre-install checks...\033[0m"
  inspect_time_services
  upgrade_cmake_if_needed
}

inspect_time_services () {
  echo -e "\n\033[1mChecking clock NTP synchronisation...\033[0m"

  if  [[ -x "$(command -v timedatectl)" ]]; then
    if [[ $(sudo timedatectl | grep -o -e 'synchronized: yes' -e 'service: active' | wc -l) -ne 2 ]]; then
      echo -e "\n\033[0;33mERROR: Clock NTP synchronisation is not working correctly. This is required to run a stable service node. Please fix 'timedatectl' before continuing.\033[0m\n"
      timedatectl
      exit 1
    fi
  else
    echo -e "\033[0;33mWARNING: Clock NTP synchronisation could not be verified.\nPlease check and make sure this is working before continuing!\033[0m\n"
    while true; do
      read -p $'\033[1mAre you sure you want to continue?\e[0m (NOT RECOMMENDED) [Y/N]: ' yn
      yn=${yn:-N}

      case $yn in
            [Yy]* ) break;;
            [Nn]* ) exit 1;;
            * ) echo -e "(Please answer Y or N)";;
      esac
    done
  fi
}

upgrade_cmake_if_needed() {
  local current_cmake_version distro_name distro_version_codename

  [[ -x "$(command -v cmake)" ]] && current_cmake_version="$(cmake --version | awk 'NR==1 { print $3  }')" || current_cmake_version=0

  distro_name="$(lsb_release -a 2> /dev/null | grep 'Distributor ID:' | awk '{ print tolower($3) }')"
  distro_version_codename="$(lsb_release -a 2>/dev/null | grep 'Codename:' | awk '{ print $2 }')"

  if [[ "${distro_name}" = "ubuntu" && ( "${current_cmake_version}" -eq 0 || $(version2num "${current_cmake_version}") -lt $(version2num "3.18") ) ]]; then
    echo -e "\n\033[1mUpgrading cmake (${current_cmake_version}) to newest version...\033[0m"
    sudo apt-get update
    sudo apt-get -y install gpg wget
    wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | gpg --dearmor - | sudo tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ ${distro_version_codename} main" | sudo tee /etc/apt/sources.list.d/kitware.list >/dev/null
    sudo apt-get update
    sudo apt-get -y install cmake
  fi
}

scan_for_concurrent_install_sessions() {
  local pids pid_exec_path install_session_states home_user
  pids=( $(sudo ps aux | egrep '[b]ash.*eqsnode.sh' | gawk '{ print $2 }' | grep '[0-9]') )
  install_session_states=()

  for process_id in "${pids[@]}"
  do
    # surpress stderr of pwdx command (in case process is stopped), which would otherwise break the command
    pid_exec_path="$(sudo pwdx "${process_id}" 2> /dev/null | grep -o '/.*')"

    # empty when process stopped
    if [[ "${pid_exec_path}" != "" ]] && [[ -f "${pid_exec_path}/.installsessionstate" ]]; then
      home_user="$(echo "${pid_exec_path}" | grep -oP '/home/\K[^/]*')"
      install_session_states+=("${home_user};${process_id};$(cat "${pid_exec_path}/.installsessionstate");${pid_exec_path}")
    fi
  done

  # shellcheck disable=SC2086
  echo ${install_session_states[*]}
}

setup_running_user () {
  local running_user="$1"
#  validate_running_user "$1"
  create_running_user_if_needed "$1"
  sudoers_running_user_nopasswd 'add'
}

#validate_running_user() {
#  local running_user="$1"
#  echo -e "\n\033[1mValidating user '${running_user}'...\033[0m"
#
#  if running_user_has_active_daemon "${running_user}"; then
#    echo -e "\n\033[0;33mSAFETY POLICY VIOLATION: User '${running_user}' is already running an active service node daemon. Please install with a different user!\033[0m"
#    echo -e "\nIn case you want to install a second service node on this VPS or server, please use the following command instead:\n\n\033[0;33m    bash install.sh -m\033[0m"
#    echo -e "\nInstallation aborted."
#
#    exit 1
#  fi
#}

running_user_has_active_daemon() {
   [[ "$(sudo ps aux | egrep '[b]in/daemon.*--service-node' | gawk '{ print $1 }' | natsort | uniq | grep -o "^${1}$" | wc -l)" -gt 0 ]]
}

create_running_user_if_needed() {
   # shellcheck disable=SC2154
   if ! id -u "${config[running_user]}" >/dev/null 2>&1; then
     echo -e "\n\033[1mCreating sudo user '${config[running_user]}' to run service node...\033[0m"
     echo -e "\n\033[0;33mWe need to create a user '${config[running_user]}' to run the service node. You will be asked to enter a password for this user next. Please make sure to keep this password safe.\033[0m\n"
     read -n 1 -s -r -p "Press ANY key to continue"

     sudo adduser --gecos GECOS "${config[running_user]}"
     sudo usermod -aG sudo "${config[running_user]}"
   fi
}

sudoers_running_user_nopasswd() {
  local action="$1"
  local sudo_settings sed_command
  [[ "${action}" = 'add' ]] && sudo_settings='ALL=(ALL) NOPASSWD:ALL' || sudo_settings='ALL=(ALL:ALL) ALL'
  # shellcheck disable=SC2116
  sed_command="$(echo "/^${config[running_user]} /{h;s/ .*/ ${sudo_settings}/};\${x;/^$/{s//${config[running_user]} ${sudo_settings}/;H};x}")"
  sudo sed -i "${sed_command}" /etc/sudoers
}

copy_installer_or_continue_session() {
  if [[ -d "${installer_home}" ]]; then
    if [[ -f "${installer_home}/.installsessionstate" ]] && [[ "$(cat "${installer_home}/.installsessionstate")" = "${installer_state[finished_eqsnode_install]}" ]]; then
      echo -e "\033[0;33mA finished installation of an Equilibria service node has been found! This installation script is ONLY for fresh installations not for updating a service node.\033[0m"
      exit 0
    fi

    echo -e "\n\033[1mA previous installation session for user '${config[running_user]}' has been detected with the following config:\033[0m"
    # Echo install.conf, while skipping #-comment lines
    cat "${installer_home}/install.conf" | egrep "^[^#].*"
    echo ""

    while true; do
      read -p 'Do you want to continue or overwrite this session? (or press ENTER to abort installation) [C/O]: ' co
      co=${co:-exit}

      case $co in
            [Cc]* )       break;;
            [Oo]* )       copy_installer_to_install_user_homedir
                          break;;
            quit | exit)  echo -e "\nInstallation aborted."; exit 0 ;;
            * )           echo -e "(Please answer C or O)";;
      esac
    done
  else
    copy_installer_to_install_user_homedir
  fi
}

copy_installer_to_install_user_homedir() {
  [[ -d "${installer_home}" ]] && echo -e "\033[1mDeleting old installer files...\033[0m" && sudo rm --recursive --force -- "${installer_home}"

  echo -e "\n\033[1mCopying installer to '${installer_home}'...\033[0m"
  sudo mkdir "${installer_home}"
  sudo cp eqsnode.sh eqnode.service.template common.sh "${installer_home}"
  write_install_config_to_install_user_homedir
  sudo chown -R "${config[running_user]}":root "${installer_home}"
}

write_install_config_to_install_user_homedir() {
  local install_file_user_home
  install_file_user_home="${installer_home}/install.conf"

  echo -e "\n\033[1mGenerating new install.conf in '${install_file_user_home}'...\033[0m"
  sudo touch "${install_file_user_home}"

  for key in "${!config[@]}"
  do
    echo -e "${key}=${config[${key}]}" | sudo tee -a "${install_file_user_home}"
  done
}

install_with_running_user() {
#  create_install_session_screen_lifeline
  sudo -H -u "${config[running_user]}" bash -c 'cd ~/eqnode_installer/ && bash eqsnode.sh install'
#  sudo -H -u "snode" bash -c 'cd ~/eqnode_installer/ && bash eqsnode.sh fakerun'
}

finish_install() {
  sudoers_running_user_nopasswd 'remove'
  echo -e "\n\033[1mInstallation of Service Node completed.\033[0m\n"
  echo -e "\033[0;33mPlease DO NOT forget to link a wallet to the new service node! This is done by copy and pasting the command line, obtained during the 'prepare_sn' step, into the wallet. Only then the activation of the service node will be complete and available for staking!\033[0m\n"
  su - "${config[running_user]}"
}

usage() {
  cat <<USAGEMSG

bash $0 [OPTIONS...]

Options:
  -c --copy-blockchain [no|auto|path]   Copy a previously downloaded blockchain if present on
                                        VPS or server for fast installation. Set 'auto' for
                                        auto-detect (default). Set a .equilibria directory or
                                        'no' to force a fresh download of the blockchain. Use
                                        'no,auto' when the first node should download a fresh
                                        blockchain, while subsequent node installations should
                                        copy this fresh blockchain download.

                                        Examples: --copy-blockchain auto
                                                  --copy-blockchain /home/snode/.equilibria
                                                  --copy-blockchain no
                                                  --copy-blockchain no,auto

  -i --inspect-auto-magic               Display preview of all automatically set port,
                                        users and Equilibria version
  -n --nodes [number]                   Number of nodes to install. If --nodes option is
                                        not specified, then only one node will be installed.
                                        If --nodes is to number > 1, then '--user auto' is
                                        used by default.
  -p  --ports [auto|config]             Set port configuration. Format:
                                        p2p:<port[+port+...]>,rpc:<port[+port+...]>

                                        Examples:
                                        --ports p2p:9330,rpc:9331
                                        --nodes 2 --ports p2p:9330+9430,rpc:9331+9431

                                        Auto detect ports; This requires ALL other service
                                        nodes to be active.
                                        Example:  --ports auto

  -u --user [auto|name,...]             Set username that will run the service node or
                                        'auto' for autodetect. In case --nodes option is
                                        set you can add multiple usernames comma separated.
                                        Examples:   --user snode2
                                                    --user auto
                                                    --nodes 2 --user snode,snode2
                                                    --nodes 2 --user auto

  -v --version [auto|version]           Set Equilibria version with format 'v0.0.0'. Use
                                        'auto' to install the latest version.

  -h  --help                            Show this help text

USAGEMSG
}

finally() {
  result=$?
  echo ""
  exit ${result}
}
trap finally EXIT ERR INT

main "${@}"
exit 0
