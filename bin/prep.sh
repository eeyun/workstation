#!/usr/bin/env sh
# shellcheck shell=sh disable=SC2039

# Fails on unset variables & whenever a command returns a non-zero exit code.
set -eu
# If the variable `$DEBUG` is set, then print the shell commands as we execute.
if [ -n "${DEBUG:-}" ]; then set -x; fi

print_help() {
  printf -- "%s %s

%s

Workstation Setup

USAGE:
        %s [FLAGS] [OPTIONS] [<HOSTNAME>]

FLAGS:
    -b  Only sets up base system (not extra workstation setup)
    -h  Prints this message

OPTIONS:
    -a  macOS App Store credentials of the form <email>:<password>

ARGS:
    <HOSTNAME>  The name for this workstation

" "$_program" "$_version" "$_author" "$_program"
}

main() {
  local base_only opt

  _program="$(basename "$0")"
  _version="0.5.0"
  _author="Fletcher Nichol <fnichol@nichol.ca>"
  _system="$(uname -s)"

  OPTIND=1
  # Parse command line flags and options
  while getopts ":hba:" opt; do
    case $opt in
      a)
        _app_store_creds="$OPTARG"
        ;;
      b)
        base_only=true
        ;;
      h)
        print_help
        exit 0
        ;;
      \?)
        print_help
        exit_with "Invalid option:  -$OPTARG" 1
        ;;
    esac
  done
  # Shift off all parsed token in `$*` so that the subcommand is now `$1`.
  shift "$((OPTIND - 1))"

  if [ -n "${1:-}" ]; then
    _argv_hostname="$1"
  fi

  if [ "$_system" = "Darwin" ] \
      && [ "$base_only" != "true" ] \
      && [ ! -f "$HOME/Library/Preferences/com.apple.appstore.plist" ] \
      && [ -z "${_app_store_creds:-}" ]; then
    printf -- "Not logged into App Store, please provide '-a' option.\n\n"
    print_help
    exit_with "Must provide -a flag with <email>:<password>" 2
  fi

  init
  set_hostname
  setup_package_system
  update_system
  install_base_packages
  install_bashrc

  if [ "${base_only:-}" != "true" ]; then
    install_workstation_packages
    install_rust
    install_ruby
    install_node
    set_preferences
    install_dot_configs
  fi
}

init() {
  local p

  _hostname="$(hostname)"

  if [ "$_system" != "Linux" ]; then
    _os="$_system"
  elif [ -f /etc/lsb-release ]; then
    _os="$(. /etc/lsb-release; echo $DISTRIB_ID)"
  elif [ -f /etc/arch-release ]; then
    _os="Arch"
  else
    _os="Unknown"
  fi

  p="$(dirname "$0")"
  p="$(cd "$p"; pwd)/$(basename "$0")"
  p="$(portable_readlink "$p")"
  p="$(dirname "$p")"
  p="$(dirname "$p")"

  _data_path="$p/data"
  _lib_path="$p/lib"

  # shellcheck source=lib/common.sh
  . "$_lib_path/common.sh"
  case "$_system" in
    Darwin)
      # shellcheck source=lib/darwin.sh
      . "$_lib_path/darwin.sh"
      ;;
    Linux)
      # shellcheck source=lib/linux.sh
      . "$_lib_path/linux.sh"
      ;;
  esac

  header "Setting up workstation '${_argv_hostname:-$_hostname}'"

  ensure_not_root
  get_sudo
  keep_sudo

  if [ "$_system" = "Darwin" ]; then
    # Close any open System Preferences panes, to prevent them from overriding
    # settings we’re about to change
    osascript -e 'tell application "System Preferences" to quit'
  fi
}

set_hostname() {
  if [ -z "${_argv_hostname:-}" ]; then
    return 0
  fi

  local name="$_argv_hostname"

  header "Setting hostname to '$name'"
  case "$_os" in
    Darwin)
      need_cmd sudo
      need_cmd scutil
      need_cmd defaults

      local smb="/Library/Preferences/SystemConfiguration/com.apple.smb.server"
      if [ "$(scutil --get ComputerName)" != "$name" ]; then
        sudo scutil --set ComputerName "$name"
      fi
      if [ "$(scutil --get LocalHostName)" != "$name" ]; then
        sudo scutil --set LocalHostName "$name"
      fi
      if [ "$(defaults read "$smb" NetBIOSName)" != "$name" ]; then
        sudo defaults write "$smb" NetBIOSName -string "$name"
      fi
      ;;
    *)
      warn "Setting hostname on $_os not yet supported, skipping"
      ;;
  esac
}

setup_package_system() {
  header "Setting up package system"

  case "$_os" in
    Darwin)
      darwin_install_xcode_cli_tools
      darwin_install_homebrew
      ;;
    Ubuntu)
      sudo apt-get update | indent
      ;;
    Arch)
      sudo pacman -Syy --noconfirm | indent
      ;;
    *)
      warn "Setting up package system on $_os not yet supported, skipping"
      ;;
  esac
}

update_system() {
  header "Applying system updates"

  case "$_os" in
    Darwin)
      softwareupdate --install --all 2>&1 | indent
      ;;
    Ubuntu)
      # Nothing to do
      ;;
    Arch)
      sudo pacman -Su --noconfirm | indent
      ;;
    *)
      warn "Setting up package system on $_os not yet supported, skipping"
      ;;
  esac
}

install_base_packages() {
  header "Installing base packages"

  case "$_os" in
    Darwin)
      install_pkg jq
      install_pkgs_from_json "$_data_path/darwin_base_pkgs.json"
      ;;
    Ubuntu)
      install_pkg jq
      install_pkgs_from_json "$_data_path/ubuntu_base_pkgs.json"
      ;;
    Arch)
      install_pkg jq
      install_pkgs_from_json "$_data_path/arch_base_pkgs.json"
      ;;
    *)
      warn "Installing packages on $_os not yet supported, skipping"
      ;;
  esac
}

install_workstation_packages() {
  header "Installing workstation packages"

  case "$_os" in
    Darwin)
      darwin_add_homebrew_taps
      darwin_install_cask_pkgs_from_json "$_data_path/darwin_cask_pkgs.json"
      darwin_install_apps_from_json "$_data_path/darwin_apps.json"
      install_pkgs_from_json "$_data_path/darwin_workstation_pkgs.json"
      killall Dock
      killall Finder
      ;;
    Ubuntu)
      install_pkgs_from_json "$_data_path/ubuntu_workstation_pkgs.json"
      ;;
    Arch)
      install_pkgs_from_json "$_data_path/arch_workstation_pkgs.json"
      ;;
    *)
      warn "Installing packages on $_os not yet supported, skipping"
      ;;
  esac
}

install_rust() {
  local rustc="$HOME/.cargo/bin/rustc"
  local cargo="$HOME/.cargo/bin/cargo"

  header "Setting up Rust"

  if [ ! -x "$rustc" ]; then
    need_cmd curl

    info "Installing Rust"
    curl -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable 2>&1 \
      | indent
    "$rustc" --version | indent
    "$cargo" --version | indent
  fi

  if ! "$cargo" install --list | grep -q rustfmt; then
    info "Installing rustfmt"
    "$cargo" install rustfmt 2>&1 | indent
  fi
}

install_ruby() {
  header "Setting up Ruby"

  case "$_system" in
    Darwin)
      install_pkg chruby
      install_pkg ruby-install
      ;;
    Linux)
      linux_install_chruby
      linux_install_ruby_install
      ;;
    *)
      warn "Installing Ruby on $_os not yet supported, skipping"
      return 0
      ;;
  esac

  # shellcheck disable=SC2012
  if [ "$(ls -1 "$HOME/.rubies" 2> /dev/null | wc -l)" -eq 0 ]; then
    info "Building curent stable version of Ruby"
    ruby-install ruby 2>&1 | indent
  fi

  sudo mkdir -p /etc/profile.d

  if [ ! -f /etc/profile.d/chruby.sh ]; then
    info "Creating /etc/profile.d/chruby.sh"
    cat <<_CHRUBY_ | sudo tee /etc/profile.d/chruby.sh > /dev/null
source /usr/local/share/chruby/chruby.sh
RUBIES+=(/opt/chef/embedded)
source /usr/local/share/chruby/auto.sh
_CHRUBY_
  fi

  if [ ! -f /etc/profile.d/renv.sh ]; then
    info "Creating /etc/profile.d/renv.sh"
    download https://raw.githubusercontent.com/fnichol/renv/master/renv.sh \
      /tmp/renv.sh
    sudo cp /tmp/renv.sh /etc/profile.d/renv.sh
    rm -f /tmp/renv.sh
  fi
}

install_node() {
  need_cmd bash
  need_cmd curl
  need_cmd jq

  header "Setting up Node"

  local url version

  if [ ! -f "$HOME/.nvm/nvm.sh" ]; then
    info "Installing nvm"
    version="$(curl -sSf \
      https://api.github.com/repos/creationix/nvm/releases/latest \
      | jq -r .tag_name)"
    url="https://raw.githubusercontent.com/creationix/nvm/$version/install.sh"

    touch "$HOME/.bash_profile"
    curl -sSf "$url" | env PROFILE="$HOME/.bash_profile" bash 2>&1 | indent
  fi

  # shellcheck disable=SC2012
  if [ "$(ls -1 "$HOME/.nvm/versions/node" 2> /dev/null | wc -l)" -eq 0 ]; then
    info "Installing current stable version of Node"
    bash -c '. $HOME/.nvm/nvm.sh && nvm install --lts 2>&1' | indent
  fi
}

set_preferences() {
  header "Setting preferences"

  case "$_os" in
    Darwin)
      darwin_set_preferences "$_data_path/darwin_prefs.json"
      darwin_install_iterm2_settings
      ;;
    Ubuntu)
      # Nothing to do
      ;;
    *)
      warn "Installing packages on $_os not yet supported, skipping"
      ;;
  esac
}

install_bashrc() {
  need_cmd bash
  need_cmd rm
  need_cmd sudo

  if [ -f /etc/bash/bashrc.local ]; then
    return 0
  fi

  header "Installing fnichol/bashrc"
  download https://raw.githubusercontent.com/fnichol/bashrc/master/contrib/install-system-wide \
    /tmp/install.sh
  sudo bash /tmp/install.sh | indent
  rm -f /tmp/install.sh
}

install_dot_configs() {
  need_cmd cut
  need_cmd git
  need_cmd su

  header "Installing dot configs"

  local user homedir repo repo_dir
  user="$USER"
  homedir="$(homedir_for "$user")"
  if [ -z "$homedir" ]; then
    exit_with "Failed to determine home dir for '$user'" 9
  fi

  if [ ! -f "${homedir}/.homesick/repos/homeshick/homeshick.sh" ]; then
    info "Installing homeshick for '$user'"
    git clone --depth 1 git://github.com/andsens/homeshick.git \
      "$homedir/.homesick/repos/homeshick" | indent
  fi
  if [ "$(type -t homeshick)" != "function" ]; then
    # shellcheck disable=SC1090
    . "$homedir/.homesick/repos/homeshick/homeshick.sh"
  fi

  for repo in fnichol/dotfiles fnichol/dotvim; do
    repo_dir="${homedir}/.homesick/repos/$(echo "$repo" | cut -d '/' -f 2)"

    if [ ! -d "$repo_dir" ]; then
      info "Installing repo $repo for '$user'"
      homeshick --batch clone $repo 2>&1 | indent
    fi
  done

  info "Updating dotfile configurations links for '$user'"
  homeshick --force link 2>&1 | indent
}

exit_with() {
  case "${TERM:-}" in
    *term | xterm-* | rxvt | screen | screen-*)
      printf -- "\n\033[1;31mERROR: \033[1;37m${1:-}\033[0m\n\n" >&2
      ;;
    *)
      printf -- "\nERROR: ${1:-}\n\n" >&2
      ;;
  esac
  exit "${2:-10}"
}

portable_readlink() {
  local path="$1"

  case "$_system" in
    Darwin)
      python -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$path"
      ;;
    *)
      readlink -f "$path"
      ;;
  esac
}

main "$@" || exit 99
