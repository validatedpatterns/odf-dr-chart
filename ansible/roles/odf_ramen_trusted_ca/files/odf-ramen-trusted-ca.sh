#!/usr/bin/env bash
# After MirrorPeer (and vp-manage-proxy-cluster-ca populates vp-pattern-proxy-ca-bundle), copy CA from
# the hub vp-pattern-proxy-ca-bundle ConfigMap — do not re-extract from router/spoke API servers.
# Wait until Ramen hub config has s3StoreProfiles (from ODF/MirrorPeer), then patch caCertificates only.
set -euo pipefail

PRIMARY_CLUSTER="${PRIMARY_CLUSTER:?PRIMARY_CLUSTER is required}"
SECONDARY_CLUSTER="${SECONDARY_CLUSTER:?SECONDARY_CLUSTER is required}"
WORK_DIR="${WORK_DIR:-/tmp/odf-ssl-certs}"
RAMEN_CM_WAIT_SECONDS="${RAMEN_CM_WAIT_SECONDS:-3600}"
TRUSTED_CA_WAIT_SECONDS="${TRUSTED_CA_WAIT_SECONDS:-3600}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAMEN_SCRIPT="${SCRIPT_DIR}/odf-ssl-ramen-hub-configmap.sh"

LOG_FILE="${WORK_DIR:-/tmp/odf-ssl-certs}/ramen-trusted-ca.log"
mkdir -p "${WORK_DIR:-/tmp/odf-ssl-certs}"
# Tee all output to a log file readable via oc exec while Ansible buffers stdout.
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date -u +%T)] odf-ramen-trusted-ca.sh started"

die() {
	echo "❌ odf-ramen-trusted-ca.sh: $*" >&2
	exit 1
}

command -v oc >/dev/null 2>&1 || die "oc not found"
[[ -x "$RAMEN_SCRIPT" ]] || [[ -f "$RAMEN_SCRIPT" ]] || die "missing $RAMEN_SCRIPT"
chmod +x "$RAMEN_SCRIPT" 2>/dev/null || true

mkdir -p "$WORK_DIR"

wait_for_trusted_ca() {
	local deadline=$((SECONDS + TRUSTED_CA_WAIT_SECONDS))
	# Use the differential bundle: cluster-specific CAs only (API + ingress, no system trust store).
	# This is the correct material for Ramen s3StoreProfiles caCertificates — concise and focused
	# on the CAs needed to verify NooBaa S3 external route TLS certificates.
	echo "Waiting for vp-pattern-proxy-ca-bundle-differential (openshift-config) with non-trivial cabundle (max ${TRUSTED_CA_WAIT_SECONDS}s)..."
	while ((SECONDS < deadline)); do
		local data bytes
		data=$(oc get configmap vp-pattern-proxy-ca-bundle-differential -n openshift-config -o jsonpath='{.data.cabundle}' 2>/dev/null || true)
		bytes=$(printf '%s' "$data" | wc -c | tr -d ' ')
		if [[ "${bytes:-0}" -ge 64 ]]; then
			printf '%s' "$data" >"$WORK_DIR/combined-ca-bundle.crt"
			echo "  ✅ differential CA bundle captured (${bytes} bytes)"
			return 0
		fi
		echo "  ... cabundle bytes=${bytes:-0}, retry in ${POLL_INTERVAL}s"
		sleep "$POLL_INTERVAL"
	done
	die "vp-pattern-proxy-ca-bundle-differential not ready in time — ensure vp-manage-proxy-cluster-ca chart differentialBundle is enabled and synced"
}

count_s3_profiles() {
	local yaml="$1"
	[[ -n "$yaml" ]] || {
		echo 0
		return
	}
	if command -v yq &>/dev/null; then
		local k t
		k=$(echo "$yaml" | yq eval '.kubeObjectProtection.s3StoreProfiles | length' 2>/dev/null | tr -d ' \n\r' || echo 0)
		t=$(echo "$yaml" | yq eval '.s3StoreProfiles | length' 2>/dev/null | tr -d ' \n\r' || echo 0)
		k=$((10#${k:-0}))
		t=$((10#${t:-0}))
		echo $((k > t ? k : t))
	else
		echo "$yaml" | grep -c 's3ProfileName:' 2>/dev/null || echo 0
	fi
}

wait_for_ramen_s3_profiles() {
	local deadline=$((SECONDS + RAMEN_CM_WAIT_SECONDS)) yaml c
	echo "Waiting for ramen-hub-operator-config s3StoreProfiles (openshift-operators, max ${RAMEN_CM_WAIT_SECONDS}s)..."
	while ((SECONDS < deadline)); do
		yaml=$(oc get configmap ramen-hub-operator-config -n openshift-operators -o jsonpath='{.data.ramen_manager_config\.yaml}' 2>/dev/null || true)
		# Strip carriage returns — configmap YAML may have CRLF line endings.
		yaml=$(printf '%s' "$yaml" | tr -d '\r')
		c=$(count_s3_profiles "$yaml")
		echo "  [$(date -u +%T)] yaml_empty=$([ -z "$yaml" ] && echo YES || echo NO) count=${c}"
		if [[ -n "$yaml" && "${c:-0}" -ge 2 ]]; then
			echo "  ✅ ramen_manager_config has s3StoreProfiles (count≈$c)"
			return 0
		fi
		echo "  ... profiles not ready yet (need >=2, got ${c:-0}), retry in ${POLL_INTERVAL}s"
		sleep "$POLL_INTERVAL"
	done
	die "ramen-hub-operator-config never gained s3StoreProfiles — confirm MirrorPeer and hub Ramen operator reconciled"
}

wait_for_trusted_ca
wait_for_ramen_s3_profiles

export WORK_DIR PRIMARY_CLUSTER SECONDARY_CLUSTER
exec bash "$RAMEN_SCRIPT"
