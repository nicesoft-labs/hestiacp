set -o nounset
set -o pipefail

#----------------------------------------------------------#
#                  Variables&Functions                     #
#----------------------------------------------------------#
export PATH=$PATH:/sbin
export DEBIAN_FRONTEND=noninteractive
RHOST='rpm.hestiacp.com'
VERSION='niceos'
HESTIA='/usr/local/hestia'
LOG="/root/hst_install_backups/hst_install-$(date +%d%m%Y%H%M).log"
memory=$(grep 'MemTotal' /proc/meminfo | tr ' ' '\n' | grep [0-9])
hst_backups="/root/hst_install_backups/$(date +%d%m%Y%H%M)"
spinner="/-\\|"
os='niceos'
release=$(awk -F= '/^VERSION_ID/ {gsub(/\"/,"",$2); print $2}' /etc/os-release | cut -d '.' -f 1)
architecture="$(arch)"
HESTIA_INSTALL_DIR="$HESTIA/install/niceos"
HESTIA_COMMON_DIR="$HESTIA/install/common"
VERBOSE='no'

# Supported PHP versions
multiphp_v=("7.3" "7.4" "8.0" "8.1" "8.2" "8.3")
# One of the following PHP versions is required for Roundcube / phpmyadmin
multiphp_required=("7.4" "8.0" "8.1" "8.2" "8.3")
# Default PHP version if none supplied
fpm_v="8.1"
# MariaDB version
mariadb_v="10.11"
# Node.js version
node_v="20"

# Defining software pack for NAIS.OS / CentOS-like base
software="acl httpd httpd-tools mod_proxy_fcgi mod_ssl at bc bind bind-utils clamav clamav-update cronie curl dovecot dovecot-pigeonhole \
  exim fail2ban ftp git ipset jq mariadb mariadb-server net-tools nginx openssh-server \
  php php-cli php-common php-fpm php-gd php-intl php-ldap php-mbstring php-mysqlnd php-opcache php-pgsql php-pecl-zip php-process php-soap php-xml php-xmlrpc \
  postgresql postgresql-server postgresql-contrib proftpd quota rrdtool rsyslog spamassassin s-nail sysstat unzip util-linux vim-enhanced vsftpd whois zip zstd \
  firewalld policycoreutils policycoreutils-python-utils dnf-plugins-core bubblewrap restic"

installer_dependencies="ca-certificates curl dnf-plugins-core findutils gnupg2 openssl sudo wget epel-release"

# Defining help function
help() {
        cat <<USAGE
Usage: $0 [OPTIONS]
  -a, --apache            Install Apache        [yes|no]  default: yes
  -w, --phpfpm            Install PHP-FPM       [yes|no]  default: yes
  -o, --multiphp          Install MultiPHP      [yes|no]  default: no
  -v, --vsftpd            Install VSFTPD        [yes|no]  default: yes
  -j, --proftpd           Install ProFTPD       [yes|no]  default: no
  -k, --named             Install BIND          [yes|no]  default: yes
  -m, --mysql             Install MariaDB       [yes|no]  default: yes
  -M, --mysql8            Install MySQL 8       [yes|no]  default: no
  -g, --postgresql        Install PostgreSQL    [yes|no]  default: no
  -x, --exim              Install Exim          [yes|no]  default: yes
  -z, --dovecot           Install Dovecot       [yes|no]  default: yes
  -Z, --sieve             Install Sieve         [yes|no]  default: no
  -c, --clamav            Install ClamAV        [yes|no]  default: yes
  -t, --spamassassin      Install SpamAssassin  [yes|no]  default: yes
  -i, --iptables          Install iptables      [yes|no]  default: yes
  -b, --fail2ban          Install Fail2Ban      [yes|no]  default: yes
  -q, --quota             Filesystem Quota      [yes|no]  default: no
  -L, --resourcelimit     Resource Limitation   [yes|no]  default: no
  -W, --webterminal       Web Terminal          [yes|no]  default: no
  -d, --api               Activate API          [yes|no]  default: yes
  -r, --port              Change Backend Port             default: 8083
  -l, --lang              Default language                default: en
  -y, --interactive       Interactive install   [yes|no]  default: yes
  -s, --hostname          Set hostname
  -e, --email             Set admin email
  -u, --username          Set admin user
  -p, --password          Set admin password
  -f, --force             Force installation
  -h, --help              Print this help

  Example: bash $0 -e demo@hestiacp.com -p p4ssw0rd --multiphp yes
USAGE
        exit 1
}

# Logging helper
log() {
        local level="$1"; shift
        echo "[$(date +%F' '%T)] [$level] $*" | tee -a "$LOG"
}

# Defining password-gen function
gen_pass() {
        matrix=$1
        length=$2
        if [ -z "$matrix" ]; then
                matrix="A-Za-z0-9"
        fi
        if [ -z "$length" ]; then
                length=16
        fi
        head /dev/urandom | tr -dc $matrix | head -c$length
}

check_result() {
        if [ $1 -ne 0 ]; then
                log ERROR "$2"
                exit $1
        fi
}

wait_for_apt_lock() {
        return 0
}

progress() {
        return 0
}

selinux_set_permissive() {
        if command -v getenforce >/dev/null 2>&1; then
                current=$(getenforce)
                if [ "$current" != "Disabled" ]; then
                        log INFO "Setting SELinux to permissive mode for installation"
                        setenforce 0 || true
                        if grep -q '^SELINUX=enforcing' /etc/selinux/config; then
                                sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
                        fi
                fi
        fi
}

ensure_dnf() {
        if ! command -v dnf >/dev/null 2>&1; then
                echo "Error: dnf package manager is required"
                exit 1
        fi
}

setup_repos() {
        log INFO "Enabling EPEL repository"
        dnf -y install epel-release >>"$LOG" 2>&1
        check_result $? "Failed to install epel-release"
        if dnf repolist | grep -q "powertools"; then
                log INFO "Enabling PowerTools repository"
                dnf config-manager --set-enabled powertools >>"$LOG" 2>&1 || true
        fi
}

install_dependencies() {
        log INFO "Installing installer dependencies"
        dnf -y install $installer_dependencies >>"$LOG" 2>&1
        check_result $? "Failed to install base dependencies"
}

install_software() {
        log INFO "Installing core packages via dnf"
        dnf -y install $software >>"$LOG" 2>&1
        check_result $? "Failed to install required software"
}

configure_services() {
        log INFO "Enabling essential services"
        systemctl enable nginx httpd mariadb exim || true
        systemctl enable firewalld || true
        systemctl enable php-fpm || true
}

initialize_databases() {
        if [ -x /usr/bin/mysql_install_db ]; then
                log INFO "Initializing MariaDB database"
                mysql_install_db --user=mysql >>"$LOG" 2>&1 || true
        elif [ -x /usr/bin/mysql_secure_installation ]; then
                log INFO "Running mysql_secure_installation in non-interactive mode"
                MYSQL_PWD=$(gen_pass "A-Za-z0-9" 22)
                mysql_secure_installation <<EOFMYSQL >>"$LOG" 2>&1 || true
n
n
y
y
y
y
$MYSQL_PWD
$MYSQL_PWD
EOFMYSQL
        fi

        if [ -x /usr/bin/postgresql-setup ]; then
                log INFO "Initializing PostgreSQL database cluster"
                postgresql-setup initdb >>"$LOG" 2>&1 || true
        fi
}

prepare_hestia_layout() {
        log INFO "Preparing Hestia directory structure"
        mkdir -p "$HESTIA_INSTALL_DIR" "$HESTIA_COMMON_DIR" "$hst_backups"
        rsync -a install/common/ "$HESTIA_COMMON_DIR"/ >>"$LOG" 2>&1
        check_result $? "Failed to stage common installer assets"
}

system_compat_checks() {
        if [ "$architecture" != "x86_64" ]; then
                echo "Error: Only x86_64 is supported for NAIS.OS installer"
                exit 1
        fi
        if [ "$release" -lt 7 ]; then
                echo "Error: NAIS.OS versions earlier than 7 are not supported"
                exit 1
        fi
}

#----------------------------------------------------------#
#                       Parsing args                       #
#----------------------------------------------------------#
apache='yes'
phpfpm='yes'
multiphp='no'
vsftpd='yes'
proftpd='no'
named='yes'
mysql='yes'
mysql8='no'
postgresql='no'
exim='yes'
dovecot='yes'
sieve='no'
clamav='yes'
spamassassin='yes'
iptables='yes'
fail2ban='yes'
quota='no'
resourcelimit='no'
webterminal='no'
api='yes'
port='8083'
lang='en'
interactive='yes'
hostname=$(hostname -f)
email=''
user='admin'
password=''
force='no'

while [ "$#" -gt 0 ]; do
        case $1 in
        -a|--apache) apache=$2; shift 2 ;;
        -w|--phpfpm) phpfpm=$2; shift 2 ;;
        -o|--multiphp) multiphp=$2; shift 2 ;;
        -v|--vsftpd) vsftpd=$2; shift 2 ;;
        -j|--proftpd) proftpd=$2; shift 2 ;;
        -k|--named) named=$2; shift 2 ;;
        -m|--mysql) mysql=$2; shift 2 ;;
        -M|--mysql8) mysql8=$2; shift 2 ;;
        -g|--postgresql) postgresql=$2; shift 2 ;;
        -x|--exim) exim=$2; shift 2 ;;
        -z|--dovecot) dovecot=$2; shift 2 ;;
        -Z|--sieve) sieve=$2; shift 2 ;;
        -c|--clamav) clamav=$2; shift 2 ;;
        -t|--spamassassin) spamassassin=$2; shift 2 ;;
        -i|--iptables) iptables=$2; shift 2 ;;
        -b|--fail2ban) fail2ban=$2; shift 2 ;;
        -q|--quota) quota=$2; shift 2 ;;
        -L|--resourcelimit) resourcelimit=$2; shift 2 ;;
        -W|--webterminal) webterminal=$2; shift 2 ;;
        -d|--api) api=$2; shift 2 ;;
        -r|--port) port=$2; shift 2 ;;
        -l|--lang) lang=$2; shift 2 ;;
        -y|--interactive) interactive=$2; shift 2 ;;
        -s|--hostname) hostname=$2; shift 2 ;;
        -e|--email) email=$2; shift 2 ;;
        -u|--username) user=$2; shift 2 ;;
        -p|--password) password=$2; shift 2 ;;
        -f|--force) force='yes'; shift ;;
        -h|--help) help ;;
        *) echo "Invalid argument: $1"; help ;;
        esac
done

if [ -z "$email" ]; then
        echo "Error: an admin email must be provided via --email"
        exit 1
fi

if [ -z "$password" ]; then
        password=$(gen_pass "A-Za-z0-9" 18)
        log INFO "Generated admin password: $password"
fi

#----------------------------------------------------------#
#                       Pre-flight                         #
#----------------------------------------------------------#
if [ "x$(id -u)" != 'x0' ]; then
        echo 'Error: this script can only be executed by root'
        exit 1
fi

mkdir -p "$(dirname "$LOG")" "$hst_backups"
touch "$LOG"

log INFO "Starting Hestia installation for NAIS.OS"
log INFO "Detected release: $release ($architecture)"

system_compat_checks
ensure_dnf
selinux_set_permissive
setup_repos
install_dependencies
install_software
initialize_databases
configure_services
prepare_hestia_layout

log INFO "Installation prerequisites completed"
log INFO "Please continue with Hestia post-installation configuration as documented for RHEL-compatible systems."
