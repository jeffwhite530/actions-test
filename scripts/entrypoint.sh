#!/bin/bash


# Error handling
set -euo pipefail
trap 'log "Error on line $LINENO"' ERR


# Logging setup
log() {
  echo "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ") $*"
}


get_cpu_quota() {
  local cpu_quota
  local cpu_period

  # Try to read CPU quota and period from cgroups v2 first
  if [ -f /sys/fs/cgroup/cpu.max ]; then
    read cpu_quota cpu_period < /sys/fs/cgroup/cpu.max
  # Fall back to cgroups v1
  elif [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -f /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    cpu_quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    cpu_period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
  else
    echo "Unable to determine CPU quota" >&2
    return 1
  fi

  # If quota is -1 (unlimited), use the host's CPU count
  if [ "$cpu_quota" = "-1" ] || [ "$cpu_quota" = "max" ]; then
    nproc
    return
  fi

  # Calculate number of CPUs from quota
  echo $((cpu_quota / cpu_period))
}


launch_munged() {
  log "Preparing for munge daemon"

  chmod 0700 /etc/munge

  # Create base munge directory
  mkdir -p /app/slurm/munge
  chmod 0755 /app/slurm/munge

  # Create key directory (equivalent to ${sysconfdir}/munge)
  mkdir -p /app/slurm/munge/etc
  chmod 0700 /app/slurm/munge/etc

  # Create lib directory (equivalent to ${localstatedir}/lib/munge)
  # Using 0711 to support file-descriptor-passing authentication
  mkdir -p /app/slurm/munge/lib
  chmod 0711 /app/slurm/munge/lib

  # Create log directory (equivalent to ${localstatedir}/log/munge)
  mkdir -p /app/slurm/munge/log
  chmod 0700 /app/slurm/munge/log

  # Create run directory (equivalent to ${runstatedir}/munge)
  # Must allow execute permissions for all
  mkdir -p /app/slurm/munge/run
  chmod 0755 /app/slurm/munge/run

  # Configure environment for munged
  export MUNGED_SEEDDIR=/app/slurm/munge/lib
  
  local pid_file=/app/slurm/munge/run/munged.pid
  local socket=/app/slurm/munge/run/munge.socket.2
  local log_file=/app/slurm/munge/log/munged.log

  log "Checking for munge key"
  if [[ -f /etc/munge/munge.key ]]; then
    log "Munge key already exists at /etc/munge/munge.key"
  else
    log "Creating munge key at /etc/munge/munge.key"
    /usr/sbin/mungekey --verbose --create --keyfile=/etc/munge/munge.key
  fi

  chmod 600 /etc/munge/munge.key

  log "Starting munge daemon"
  exec /usr/sbin/munged \
    --key-file=/etc/munge/munge.key \
    --seed-file="${MUNGED_SEEDDIR}/seed" \
    --pid-file="${pid_file}" \
    --socket="${socket}" \
    --log-file="${log_file}" &

  # Wait for the socket to be created
  until [ -S "${socket}" ]; do
    sleep 1
  done
}


launch_slurmdbd() {
  log "Preparing for slurmdbd daemon"

  chmod 600 /etc/slurm/slurmdbd.conf

  # Create required directories
  mkdir -p /app/slurm/{run,log}
  
  touch /app/slurm/log/slurmdbd.log

  # Extract StorageHost from slurmdbd.conf
  storagehost_addr=$(grep -oP '^StorageHost=\K.*' /etc/slurm/slurmdbd.conf)

  if [ -z "${storagehost_addr}" ]; then
    log "Error: Could not find StorageHost in /etc/slurm/slurmdbd.conf"
    exit 1
  fi

  log "Waiting for mariadb to become available at ${storagehost_addr}"
  until nc -z "${storagehost_addr}" 3306; do
    log "Attempting to connect to ${storagehost_addr}:3306..."
    sleep 5
  done
  log "mariadb is up at ${storagehost_addr} - proceeding with startup"

  log "Starting slurmdbd daemon"
  exec /usr/sbin/slurmdbd -D -v
}


launch_slurmctld() {
  log "Preparing for slurmctld daemon"

  # Create required directories
  mkdir -p /app/slurm/{run,log,spool/slurmctld}

  touch /app/slurm/log/slurmctld.log

  # Extract AccountingStorageHost from slurm.conf
  slurmdbd_addr=$(grep -oP '^AccountingStorageHost=\K.*' /etc/slurm/slurm.conf)

  if [ -z "${slurmdbd_addr}" ]; then
    log "Error: Could not find AccountingStorageHost in /etc/slurm/slurm.conf"
    exit 1
  fi

  log "Waiting for slurmdbd to become available at ${slurmdbd_addr}"
  until nc -z "${slurmdbd_addr}" 6819; do
    log "Attempting to connect to ${slurmdbd_addr}:6819..."
    sleep 5
  done
  log "slurmdbd is up at ${slurmdbd_addr} - proceeding with startup"

  log "Starting slurmctld daemon"
  exec /usr/sbin/slurmctld -D -v
}


launch_slurmd() {
  log "Preparing for slurmd daemon"

  # Create required directories
  mkdir -p /app/slurm/{run,log,spool/slurmd}

  touch /app/slurm/log/slurmd.log

  # Extract SlurmctldHost from slurm.conf
  slurmctld_addr=$(grep -oP '^SlurmctldHost=\K.*' /etc/slurm/slurm.conf)

  if [ -z "${slurmctld_addr}" ]; then
    log "Error: Could not find SlurmctldHost in /etc/slurm/slurm.conf"
    exit 1
  fi

  log "Waiting for slurmctld to become available at ${slurmctld_addr}"
  until nc -z "${slurmctld_addr}" 6817; do
    log "Attempting to connect to ${slurmctld_addr}:6817..."
    sleep 5
  done
  log "slurmctld is up at ${slurmctld_addr} - proceeding with startup"

  dbus-daemon --system --fork --nopidfile

  cpu_count=$(get_cpu_quota)

  # Get memory limit in MB
  if [ -f /sys/fs/cgroup/memory.max ]; then
    log "Getting memory amount from cgroups v2"
    memory=$(( $(cat /sys/fs/cgroup/memory.max) / 1024 / 1024 ))
  elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    log "Getting memory amount from cgroups v1"
    memory=$(( $(cat /sys/fs/cgroup/memory/memory.limit_in_bytes) / 1024 / 1024 ))
  else
    log "Getting memory amount from system (/proc/meminfo)"
    memory=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
  fi

  cat <<EOF > /etc/slurm/cgroup.conf
IgnoreSystemd=yes
CgroupPlugin=disabled
EOF

  echo "$memory"

  log "Starting slurmd daemon"
  exec /usr/sbin/slurmd -D -Z \
       --conf "CPUs=$cpu_count RealMemory=$memory"
}


launch_slurm-node-watcher() {
  log "Preparing for slurm-node-watcher daemon"

  # Extract SlurmctldHost from slurm.conf
  slurmctld_addr=$(grep -oP '^SlurmctldHost=\K.*' /etc/slurm/slurm.conf)

  if [ -z "${slurmctld_addr}" ]; then
    log "Error: Could not find SlurmctldHost in /etc/slurm/slurm.conf"
    exit 1
  fi

  log "Waiting for slurmctld to become available at ${slurmctld_addr}"
  until nc -z "${slurmctld_addr}" 6817; do
    log "Attempting to connect to ${slurmctld_addr}:6817..."
    sleep 5
  done
  log "slurmctld is up at ${slurmctld_addr} - proceeding with startup"

  log "Starting slurm-node-watcher daemon"
  exec /usr/bin/python3 /usr/local/bin/slurm-node-watcher.py
}


# Main script execution
log "Starting entrypoint script"


# Determine which daemon to launch based on the first argument
case "${1:-}" in
  "launch_slurmdbd")
    launch_munged
    launch_slurmdbd
    ;;
  "launch_slurmctld")
    launch_munged
    launch_slurmctld
    ;;
  "launch_slurmd")
    launch_munged
    launch_slurmd
    ;;
  "launch_slurm-node-watcher")
    launch_munged
    launch_slurm-node-watcher
    ;;
  *)
    log "Usage: $0 {launch_slurmdbd|launch_slurmctld|launch_slurmd|launch_slurm-node-watcher}"
    exit 1
    ;;
esac
