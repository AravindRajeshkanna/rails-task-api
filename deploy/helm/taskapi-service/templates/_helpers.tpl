{{- define "taskapi.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "taskapi.fullname" -}}
{{- if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}{{ .Release.Name | trunc 63 | trimSuffix "-" }}{{- end }}
{{- end }}

{{- define "taskapi.labels" -}}
app.kubernetes.io/name: {{ include "taskapi.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: task-api
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- if .Values.image.tag }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
{{- end }}
{{- end }}

{{- define "taskapi.selectorLabels" -}}
app.kubernetes.io/name: {{ include "taskapi.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "taskapi.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}{{ default (include "taskapi.fullname" .) .Values.serviceAccount.name }}
{{- else }}{{ default "default" .Values.serviceAccount.name }}{{- end }}
{{- end }}

{{- define "taskapi.image" -}}
{{- required "image.repository is required" .Values.image.repository }}:{{ required "image.tag is required (CI sets it to the git SHA)" .Values.image.tag }}
{{- end }}

{{/* Everything a pod template shares between a Deployment and a Rollout. */}}
{{- define "taskapi.podSpec" -}}
serviceAccountName: {{ include "taskapi.serviceAccountName" . }}
terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
securityContext: {{- toYaml .Values.podSecurityContext | nindent 2 }}
{{- with .Values.nodeSelector }}
nodeSelector: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity: {{- toYaml . | nindent 2 }}
{{- end }}
{{- if .Values.topologySpread }}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels: {{- include "taskapi.selectorLabels" . | nindent 8 }}
{{- end }}
containers:
  - name: app
    image: {{ include "taskapi.image" . }}
    imagePullPolicy: {{ .Values.image.pullPolicy }}
    {{- with .Values.command }}
    command: {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.args }}
    args: {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if gt (int .Values.port) 0 }}
    ports:
      - { name: http, containerPort: {{ .Values.port }} }
    {{- end }}
    env:
      {{- if gt (int .Values.port) 0 }}
      - { name: PORT, value: {{ .Values.port | quote }} }
      {{- end }}
      - { name: APP_VERSION, value: {{ .Values.image.tag | quote }} }
      - name: POD_NAME
        valueFrom: { fieldRef: { fieldPath: metadata.name } }
      {{- range $key, $value := .Values.env }}
      - { name: {{ $key }}, value: {{ $value | quote }} }
      {{- end }}
    envFrom:
      {{- if .Values.secrets.enabled }}
      - secretRef: { name: {{ include "taskapi.fullname" . }} }
      {{- end }}
      {{- with .Values.envFrom }}{{ toYaml . | nindent 6 }}{{- end }}
    {{- if eq .Values.probes.mode "http" }}
    startupProbe:
      httpGet: { path: {{ .Values.probes.path }}, port: http }
      {{- toYaml .Values.probes.startup | nindent 6 }}
    readinessProbe:
      httpGet: { path: {{ .Values.probes.path }}, port: http }
      {{- toYaml .Values.probes.readiness | nindent 6 }}
    livenessProbe:
      httpGet: { path: {{ default .Values.probes.path .Values.probes.livenessPath }}, port: http }
      {{- toYaml .Values.probes.liveness | nindent 6 }}
    {{- else }}
    {{- with .Values.probes.readinessCommand }}
    readinessProbe:
      exec: { command: {{ toJson . }} }
      {{- toYaml $.Values.probes.readiness | nindent 6 }}
    {{- end }}
    {{- with .Values.probes.livenessCommand }}
    livenessProbe:
      exec: { command: {{ toJson . }} }
      {{- toYaml $.Values.probes.liveness | nindent 6 }}
    {{- end }}
    {{- end }}
    {{- if gt (int .Values.preStopSleepSeconds) 0 }}
    lifecycle:
      preStop:
        exec: { command: [ sleep, {{ .Values.preStopSleepSeconds | quote }} ] }
    {{- end }}
    resources: {{- toYaml .Values.resources | nindent 6 }}
    securityContext: {{- toYaml .Values.containerSecurityContext | nindent 6 }}
    volumeMounts:
      {{- range $index, $path := .Values.writablePaths }}
      - { name: scratch, mountPath: {{ $path }}, subPath: {{ $path | trimPrefix "/" | replace "/" "-" }} }
      {{- end }}
volumes:
  - name: scratch
    emptyDir: {}
{{- end }}

{{/* [5432, 3000] -> a YAML list of NetworkPolicy ports. */}}
{{- define "taskapi.ports" -}}
{{- $out := list -}}
{{- range . }}{{ $out = append $out (dict "port" .) }}{{- end -}}
{{ toYaml $out }}
{{- end }}
