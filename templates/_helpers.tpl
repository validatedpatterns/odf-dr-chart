{{/* Primary cluster name for use in MirrorPeer, jobs, etc. */}}
{{- define "rdr.primaryClusterName" -}}
{{- $dr := index .Values.regionalDR 0 -}}
{{- $override := index (index (.Values.clusterOverrides | default dict) "primary" | default dict) "name" -}}
{{- $fallback := index (index ($dr.clusters | default dict) "primary" | default dict) "name" -}}
{{- $override | default $fallback -}}
{{- end -}}

{{/* Secondary cluster name */}}
{{- define "rdr.secondaryClusterName" -}}
{{- $dr := index .Values.regionalDR 0 -}}
{{- $override := index (index (.Values.clusterOverrides | default dict) "secondary" | default dict) "name" -}}
{{- $fallback := index (index ($dr.clusters | default dict) "secondary" | default dict) "name" -}}
{{- $override | default $fallback -}}
{{- end -}}

{{/* regionalDR[0].name (ClusterSet) */}}
{{- define "rdr.regionalDRClusterSetName" -}}
{{- $dr := index .Values.regionalDR 0 -}}
{{- $dr.name -}}
{{- end -}}

{{/* ODF post-install fixes: MirrorPeer + prerequisites. Default on if omitted. */}}
{{- define "rdr.odfPostInstallFixesEnabled" -}}
{{- $odf := .Values.odf | default dict -}}
{{- if not (hasKey $odf "postInstallFixesEnabled") -}}1{{- else if index $odf "postInstallFixesEnabled" -}}1{{- else -}}0{{- end -}}
{{- end -}}

{{/* Namespace for ODF post-install Jobs. */}}
{{- define "rdr.clusterCaMgtNamespace" -}}
{{- .Values.clusterCaMgt.namespace | default "cluster-ca-mgt" -}}
{{- end -}}

{{/* Stable checksum of packaged ansible/ (excludes dotfiles). */}}
{{- define "rdr.ansibleConfigChecksum" -}}
{{- $paths := list -}}
{{- range $path, $_ := .Files.Glob "ansible/**" -}}
{{- if not (hasPrefix "ansible/." $path) -}}
{{- $paths = append $paths $path -}}
{{- end -}}
{{- end -}}
{{- $buf := "" -}}
{{- range $path := $paths | sortAlpha -}}
{{- $buf = printf "%s\n%s\n%s" $buf $path ($.Files.Get $path) -}}
{{- end -}}
{{- $buf | sha256sum -}}
{{- end -}}

{{- define "rdr.ansibleConfigMapArgoSyncOptions" -}}
{{- .Values.ansible.configMapArgoSyncOptions | default "Prune=false,ServerSideApply=true" -}}
{{- end -}}

{{- define "rdr.ansibleJobPodAnnotations" -}}
checksum/odf-dr-ansible: {{ include "rdr.ansibleConfigChecksum" . | quote }}
{{- end -}}
