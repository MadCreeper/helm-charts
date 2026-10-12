# bodylog-victorialogs

Makes the router's body logs searchable. [bodylog](../bodylog) writes every request
and response as hourly JSONL on one node; this chart runs
[Vector](https://vector.dev) next to it to ship each record into
[VictoriaLogs](https://docs.victoriametrics.com/victorialogs/), and registers
VictoriaLogs as a Grafana datasource so the records can be queried with LogsQL.

```
bodylog pod ──writes──> <dir>/YYYY-MM-DD/HH.jsonl  (hostPath or PVC, one node)
                               │ read-only
                        Vector (same node) ──HTTP jsonline──> VictoriaLogs <── Grafana
```

| component | what | image |
|---|---|---|
| Vector | Deployment, 1 replica, scheduled onto the bodylog pod's node | `timberio/vector` |
| VictoriaLogs | subchart [`victoria-logs-single`](https://github.com/VictoriaMetrics/helm-charts/tree/master/charts/victoria-logs-single), aliased `victorialogs` | `victoriametrics/victoria-logs` |
| Grafana datasource | ConfigMap for Grafana's datasource sidecar | |

## Install

Point the chart at the directory bodylog writes to -- the bodylog chart's
`persistence.hostPath`, or its PVC:

```sh
helm install bodylog-victorialogs modelsphere/bodylog-victorialogs -n logging --create-namespace \
  --set bodylog.hostPath=/data/bodylog \
  --set bodylog.namespace=router
helm test bodylog-victorialogs -n logging
```

- `bodylog.namespace` / `bodylog.podLabels` select the bodylog pod Vector follows
  (default: label `app.kubernetes.io/name: bodylog` in the release namespace). With
  several bodylog releases in one namespace, add `app.kubernetes.io/instance`.
- `bodylog.existingClaim` instead of `hostPath` mounts bodylog's PVC read-only. A
  ReadWriteOnce claim works, because both pods run on the same node.
- To ship into a VictoriaLogs you already run: `victorialogs.enabled=false` and
  `victorialogsUrl=http://...:9428`.

`helm test` checks that VictoriaLogs answers at the URL Vector and Grafana are
configured with, and that its query API works. On a router with steady traffic, set
`test.expectRecordsWithin=1h` to also require that records arrived recently.

## How it works

- **Placement.** A Deployment with a required `podAffinity` on the bodylog pod, not a
  DaemonSet: the DaemonSet controller ignores pod affinity and would leave a Pending
  pod on every other node. If bodylog is not running, Vector stays Pending too.
- **Where reading starts.** `vector.readFrom: end` (default) ships records written
  after Vector first starts. `beginning` also ships the current day's files -- on a
  busy router that is hundreds of GB at once.
- **Restarts.** Read positions are kept in a node directory
  (`vector.checkpointHostPath`, default `/var/lib/<release>`), so a restart resumes
  where it stopped. The update strategy is `Recreate`: two pods on one checkpoint
  directory would ship the same lines twice.
- **Each record** is transformed by [`files/bodylog.vrl`](files/bodylog.vrl)
  (override with `vector.vrl`): all fields are kept; `model`, `prompt_tokens`,
  `completion_tokens` and `total_tokens` are lifted out of the response; `_msg` gets
  a one-line summary
  (`<model>:<peer> --> <upstream> prompt:N cache:N output:N TTFT:Ns status:N`);
  inline base64 images are cut to 10 characters and request bodies over 1.5MB are
  truncated, because VictoriaLogs rejects entries over 2MiB.
- **Time and streams.** Entries are timestamped from the record's `ts` (when the
  request happened, `vector.timeField`). `method`, `status` and `model` are the
  stream fields (`vector.streamFields`); keep that list low-cardinality.

## Sizing

Records carry whole request and response bodies. Measured on a production router:
~10GB/hour of raw records compressed to ~12GB/day in VictoriaLogs, so the default
14-day retention needed ~170GB. Size `victorialogs.server.persistentVolume.size`
from a day of your own traffic. Retention is by age (`retentionPeriod`; a bare number
is months); `victorialogs.server.retentionDiskSpaceUsage` adds a size cap.

`victorialogs.server.extraArgs.insert.maxLineSizeBytes` is raised to 16MiB. Without
it, VictoriaLogs skips long lines at ingestion -- that is, most long-prompt
requests -- and only counts them in `vl_too_long_lines_skipped_total`.

## Grafana

The datasource ConfigMap (`grafana.datasource.*`) is created in `monitoring`
with label `grafana_datasource: "1"`, which kube-prometheus-stack's Grafana sidecar
loads. Grafana also needs the
[`victoriametrics-logs-datasource`](https://grafana.com/grafana/plugins/victoriametrics-logs-datasource/)
plugin, which this chart cannot install (Grafana belongs to another release). In the
kube-prometheus-stack values:

```yaml
grafana:
  plugins:
    - victoriametrics-logs-datasource
```

When the Grafana pod has no route to grafana.com, install the plugin from an init
container that gets a proxy, and keep the proxy away from Grafana itself (its
in-cluster datasources would go through it):

```yaml
grafana:
  extraInitContainers:
    - name: install-victorialogs-plugin
      image: docker.io/grafana/grafana:13.1.1          # the same image Grafana runs
      env:
        - { name: HTTPS_PROXY, value: "http://proxy.example:3128" }
      command: ["sh", "-c"]
      args:
        - grafana cli --pluginsDir /var/lib/grafana/plugins plugins install victoriametrics-logs-datasource 0.32.0
          || echo "plugin install failed; starting Grafana without it"
      volumeMounts:
        - { name: storage, mountPath: /var/lib/grafana }
```

A repeated install is a no-op, and a failed download does not keep Grafana from
starting. The plugins directory must be persistent (`grafana.persistence.enabled`)
for the init container's install to be the one Grafana loads.

Example queries (Explore, VictoriaLogs datasource):

```
status:500
model:"kimi-k2.6" AND first_chunk_t:>2
prompt_tokens:>3000 AND resp_meta.usage.prompt_tokens_details.cached_tokens:<500
request_id:"41dc9914feb71bca5453c751187e5584"
NOT resp_meta.finish_reason:"stop"
```

## Values

| key | default | |
|---|---|---|
| `bodylog.hostPath` / `bodylog.existingClaim` | `""` | where bodylog writes; exactly one is required |
| `bodylog.namespace` | release namespace | namespace of the bodylog pod |
| `bodylog.podLabels` | `app.kubernetes.io/name: bodylog` | labels of the bodylog pod |
| `victorialogs.enabled` | `true` | deploy VictoriaLogs; `false` needs `victorialogsUrl` |
| `victorialogs.server.retentionPeriod` | `14d` | |
| `victorialogs.server.persistentVolume.size` | `100Gi` | see Sizing |
| `vector.readFrom` | `end` | `beginning` ships the current day's files too |
| `vector.timeField` | `ts` | empty stamps entries with ship time |
| `vector.streamFields` | `[method, status, model]` | |
| `vector.vrl` | `""` | replaces `files/bodylog.vrl` |
| `vector.checkpointHostPath` | `/var/lib/<release>` | |
| `grafana.datasource.enabled` | `true` | |
| `grafana.datasource.namespace` | `monitoring` | Grafana's namespace |
| `test.expectRecordsWithin` | `""` | e.g. `1h` |
