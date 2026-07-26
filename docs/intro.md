---
sidebar_position: 1
---

# Intro

**Syncee** is a high-performance, flexible, and optionally schema-driven state replication library for Roblox. It gives you complete control over how data is replicated to clients with minimal overhead and a simple intuitive API.

---

## Key Features
- **Simple & Flexible**: Easily replicate tables & buffers to specific clients with full control over replication targets.
- **Buffer Support**
- **Delta Replication**: Only replicates what changes within tables and buffers.
- **Schemas**: Schemas can be defined per table if needed to minimize bandwidth.
- **Ratelimiting**: Each table and buffer can be ratelimited individually.
- **Proxies**: You can create proxies for tables that automatically handle updates, with near-full support when used as parameters in Syncee's API.

## How it differs

Compared to alternatives present, **Syncee** handles replication differently and provides more features.
- You do not need to explicity mark tables for replication.
- Replicating anything is through a single function call.
- Not path-based. Tables and buffers are each assigned a single ID.
- Doesn't modify tables in any way or force you to use proxies. They are optional.
- Supports having multiple copies of same table and cyclic tables.
- Supports buffer delta replication.

Syncee does not handle sending the data to clients on its own. It lets you do this yourself so you can integrate it into your own networking solution.

---

## Installation

### Manual: 
Install the latest [release](https://github.com/anexpia/syncee/releases).\
You'll need to add [**Squish**](https://github.com/anexpia/Squish) manually too in the same folder as **Syncee**.

### Pesde:
```bash
pesde add anexpia/syncee
```

### Wally:
Add to your `wally.toml` under `[dependencies]`:
```toml
syncee = "anexpia/syncee@1.1.0"
```
---

## [<u>Setup Guide</u>](./setup.md)

