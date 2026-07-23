---
sidebar_position: 1
---

# Intro

**Syncee** is a high-performance, flexible, optionally schema-driven one-way **data replication library** for Roblox that gives you complete control over how tables are replicated to clients with a simple and intuitive API.

## Key Features
- **Simple & Flexible**: It's very easy to replicate anything you want to specific clients.
- **Delta Updates**: Only replicates what changes for tables and buffers.
- **Schema Support**: You can provide schemas to control how data is replicated for tables.
- **Ratelimiting**: Each table & buffer can be given a different ratelimit.
- **Proxies**: For clean API usage.
- **Cyclic tables?**: .. Please don't. It works though.

---

## Installation

### Manual: [releases](https://github.com/anexpia/syncee/releases)
### Pesde:
```bash
pesde add anexpia/syncee
```

### Wally:
Add to your `wally.toml` under `[dependencies]`:
```toml
Syncee = "anexpia/syncee@1.0.0"
```
---

## [Usage Guide](./usage.md)
