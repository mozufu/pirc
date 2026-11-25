---
label: Work
description: Coding sessions in a repository.
ui:
  noun: session
# Transitional host restriction until nodes accept explicit mode ids.
workdir: workspace
prompt:
  - base
  - agents:global
  - agents:workspace
  - agents:project
  - body
features_off: []
features_on: []
# null allows the node's normal tools; [] allows none.
tools: null
assistant: user
schedule_scope: own
project_config: true
workspace_memory: true
repository: true
recap: true
delete_sessions: false
---
