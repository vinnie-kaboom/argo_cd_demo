# Agent Ops

Agent Ops is a small automation system for handling alerts and remediation actions.

If you want the one-line version:

- Something happens in the cluster
- Agent Ops receives the event
- It records what happened
- Then it either fixes the cluster or starts a GitHub-based fix flow

## Simple flow

```text
Alert or webhook
      |
      v
Agent Ops EventSource
      |
      v
EventBus
      |
      v
Sensor
      |
      v
agent-remediation Workflow
      |
      +--> record a report
      |
      +--> if action = cluster change:
      |        patch Argo CD app or Argo Rollout
      |
      +--> if action = open-fix-pr:
               dispatch GitHub event for a fix PR
```

## What it is for

Agent Ops is used to do one of these things when an alert arrives:

1. Record the event so there is an audit trail.
2. Refresh an Argo CD Application.
3. Pause or resume an Argo Rollout.
4. Optionally ask GitHub to open a fix PR flow.

## What happens step by step

1. A webhook hits the EventSource in [base/eventsource.yaml](base/eventsource.yaml).
2. Argo Events sends that message through the EventBus in [base/eventbus.yaml](base/eventbus.yaml).
3. The Sensor in [base/sensor.yaml](base/sensor.yaml) reads the payload and turns it into workflow parameters.
4. The workflow in [base/workflow-template.yaml](base/workflow-template.yaml) always records a ConfigMap report first.
5. After that, it takes one of two paths:
   - If the action is a cluster action, it patches Argo CD or a Rollout.
   - If the action is `open-fix-pr`, it can dispatch a GitHub event to start a fix PR flow.

## The two main event types

### 1. Remediation webhook

This is the direct control path.

Example actions:
- `record-only`
- `refresh-app`
- `pause-rollout`
- `resume-rollout`

The workflow gets values like:
- app name
- namespace
- rollout name
- environment
- proposed replica count

### 2. Alertmanager webhook

This is the alert-driven path.

The example Alertmanager receiver in [examples/alertmanager-receiver.yaml](examples/alertmanager-receiver.yaml) sends alerts to Agent Ops.

The sample alert payload in [examples/alertmanager-sample-payload.json](examples/alertmanager-sample-payload.json) shows how alert labels map into workflow parameters.

## What the workflow does

The workflow in [base/workflow-template.yaml](base/workflow-template.yaml) has three jobs:

1. Record the event.
2. Run the requested cluster action.
3. Optionally dispatch a GitHub repository event to open a fix PR flow.

### Record event

The workflow writes a ConfigMap report with:
- timestamp
- action
- environment
- app name
- namespace
- rollout name
- proposed replica count
- summary

### Cluster actions

If the action is not `open-fix-pr`, the workflow can:

- patch an Argo CD Application to refresh it
- patch a Rollout to pause it
- patch a Rollout to resume it

### Fix PR flow

If the action is `open-fix-pr`, the workflow only continues when:

- pull requests are allowed in that environment
- a GitHub token exists
- `proposedReplicaCount` is present

If all of that is true, it sends a `repository_dispatch` event to GitHub.

## Why dev/staging/prod behave differently

The overlays control whether GitHub PR creation is allowed.

- Dev: [overlays/dev/kustomization.yaml](overlays/dev/kustomization.yaml)
- Staging: [overlays/staging/kustomization.yaml](overlays/staging/kustomization.yaml)
- Prod: [overlays/prod/kustomization.yaml](overlays/prod/kustomization.yaml)

In practice:
- Dev allows the PR path.
- Staging and prod keep it off by default.

## RBAC

Agent Ops runs as the `agent-ops-sa` service account and uses RBAC from:
- [base/role.yaml](base/role.yaml)
- [base/clusterrole.yaml](base/clusterrole.yaml)
- [base/rolebinding.yaml](base/rolebinding.yaml)
- [base/clusterrolebinding.yaml](base/clusterrolebinding.yaml)

This is what gives it permission to record events and patch the resources it manages.

## Quick mental model

Think of Agent Ops like this:

- Event comes in
- Sensor translates it
- Workflow records it
- Workflow either changes the cluster or starts a PR flow

That is the whole system.
