{{/* Primary cluster name for use in jobs, MirrorPeer, DRPC, etc. */}}
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

{{/* regionalDR[0].name (ClusterSet); Submariner broker namespace = name + "-broker" */}}
{{- define "rdr.regionalDRClusterSetName" -}}
{{- $dr := index .Values.regionalDR 0 -}}
{{- $dr.name -}}
{{- end -}}

{{- define "rdr.submarinerBrokerNamespace" -}}
{{ include "rdr.regionalDRClusterSetName" . }}-broker
{{- end -}}

{{/* global.clusterPlatform (e.g. AWS, BareMetal): AWS gates AWS-only chart pieces. Case-insensitive; default AWS. */}}
{{- define "rdr.clusterPlatformAws" -}}
{{- $g := .Values.global | default dict -}}
{{- if eq "aws" (lower ($g.clusterPlatform | default "AWS" | toString)) -}}1{{- else -}}0{{- end -}}
{{- end -}}

{{/* Submariner EC2 SG tagger job + RBAC: AWS platform and submariner.sgTagJobEnabled true. */}}
{{- define "rdr.submarinerSgTagJobEnabled" -}}
{{- $sm := .Values.submariner | default dict -}}
{{- $aws := eq "1" (include "rdr.clusterPlatformAws" . | trim) -}}
{{- $want := and (hasKey $sm "sgTagJobEnabled") (index $sm "sgTagJobEnabled") -}}
{{- if and $aws $want -}}1{{- else -}}0{{- end -}}
{{- end -}}

{{/* ODF post-install fixes: prerequisites checker + Ramen trusted CA jobs/RBAC. Default on if .Values.odf.postInstallFixesEnabled omitted. */}}
{{- define "rdr.odfPostInstallFixesEnabled" -}}
{{- $odf := .Values.odf | default dict -}}
{{- if not (hasKey $odf "postInstallFixesEnabled") -}}1{{- else if index $odf "postInstallFixesEnabled" -}}1{{- else -}}0{{- end -}}
{{- end -}}

{{/* Ramen hub trusted-CA job: patch s3StoreProfiles from cluster-proxy-ca-bundle. Default on when enabled omitted. */}}
{{- define "rdr.odfRamenTrustedCaEnabled" -}}
{{- if ne "1" (include "rdr.odfPostInstallFixesEnabled" . | trim) -}}0{{- else -}}
{{- $cfg := .Values.odfRamenTrustedCa | default dict -}}
{{- if not (hasKey $cfg "enabled") -}}1{{- else if index $cfg "enabled" -}}1{{- else -}}0{{- end -}}
{{- end -}}
{{- end -}}

{{/* ODF SSL extraction jobs, ACM CA policies, and spoke distribution. Default on when enabled omitted. */}}
{{- define "rdr.odfSslCertificateExtractorEnabled" -}}
{{- $cfg := .Values.odfSslCertificateExtractor | default dict -}}
{{- if not (hasKey $cfg "enabled") -}}1{{- else if index $cfg "enabled" -}}1{{- else -}}0{{- end -}}
{{- end -}}

{{/* Namespace for ODF CA post-install Jobs. */}}
{{- define "rdr.clusterCaMgtNamespace" -}}
{{- .Values.clusterCaMgt.namespace | default "cluster-ca-mgt" -}}
{{- end -}}

{{/* Stable checksum of packaged ansible/ (excludes dotfiles). Drives CM + Job drift on chart updates. */}}
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

{{/* Argo CD sync-options for the ansible ConfigMap. */}}
{{- define "rdr.ansibleConfigMapArgoSyncOptions" -}}
{{- .Values.ansible.configMapArgoSyncOptions | default "Prune=false,ServerSideApply=true" -}}
{{- end -}}

{{/* Pod template annotation: keep ansible Jobs in sync with odf-dr-ansible content. */}}
{{- define "rdr.ansibleJobPodAnnotations" -}}
checksum/odf-dr-ansible: {{ include "rdr.ansibleConfigChecksum" . | quote }}
{{- end -}}

{{/*
  opp.* aliases — used by the SSL certificate templates which were originally in odf-opp.
  They delegate to the canonical rdr.* helpers so there is a single implementation.
*/}}
{{- define "opp.primaryClusterName" -}}{{ include "rdr.primaryClusterName" . }}{{- end -}}
{{- define "opp.secondaryClusterName" -}}{{ include "rdr.secondaryClusterName" . }}{{- end -}}
{{- define "opp.clusterCaMgtNamespace" -}}{{ include "rdr.clusterCaMgtNamespace" . }}{{- end -}}
{{- define "opp.odfSslCertificateExtractorEnabled" -}}{{ include "rdr.odfSslCertificateExtractorEnabled" . }}{{- end -}}
