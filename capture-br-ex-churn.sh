#!/usr/bin/env bash
set -euo pipefail

# Usage: ./capture-br-ex-churn.sh <node-name> [duration-seconds]
NODE=${1:?Usage: $0 <node-name> [duration-seconds]}
DURATION=${2:-60}
NS=openshift-ovn-kubernetes
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR="br-ex-churn-${NODE}-${STAMP}"

mkdir -p "$OUTDIR"

POD=$(oc -n "$NS" get pod -l app=ovnkube-node \
  --field-selector "spec.nodeName=${NODE}" \
  -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD" ]; then
  echo "No ovnkube-node Pod found on node: $NODE" >&2
  exit 1
fi

oc -n "$NS" get pod "$POD" \
  -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' \
  > "$OUTDIR/container-names.txt"

# Find the container which actually has ovs-ofctl. On most OCP releases
# this will be ovnkube-controller, but this avoids assuming the name.
OVS_CONTAINER=
for candidate in $(tr ' ' '\n' < "$OUTDIR/container-names.txt"); do
  if oc -n "$NS" exec "$POD" -c "$candidate" -- \
    ovs-ofctl --version >/dev/null 2>&1; then
    OVS_CONTAINER=$candidate
    break
  fi
done

if [ -z "$OVS_CONTAINER" ]; then
  echo "No container with ovs-ofctl was found in $POD." >&2
  echo "See $OUTDIR/container-names.txt and use the OVN/OVS container manually." >&2
  exit 1
fi

# Select the newest OpenFlow version accepted by this br-ex bridge.
# This is a read-only 'show' request. OpenFlow 1.5.1 is selected as OpenFlow15.
OF_VERSION=
: > "$OUTDIR/openflow-version-probe-errors.txt"
for candidate in OpenFlow15 OpenFlow14 OpenFlow13; do
  if oc -n "$NS" exec "$POD" -c "$OVS_CONTAINER" -- \
    ovs-ofctl -O "$candidate" show br-ex \
    > "$OUTDIR/br-ex-ports.txt" 2>> "$OUTDIR/openflow-version-probe-errors.txt"; then
    OF_VERSION=$candidate
    break
  fi
done

if [ -z "$OF_VERSION" ]; then
  echo "br-ex did not accept OpenFlow15, OpenFlow14, or OpenFlow13." >&2
  echo "See $OUTDIR/openflow-version-probe-errors.txt" >&2
  exit 1
fi

# The next two commands make one full before snapshot of each bridge. They can
# be large on a busy node. Do not increase their frequency or run them in a loop.
FLOW_BEFORE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
oc -n "$NS" exec "$POD" -c "$OVS_CONTAINER" -- \
  ovs-ofctl -O "$OF_VERSION" dump-flows br-int \
  > "$OUTDIR/br-int-flows-before.txt"
oc -n "$NS" exec "$POD" -c "$OVS_CONTAINER" -- \
  ovs-ofctl -O "$OF_VERSION" dump-flows br-ex \
  > "$OUTDIR/br-ex-flows-before.txt"

# vconn debug can create a very large log. Capture only the bytes appended to
# the host ovs-vswitchd file during this short window, not the complete file.
VSWITCHD_LOG=/var/log/openvswitch/ovs-vswitchd.log
host_vswitchd_log_stat() {
  oc debug -q "node/$NODE" -- chroot /host \
    stat -c '%i %s' "$VSWITCHD_LOG"
}

VSWITCHD_LOG_BEFORE=$(host_vswitchd_log_stat)
VSWITCHD_LOG_INODE_BEFORE=${VSWITCHD_LOG_BEFORE%% *}
VSWITCHD_LOG_BYTES_BEFORE=${VSWITCHD_LOG_BEFORE##* }
case "$VSWITCHD_LOG_INODE_BEFORE:$VSWITCHD_LOG_BYTES_BEFORE" in
  *[!0-9:]*|:) echo "Could not read inode and byte size of $VSWITCHD_LOG" >&2; exit 1 ;;
esac

# Preserve the current vconn file level, enable only this module at debug,
# and restore the original level immediately after the monitor stops.
VCONN_FILE_LEVEL=$(oc -n "$NS" exec "$POD" -c "$OVS_CONTAINER" -- \
  ovs-appctl -t ovs-vswitchd vlog/list | \
  awk '$1 == "vconn" {print tolower($4); exit}')
if [ -z "$VCONN_FILE_LEVEL" ]; then
  echo "Could not read the current vconn file log level." >&2
  exit 1
fi

VCONN_CHANGED=0
restore_vconn() {
  if [ "$VCONN_CHANGED" -eq 1 ]; then
    if oc -n "$NS" exec "$POD" -c "$OVS_CONTAINER" -- \
      ovs-appctl -t ovs-vswitchd vlog/set "vconn:file:$VCONN_FILE_LEVEL"; then
      VCONN_CHANGED=0
    else
      echo "WARNING: could not restore vconn file log level to $VCONN_FILE_LEVEL" >&2
      return 1
    fi
  fi
}
trap restore_vconn EXIT

CAPTURE_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
oc -n "$NS" exec "$POD" -c "$OVS_CONTAINER" -- \
  ovs-appctl -t ovs-vswitchd vlog/set vconn:file:dbg
VCONN_CHANGED=1

{
  echo "flow_before_utc=$FLOW_BEFORE_UTC"
  echo "capture_start_utc=$CAPTURE_START"
  echo "node=$NODE"
  echo "pod=$POD"
  echo "ovs_command_container=$OVS_CONTAINER"
  echo "openflow_version=$OF_VERSION"
  echo "ovs_vswitchd_log=$VSWITCHD_LOG"
  echo "ovs_vswitchd_log_inode_before=$VSWITCHD_LOG_INODE_BEFORE"
  echo "ovs_vswitchd_log_bytes_before=$VSWITCHD_LOG_BYTES_BEFORE"
  echo "vconn_file_level_before=$VCONN_FILE_LEVEL"
  echo "vconn_file_level_during=dbg"
  echo "duration_seconds=$DURATION"
} > "$OUTDIR/capture-info.txt"

# Small, read-only bridge context. No OpenFlow rules are changed.
oc -n "$NS" exec "$POD" -c "$OVS_CONTAINER" -- \
  ovs-vsctl list-ports br-ex \
  > "$OUTDIR/br-ex-port-names.txt"

# Main capture: only add/delete/modify events after the command starts.
# A timeout status of 124 or 130 is expected at the requested duration.
set +e
timeout -s INT "$DURATION" oc -n "$NS" exec "$POD" -c "$OVS_CONTAINER" -- \
  ovs-ofctl -O "$OF_VERSION" -m monitor br-ex 'watch:!initial' \
  > "$OUTDIR/br-ex-flow-monitor.txt" 2>&1
MONITOR_RC=$?
set -e

case "$MONITOR_RC" in
  0|124|130) ;;
  *)
    echo "Flow monitor failed with exit code $MONITOR_RC; see $OUTDIR/br-ex-flow-monitor.txt" >&2
    exit "$MONITOR_RC"
    ;;
esac

CAPTURE_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! restore_vconn; then
  # The EXIT trap makes one further restore attempt before leaving.
  exit 1
fi
trap - EXIT
VCONN_FILE_LEVEL_AFTER=$(oc -n "$NS" exec "$POD" -c "$OVS_CONTAINER" -- \
  ovs-appctl -t ovs-vswitchd vlog/list | \
  awk '$1 == "vconn" {print tolower($4); exit}')

# One full after snapshot of each bridge. Compare the before/after files
# offline; do not run repeated dumps while the issue is active.
FLOW_AFTER_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
oc -n "$NS" exec "$POD" -c "$OVS_CONTAINER" -- \
  ovs-ofctl -O "$OF_VERSION" dump-flows br-int \
  > "$OUTDIR/br-int-flows-after.txt"
oc -n "$NS" exec "$POD" -c "$OVS_CONTAINER" -- \
  ovs-ofctl -O "$OF_VERSION" dump-flows br-ex \
  > "$OUTDIR/br-ex-flows-after.txt"

# Collect the two relevant pod logs before creating the temporary debug pod.
# This prevents debug-pod namespace messages appearing in the controller log.
LOG_CONTAINERS="$OVS_CONTAINER"
if grep -Fxq 'ovnkube-controller' "$OUTDIR/container-names.txt" && \
  [ "$OVS_CONTAINER" != 'ovnkube-controller' ]; then
  LOG_CONTAINERS="$LOG_CONTAINERS ovnkube-controller"
fi

for LOG_CONTAINER in $LOG_CONTAINERS; do
  oc -n "$NS" logs "$POD" -c "$LOG_CONTAINER" \
    --since-time="$CAPTURE_START" --timestamps \
    > "$OUTDIR/${LOG_CONTAINER}-since-capture-start.log" 2>&1 || true
done

# Read only the bytes appended while vconn:file:dbg was enabled. -q avoids
# oc debug progress messages being included in the extracted OVS log.
VSWITCHD_LOG_AFTER=$(host_vswitchd_log_stat)
VSWITCHD_LOG_INODE_AFTER=${VSWITCHD_LOG_AFTER%% *}
VSWITCHD_LOG_BYTES_AFTER=${VSWITCHD_LOG_AFTER##* }
VSWITCHD_LOG_BYTES_CAPTURED=0
VSWITCHD_LOG_EXTRACT_RC=0

if [ "$VSWITCHD_LOG_INODE_BEFORE" = "$VSWITCHD_LOG_INODE_AFTER" ] && \
  [ "$VSWITCHD_LOG_BYTES_AFTER" -ge "$VSWITCHD_LOG_BYTES_BEFORE" ]; then
  VSWITCHD_LOG_BYTES_CAPTURED=$((VSWITCHD_LOG_BYTES_AFTER - VSWITCHD_LOG_BYTES_BEFORE))
  set +e
  oc debug -q "node/$NODE" -- chroot /host \
    dd if="$VSWITCHD_LOG" iflag=skip_bytes,count_bytes \
    skip="$VSWITCHD_LOG_BYTES_BEFORE" count="$VSWITCHD_LOG_BYTES_CAPTURED" status=none \
    > "$OUTDIR/ovs-vswitchd-vconn-window.log"
  VSWITCHD_LOG_EXTRACT_RC=$?
  set -e
else
  VSWITCHD_LOG_EXTRACT_RC=1
  {
    echo "The ovs-vswitchd log inode or size changed during the capture."
    echo "before: $VSWITCHD_LOG_BEFORE"
    echo "after:  $VSWITCHD_LOG_AFTER"
    echo "Do not copy the complete log blindly; collect the current and rotated log files from sosreport."
  } > "$OUTDIR/ovs-vswitchd-vconn-window.log"
fi

{
  echo "capture_end_utc=$CAPTURE_END"
  echo "flow_after_utc=$FLOW_AFTER_UTC"
  echo "vconn_file_level_after=$VCONN_FILE_LEVEL_AFTER"
  echo "ovs_vswitchd_log_inode_after=$VSWITCHD_LOG_INODE_AFTER"
  echo "ovs_vswitchd_log_bytes_after=$VSWITCHD_LOG_BYTES_AFTER"
  echo "ovs_vswitchd_log_bytes_captured=$VSWITCHD_LOG_BYTES_CAPTURED"
  echo "ovs_vswitchd_log_extract_exit_code=$VSWITCHD_LOG_EXTRACT_RC"
  echo "monitor_exit_code=$MONITOR_RC"
} >> "$OUTDIR/capture-info.txt"

tar -czf "${OUTDIR}.tgz" "$OUTDIR"
echo "Created ${OUTDIR}.tgz"
echo "Attach ${OUTDIR}/br-ex-flow-monitor.txt first."
