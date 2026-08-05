---
sidebar_position: 1
---

# Intro

**Syncee** is a lightweight, flexible, and optionally schema-driven data replication library for Roblox. It gives you complete control over how data is replicated to clients with minimal overhead and a simple intuitive API.

---

## Features
- **Simple & Flexible**: Easily replicate tables & buffers to specific clients with full control over replication targets.
- **Buffer Support**
- **Delta Replication**: Only replicates what changes within tables and buffers.
- **Schemas**: Schemas can be defined per table if needed to minimize bandwidth.
- **Ratelimiting**: Each table and buffer can be ratelimited individually.
- **Proxies**: You can create proxies for tables that automatically handle updates, with near-full support when used as parameters in Syncee's API.

## How it differs
Compared to the alternatives. It takes a different approach to the API and how data is replicated.
- You don't explicitly mark tables as replicated. Each player is assigned a root table in which everything is sent to them.
  You can structure this table however you want. You can also add other players' root tables in each other if you ever want to and it'll work fine.
- It's not aware of the changes you do to the tables on its own as it doesn't modify the original tables in any form or copy them for comparison. You're responsible for telling it what's changing.
- It does not send the changes automatically on its own. It lets you handle this yourself so you can integrate it into your networking solution seamlessly.
- Doesn't use paths. Each table & buffer is assigned a unique id.
- Supports having multiple copies of the same table and cyclic tables.

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
syncee = "anexpia/syncee@1.1.2"
```
---

## [<u>Setup Guide</u>](./setup.md)

