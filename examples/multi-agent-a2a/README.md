# dsh A2A collaboration demo

Two independent DeepSeek Harness instances collaborate through
[`@ryubyte/dsh-a2a@0.3.1`](https://github.com/ryubyte/dsh-a2a). Headquarters A handles an offline robot and
delegates warehouse radar planning to B. The plugin discovers B's Agent Card, exposes B's skill to A as
`a2a__executor__localization`, creates a real dsh session on B for the incoming request, and returns
its reply as an A2A Artifact. The wire transport is the plugin's A2A v1.0 JSON-RPC implementation.

Each agent has a separate host bind directory: `./data/agent-a` and `./data/agent-b`, each mounted
at `/home/dsh` in its own container. No writable directory is shared between A and B.
The image is pinned to `dsh-v0.2.1-rc.2` for this feasibility test. The A2A plugin is installed
**after dsh starts**, through the official plugin CLI, and persists in that agent's host directory.
There is no derived image or Kafka dependency.

## Business scenario and knowledge boundaries

A reads [offline-event.json](agent-a/offline-event.json) for robot AMR-017 and resolves warehouse
WH-SH-03 through [warehouses.json](agent-a/warehouses.json). Unknown warehouse IDs stop the workflow.
A has the last reported position, timestamp and search-priority radius, but no warehouse map or
sensor inventory. The radius is a search priority, not a bound on where the robot could have moved.

B alone receives [its role file](agent-b/AGENTS.md), containing the 16 × 12 one-meter matrix,
opaque racks, and six wall-mounted sensors with fixed 30–90° sector openings, range, current
heading and mechanical rotation limits. The runtime instruction filename is `AGENTS.md` (the
Harness convention), rather than `Agent.md`. A learns details only from B's returned document;
this is input separation, not a claim that the final document hides the warehouse layout.

The document workflow is:

1. A creates `定位方案.original.md` and `定位方案.md` from the event and template, leaving
   `房间布局` and `传感器调节` empty.
2. A sends the **entire Markdown text** through its remote skill; no shared path or filesystem
   transfer is used. B is selected by warehouse ID, not by publishing private geometry in its card.
3. B fills the two sections, writes a scan plan JSON locally, runs the geometry checker, and includes
   the plan, measured coverage summary, blind spots and fallback actions in those sections.
4. B returns the full document as a text Artifact. A saves `定位方案.returned.md`, validates that all
   other text and section order are unchanged, and accepts it as `定位方案.md` only on success.

Archive the three generated Markdown files before another normal run; preparation deliberately
refuses to overwrite them. `work.md`, if present locally, is not an input to this workflow.

## Geometry model and limitations

B's checker reads its deployment directly from the fenced `warehouse-json` block in `AGENTS.md`.
Coordinates originate at the southwest outer corner; matrix rows run north to south. Headings
are counterclockwise from east. Sector openings are fixed; only headings change. Every round
specifies all six sensors, with motion measured from the preceding round (initial deployment
headings for round one). Closed wall/rack rectangles occlude line of sight, including tangencies.

Coverage is sampled at walkable cell centers, not over continuous floor area. The report gives
per-round visibility, simultaneous sensor pairs, uncovered cells, and cells never covered by
two sensors in the same round. Single observations from different rounds do not count as dual
coverage. A syntactically valid plan can still leave blind spots: zero exit status means the
calculation ran, **not** that full coverage or real localization succeeded.

This demo plans only: it does not actuate hardware, simulate observations, identify a robot, or
claim a measured position. It assumes radar range/bearing outputs; actual localization needs
calibration, synchronization, target association and measurement uncertainty handling. The 2D
opaque-obstacle model ignores penetration, multipath and elevation. B must disclose limitations
and propose additional sweeps or manual inspection where coverage is insufficient.

Local tests need only Python 3 and Node.js:

```sh
python3 -m unittest discover -s examples/multi-agent-a2a/tests -p 'test_*.py'
node --test examples/multi-agent-a2a/tests/document.test.mjs
```

## Start and install

Requirements: Docker Compose v2 with `up --wait`, Internet access for npm installation, and
a model provider/API credential configured separately in each dsh instance.
The data directories must be owned by UID 1000 (the container user). `setup.sh` creates missing
directories with mode 0700 and checks ownership; on hosts using another UID, an administrator
must assign those two directories to UID 1000 before setup. Do not commit `data/`: it contains
credentials, sessions and installed plugins and is excluded by the example's `.gitignore`.

```sh
cd examples/multi-agent-a2a
bash setup.sh
```

The script starts the stock containers, initializes each profile's `a2a.json`, and runs the
following commands for B first, then A. When upgrading the old demo, it backs up the active config
and replaces the old `acceptance` skill with `localization`, preserving connection URLs, tokens
and other settings. It refreshes B's inbound role file, backing up any different previous copy.

```sh
docker compose exec agent-b dsh plugin --profile web add @ryubyte/dsh-a2a@0.3.1
docker compose exec agent-b dsh-restart
docker compose exec agent-a dsh plugin --profile web add @ryubyte/dsh-a2a@0.3.1
docker compose exec agent-a dsh-restart
```

With this source-built image, pnpm reports missing profile-level peers (Cordis, dsh services and
React). These are supplied by the Harness runtime rather than installed in the profile. In the
local verification, the plugin loaded and A registered B's skill despite those warnings. Treat
that as runtime connectivity evidence, not proof that every plugin feature or client UI works.

Open [Agent A](http://127.0.0.1:3381) and [Agent B](http://127.0.0.1:3481). Configure the provider,
credentials and **default model** in both UIs; selecting a model in a single B chat does not
necessarily configure the default used by newly created inbound sessions.

In Settings → A2A connections, A should show the connected `executor` and its localization skill.
B should show its enabled inbound service. The plugin's own panels supply connection visibility;
this example does not add a separate monitoring service.

## Validate and run the collaboration

```sh
bash verify.sh
```

This checks A-to-B Agent Card discovery, missing/wrong-token rejection, authenticated task listing,
and A's registered remote skill. It does not call a model.

After configuring B's default model, optionally run a real protocol execution probe:

```sh
bash verify.sh --execute
```

This invokes B's model (and may incur provider charges), sends a real document, and requires a
completed text Artifact with both sections filled and protected content unchanged. It saves the
response under a fresh `/home/dsh/a2a-probe-*` directory in A. This does not test A's model choosing
the delegation tool, nor independently verify the geometry claimed by B.

For the actual collaboration, create a chat in A with cwd `/home/dsh` and paste [prompt.md](prompt.md).
Only A needs an initial human message: its remote tool invocation starts B's work automatically.
Watch the A2A tool call in A and the `A2A:` session in B. B's session cwd is
`/home/dsh/.dsh/profiles/web/.a2a-sessions`; initialization copies B's role instructions there.
The result should be `定位方案.md` in A's home, alongside its original and returned copies:

```sh
docker compose exec agent-a cat /home/dsh/定位方案.md
docker compose logs --tail=100 agent-a agent-b
```

A must send all inputs in its delegation and B must return its report as text. B's local file paths
are not usable by A. Model generation and whether A chooses a tool depend on provider configuration;
a successful discovery check alone does not establish a completed collaboration.

## Configure and deploy separately

Initial configuration templates live in [agent-a/a2a.json](agent-a/a2a.json) and
[agent-b/a2a.json](agent-b/a2a.json). After first setup, the active copies are
`/home/dsh/.dsh/profiles/web/a2a.json` in each agent's host directory; use the plugin UI to edit them. Re-running
setup preserves connection settings, with the one-time legacy skill migration described above.
Other template edits do not change an initialized profile.

For separate servers, start only the appropriate service on each host (`docker compose up -d agent-a`
or `docker compose up -d agent-b`), then run the initialization, plugin installation and restart
commands for that service. Set B's `server.baseUrl` to its reachable HTTPS origin and A's
`agents[0].agentCardUrl` to that origin plus `/.well-known/agent-card.json`. The advertised JSON-RPC
URL must be reachable by A; leaving `http://agent-b:3081` in a remote Agent Card will fail.
Update A's `warehouses.json` registry to match the remote Agent Card URL and selected tool, too.

Replace the example token in B's `server.authToken` and A's `agents[0].bearerToken` with the same
strong secret. Use TLS or a trusted private network. The checked-in token is for this loopback-only
local demo. Tokens are stored in the active config with mode `0600`.

The host-published UI ports are loopback-only. The normal image proxy forwards both A2A and UI
routes, so publishing B's entire port also publishes its authenticated dsh session. For remote
deployment, restrict a dedicated HTTPS reverse proxy to `/.well-known/agent-card.json` and `/a2a`
(exact path, not `/a2a/api`); keep the UI private, or configure the image's basic-auth pair. Basic
auth and A2A bearer auth both use `Authorization`, so a single external endpoint cannot simply
require both without additional proxy routing/auth design.

## Lifecycle and scope

```sh
docker compose ps
docker compose down
```

Homes and plugin installs survive `down` and container recreation. There are no named volumes;
`down --volumes` does not delete the bind-mounted data. Back up these host directories before
removing or replacing them. Installing into the host directory is deliberate for this feasibility phase; a future
deployment image can bake a validated version into its image-owned plugin payload.

The saved WH-SH-03 result bundle, when available locally, is stored directly in `data/agent-b/`:
`WH-SH-03-定位方案.md`, `plan.json`, `geometry.json`, and `WH-SH-03-manifest.json`.
B sees these at `/home/dsh/`; A cannot read them directly. The manifest records checksums and
calculation parameters. Reuse only for matching inputs and unchanged warehouse deployment;
this storage change does not add automatic cache selection. To replay, ask B to return the saved
document via A2A. Local runtime data and the bundle are not included in a fresh Git checkout.

The plugin implements the A2A transport and dsh adaptation. This example does not patch its source
or claim full protocol conformance based on the smoke checks. Inspect the plugin's settings panel
and B's actual session when diagnosing provider, task, approval or cancellation failures.
Task storage in this plugin version is in memory; a dsh process restart loses its A2A task query
history even though dsh session data persists. This feasibility example does not add recovery.

##
