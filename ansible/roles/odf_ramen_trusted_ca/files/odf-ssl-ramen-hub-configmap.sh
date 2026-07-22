#!/usr/bin/env bash
# Update ramen-hub-operator-config with caCertificates in s3StoreProfiles (same logic path as
# odf-ssl-certificate-extraction.sh §7b). Invoked by the Ansible extraction playbook so behavior
# matches the proven shell implementation.
set -euo pipefail

WORK_DIR="${WORK_DIR:-/tmp/odf-ssl-certs}"
PRIMARY_CLUSTER="${PRIMARY_CLUSTER:?PRIMARY_CLUSTER is required}"
SECONDARY_CLUSTER="${SECONDARY_CLUSTER:?SECONDARY_CLUSTER is required}"

die() {
	echo "❌ odf-ssl-ramen-hub-configmap.sh: $*" >&2
	exit 1
}

trap 'echo "❌ odf-ssl-ramen-hub-configmap.sh: command failed (exit $?) at line $LINENO — see stderr above for the failing command." >&2' ERR

mkdir -p "$WORK_DIR"
[[ -f "$WORK_DIR/combined-ca-bundle.crt" ]] || die "missing $WORK_DIR/combined-ca-bundle.crt"

echo "7b. Updating ramen-hub-operator-config in openshift-operators namespace (bash parity script)..."

CA_BUNDLE_BASE64=$(base64 -w 0 <"$WORK_DIR/combined-ca-bundle.crt" 2>/dev/null || base64 <"$WORK_DIR/combined-ca-bundle.crt" | tr -d '\n')

# Post-apply: fetch live YAML to disk (no huge shell vars) and validate structure.
verify_post_apply() {
	local f="$WORK_DIR/.ramen-post-apply-verify.yaml" attempt
	local MIN_REQUIRED_PROFILES=2
	local PK PT CK CT bad maxp
	local last_PK=0 last_PT=0 last_CK=0 last_CT=0 last_maxp=0 last_bad=1 oc_ok=0
	for attempt in $(seq 1 10); do
		if [[ "$attempt" -gt 1 ]]; then
			sleep 6
		else
			sleep 2
		fi
		if oc get configmap ramen-hub-operator-config -n openshift-operators \
			-o jsonpath='{.data.ramen_manager_config\.yaml}' >"$f" 2>/dev/null; then
			oc_ok=1
		else
			oc_ok=0
			continue
		fi
		[[ -s "$f" ]] || continue
		grep -q 'caCertificates' "$f" || continue
		grep -q 's3StoreProfiles' "$f" || continue
		PK=$(yq eval '(.kubeObjectProtection.s3StoreProfiles // []) | length' "$f" 2>/dev/null | tr -d ' \n\r' | head -1 || echo 0)
		PT=$(yq eval '(.s3StoreProfiles // []) | length' "$f" 2>/dev/null | tr -d ' \n\r' | head -1 || echo 0)
		CK=$(yq eval '[(.kubeObjectProtection.s3StoreProfiles // [])[]? | select(has("caCertificates"))] | length' "$f" 2>/dev/null | tr -d ' \n\r' | head -1 || echo 0)
		CT=$(yq eval '[(.s3StoreProfiles // [])[]? | select(has("caCertificates"))] | length' "$f" 2>/dev/null | tr -d ' \n\r' | head -1 || echo 0)
		[[ "$PK" =~ ^[0-9]+$ ]] || PK=0
		[[ "$PT" =~ ^[0-9]+$ ]] || PT=0
		[[ "$CK" =~ ^[0-9]+$ ]] || CK=0
		[[ "$CT" =~ ^[0-9]+$ ]] || CT=0
		bad=0
		[[ "$PK" -gt 0 && "$CK" -lt "$PK" ]] && bad=1
		[[ "$PT" -gt 0 && "$CT" -lt "$PT" ]] && bad=1
		maxp=$((PK > PT ? PK : PT))
		last_PK=$PK
		last_PT=$PT
		last_CK=$CK
		last_CT=$CT
		last_maxp=$maxp
		last_bad=$bad
		[[ "$bad" -eq 1 ]] && continue
		[[ "$maxp" -ge "$MIN_REQUIRED_PROFILES" ]] || continue
		[[ "$CK" -ge "$MIN_REQUIRED_PROFILES" || "$CT" -ge "$MIN_REQUIRED_PROFILES" ]] || continue
		echo "  ✅ ramen-hub-operator-config verified (attempt $attempt): kubeObjectProtection s3 profiles $PK/$CK, top-level $PT/$CT"
		return 0
	done
	echo "  ❌ Post-apply verification failed after 10 attempts." >&2
	echo "  ❌ Diagnosis: oc_get_ok=$oc_ok last_kop_profiles=$last_PK last_kop_with_ca=$last_CK last_top_profiles=$last_PT last_top_with_ca=$last_CT last_max_profiles=$last_maxp last_section_bad=$last_bad (need each non-empty section fully CA-populated; max profiles >= $MIN_REQUIRED_PROFILES; at least $MIN_REQUIRED_PROFILES with CA in kop OR top)" >&2
	echo "  ❌ If kop/top counts are 0, the hub operator may have removed ramen_manager_config data or the key is empty." >&2
	[[ -f "$f" ]] && {
		echo "  ❌ First 80 lines of live ramen_manager_config from cluster:" >&2
		head -n 80 "$f" >&2
	} || echo "  ❌ No verify file (oc get may have failed every attempt)." >&2
	return 1
}

UPDATED_YAML=""

if oc get configmap ramen-hub-operator-config -n openshift-operators &>/dev/null; then
	echo "  ConfigMap exists, updating ramen_manager_config.yaml with caCertificates in s3StoreProfiles..."

	EXISTING_YAML=$(oc get configmap ramen-hub-operator-config -n openshift-operators -o jsonpath='{.data.ramen_manager_config\.yaml}' 2>/dev/null || echo "")

	MIN_REQUIRED_PROFILES=2
	if [[ -n "$EXISTING_YAML" ]]; then
		if command -v yq &>/dev/null; then
			COUNT_KOP=$(echo "$EXISTING_YAML" | yq eval '.kubeObjectProtection.s3StoreProfiles | length' 2>/dev/null | tr -d ' \n\r' | head -1 || echo "0")
			COUNT_TOP=$(echo "$EXISTING_YAML" | yq eval '.s3StoreProfiles | length' 2>/dev/null | tr -d ' \n\r' | head -1 || echo "0")
			COUNT_KOP=$((10#${COUNT_KOP:-0}))
			COUNT_TOP=$((10#${COUNT_TOP:-0}))
			EXISTING_PROFILE_COUNT=$((COUNT_KOP >= COUNT_TOP ? COUNT_KOP : COUNT_TOP))
		else
			EXISTING_PROFILE_COUNT=$(echo "$EXISTING_YAML" | grep -c "s3ProfileName:" 2>/dev/null || echo "0")
			if [[ $EXISTING_PROFILE_COUNT -eq 0 ]]; then
				EXISTING_PROFILE_COUNT=$(echo "$EXISTING_YAML" | grep -c "s3Bucket:" 2>/dev/null || echo "0")
			fi
		fi
		EXISTING_PROFILE_COUNT=$(echo "$EXISTING_PROFILE_COUNT" | tr -d ' \n\r' | grep -E '^[0-9]+$' || echo "0")
		EXISTING_PROFILE_COUNT=$((10#$EXISTING_PROFILE_COUNT))
		if [[ $EXISTING_PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
			echo "  ❌ CRITICAL: Insufficient s3StoreProfiles in existing ConfigMap (found $EXISTING_PROFILE_COUNT, need $MIN_REQUIRED_PROFILES)"
			echo "$EXISTING_YAML" | head -n 50
			die "Insufficient s3StoreProfiles — pre-create profiles in ramen-hub-operator-config or use the full extraction job on the hub"
		fi
		echo "  ✅ Found $EXISTING_PROFILE_COUNT s3StoreProfiles (patching caCertificates only)"
	fi

	PATCHED_VIA_YQ=false
	if [[ -n "$EXISTING_YAML" ]]; then
		echo "$EXISTING_YAML" >"$WORK_DIR/existing-ramen-config.yaml"
		command -v python3 &>/dev/null || die "python3 not found — cannot patch ramen_manager_config"
		# Pure-Python patch using only built-in modules (no PyYAML required).
		# Reads combined-ca-bundle.crt directly to avoid E2BIG env-var size limits.
		# Strips any existing caCertificates lines then injects after each s3ProfileName.
		WORK_DIR="$WORK_DIR" python3 - <<'PYEOF' || die "python3 failed to patch existing-ramen-config.yaml"
import os, re, base64

work_dir = os.environ["WORK_DIR"]

with open(os.path.join(work_dir, "combined-ca-bundle.crt"), "rb") as f:
    ca_b64 = base64.b64encode(f.read()).decode("ascii")

path = os.path.join(work_dir, "existing-ramen-config.yaml")
with open(path, "r") as f:
    lines = f.readlines()

# Remove stale caCertificates lines so re-runs are idempotent.
lines = [l for l in lines if not re.match(r'^\s*caCertificates:', l)]

result = []
for line in lines:
    result.append(line)
    if re.match(r'^\s*s3ProfileName:', line):
        indent = len(line) - len(line.lstrip())
        result.append(" " * indent + "caCertificates: " + ca_b64 + "\n")

with open(path, "w") as f:
    f.writelines(result)
PYEOF
		grep -q "caCertificates" "$WORK_DIR/existing-ramen-config.yaml" || die "patched file has no caCertificates"
		cp "$WORK_DIR/existing-ramen-config.yaml" "$WORK_DIR/ramen_manager_config.yaml"
		PATCHED_VIA_YQ=true
	else
		UPDATED_YAML="kubeObjectProtection:
  s3StoreProfiles:
  - s3ProfileName: $PRIMARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"
  - s3ProfileName: $SECONDARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"
s3StoreProfiles:
  - s3ProfileName: $PRIMARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"
  - s3ProfileName: $SECONDARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\""
	fi

	if [[ "$PATCHED_VIA_YQ" != "true" ]]; then
		echo "$UPDATED_YAML" >"$WORK_DIR/ramen_manager_config.yaml"
	fi

	# Use oc patch --type=merge with a JSON patch file.
	# oc apply is avoided: it stores the full manifest in last-applied-configuration,
	# which exceeds the 262144-byte annotation limit when caCertificates is large.
	echo "  Patching ramen-hub-operator-config via oc patch --type=merge..."
	PATCH_JSON="$WORK_DIR/ramen-patch.json"
	WORK_DIR="$WORK_DIR" python3 - <<'PYEOF' || die "python3 failed to build ramen-patch.json"
import json, os, sys
work_dir = os.environ["WORK_DIR"]
with open(os.path.join(work_dir, "ramen_manager_config.yaml"), "r") as f:
    data = f.read()
with open(os.path.join(work_dir, "ramen-patch.json"), "w") as f:
    json.dump({"data": {"ramen_manager_config.yaml": data}}, f)
PYEOF

	UPDATE_EXIT_CODE=1
	UPDATE_OUTPUT=""
	if UPDATE_OUTPUT=$(oc patch configmap/ramen-hub-operator-config \
		-n openshift-operators \
		--type=merge \
		--patch-file="$PATCH_JSON" 2>&1); then
		UPDATE_EXIT_CODE=0
	else
		UPDATE_EXIT_CODE=$?
	fi
	rm -f "$PATCH_JSON"

	echo "  Update exit code: $UPDATE_EXIT_CODE"
	echo "  Update output: $UPDATE_OUTPUT"

	if [[ $UPDATE_EXIT_CODE -eq 0 ]]; then
		verify_post_apply || die "Post-apply verification failed — CA not present in live ConfigMap"
	else
		die "oc apply/set data failed: $UPDATE_OUTPUT"
	fi

	rm -f "$WORK_DIR/existing-ramen-config.yaml" "$WORK_DIR/ramen_manager_config.yaml" || true
else
	echo "  ConfigMap does not exist; creating ramen-hub-operator-config..."
	oc create configmap ramen-hub-operator-config -n openshift-operators \
		--from-literal=ramen_manager_config.yaml="kubeObjectProtection:
  s3StoreProfiles:
  - s3ProfileName: $PRIMARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"
  - s3ProfileName: $SECONDARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"
s3StoreProfiles:
  - s3ProfileName: $PRIMARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"
  - s3ProfileName: $SECONDARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"" || die "oc create configmap failed"

	verify_post_apply || die "Post-create verification failed"
fi

echo "  ramen-hub-operator-config updated successfully with base64-encoded CA bundle in s3StoreProfiles"

# Trigger Ramen to re-reconcile all VRGs so it updates ManifestWork objects on each
# managed cluster with the new caCertificates → BSL.spec.objectStorage.caCert.
echo "Triggering Ramen VRG reconciliation to propagate caCertificates to managed cluster BSLs..."
VRG_TRIGGER_FAILED=0
while IFS= read -r line; do
	NS=$(echo "$line" | awk '{print $1}')
	NAME=$(echo "$line" | awk '{print $2}')
	[[ -z "$NS" || -z "$NAME" ]] && continue
	if oc annotate vrg "$NAME" -n "$NS" \
		ramendr.openshift.io/reconcile-trigger="$(date +%s)" \
		--overwrite 2>/dev/null; then
		echo "  ✅ Annotated VRG $NS/$NAME"
	else
		echo "  ⚠️  Failed to annotate VRG $NS/$NAME" >&2
		VRG_TRIGGER_FAILED=1
	fi
done < <(oc get vrg -A --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' 2>/dev/null || true)

if [[ $VRG_TRIGGER_FAILED -eq 0 ]]; then
	echo "  ✅ VRG reconciliation triggered — Ramen will update spoke BSLs with caCertificates"
else
	echo "  ⚠️  Some VRG annotations failed; BSLs may need manual reconciliation" >&2
fi
