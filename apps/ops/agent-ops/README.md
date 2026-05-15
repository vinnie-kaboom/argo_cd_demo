# Agent Ops Event-Driven Remediation Pipeline

This document explains how Agent Ops receives events and triggers automated remediation workflows.

## What Agent Ops does

Agent Ops is an event-driven automation layer built with Argo Events + Argo Workflows.

It can:
- Record incoming events as reports (ConfigMaps)
- Refresh an Argo CD Application
- Pause or resume an Argo Rollout
- Optionally dispatch a GitHub event to open a fix PR flow

## Main components

- Event source webhook: [base/eventsource.yaml](base/eventsource.yaml)
- Event bus (NATS): [base/eventbus.yaml](base/eventbus.yaml)
- Sensor (parameter mapping + workflow trigger): [base/sensor.yaml](base/sensor.yaml)
- Workflow logic: [base/workflow-template.yaml](base/workflow-template.yaml)
- RBAC: [base/role.yaml](base/role.yaml), [base/clusterrole.yaml](base/clusterrole.yaml)

## Logic diagram

```mermaid
flowchart TD
  A[Webhook EventSource: agent-webhook]
  A1[/agent/remediate]
  A2[/agent/alerts from Alertmanager]
  B[Argo Events EventBus: NATS default]
  C[Sensor: agent-remediation-sensor]
  D[Create Workflow from WorkflowTemplate: agent-remediation]

  E[Step 1: record-event]
  E1[Create ConfigMap report with action, env, app, summary, timestamp]

  F{Dispatch by action}
  F1[action != open-fix-pr]
  F2[action == open-fix-pr]

  G[Step 2a: cluster-action]
  G1[record-only]
  G2[refresh-app: patch Argo CD Application annotation]
  G3[pause-rollout: patch Rollout spec.paused=true]
  G4[resume-rollout: patch Rollout spec.paused=false]

  H[Step 2b: open-fix-pr]
  H1{allowPullRequests == true?}
  H2{GITHUB_TOKEN present?}
  H3{proposedReplicaCount present?}
  H4[POST repository_dispatch to GitHub API]
  H5[Downstream GitHub workflow opens fix PR]

  I[RBAC + SA: agent-ops-sa]
  J[Env overlays]
  J1[dev: allowPullRequests true]
  J2[staging/prod: allowPullRequests false by default]

  A --> A1
  A --> A2
  A --> B --> C --> D
  C -->|map payload fields to workflow parameters| D
  D --> E --> E1 --> F

  F --> F1 --> G
  G --> G1
  G --> G2
  G --> G3
  G --> G4

  F --> F2 --> H --> H1
  H1 -->|yes| H2
  H1 -->|no| K[Exit: PR creation disabled]
  H2 -->|yes| H3
  H2 -->|no| L[Exit: token missing]
  H3 -->|yes| H4 --> H5
  H3 -->|no| M[Fail: missing proposedReplicaCount]

  I --> D
  I --> G
  I --> E
  J --> D
```

## Environment behavior

- Dev overlay enables PR path by default:
  - [overlays/dev/kustomization.yaml](overlays/dev/kustomization.yaml)
- Staging and prod keep PR path disabled by default:
  - [overlays/staging/kustomization.yaml](overlays/staging/kustomization.yaml)
  - [overlays/prod/kustomization.yaml](overlays/prod/kustomization.yaml)

## Alertmanager integration examples

- Receiver config: [examples/alertmanager-receiver.yaml](examples/alertmanager-receiver.yaml)
- Sample payload: [examples/alertmanager-sample-payload.json](examples/alertmanager-sample-payload.json)
