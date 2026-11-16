# Design — icrc1 recents cleanup (drift + hash-order early break)

Status: implemented in `vendor/icrc1-mo` (fix commit `009555d`). The §5 tests
ran red on the tests-only commit `d6a5f11`, exactly as listed, and green on the
fix. The §10 counterproofs CP1–CP5, CP-a and CP-b each went red where listed,
and CP-M measured the §4 table. CP-85 is the `icrc85-counterproof` check of
the pull request's CI.
Scope: `vendor/icrc1-mo` (local fork of icrc1-mo 0.2.1). No other package changes.

All line numbers refer to `main @ 091b5e34`.

## 0. What B compiles

`mops.toml` wires `icrc1-mo = "./vendor/icrc1-mo"`, so the lib that runs is
`vendor/icrc1-mo/src/ICRC1/lib.mo`, not the registry copy. `icrc2-mo` is also a
local fork (`vendor/icrc2-mo`). `icrc4-mo = "0.2.1"` comes from the registry and
compiles against the vendored icrc1 types.

The dedup state is one field of the ICRC1 state record
(`migrations/v000_002_000/types.mo:69`):

```motoko
var recent_transactions : Map.Map<Blob, (Nat64, Nat)>;   // hash → (inserted_at, block index)
```

The key is the rep-indy hash of the transaction value. That value contains `ts`
(= `created_at_time`) when the caller set it (`lib.mo:2182-2187`).

### Who reads and writes it

| Site | What it does |
|---|---|
| `lib.mo:1148` | `icrc1_transfer` adds `(now, index)` for **every** executed transfer, with or without `created_at_time`. |
| `lib.mo:1155` → `:1486-1488` | `handleCleanUp` → `cleanUpRecents()` runs synchronously at the end of every executed transfer. |
| `lib.mo:1356` | `set_fee_collector` adds `(now, index)`. |
| `lib.mo:1323` | `set_fee_collector` looks up the hash with a raw `Map.get` (no time check). It is guarded by its own TooOld check at `:1302`. |
| `lib.mo:1715-1725` | `find_dupe`: the entry counts as a duplicate iff `inserted_at + drift + window > now`. |
| `lib.mo:2108-2114` | dedup runs only when `created_at_time != null` (`testCreatedAt`, then `deduplicate` → `find_dupe`). |
| `lib.mo:1676-1688` | `is_too_old`: `created_at_time < now - (window + drift)`. |
| `lib.mo:1699-1704` | `is_in_future`: `created_at_time > now + drift`. |
| `vendor/icrc2-mo/src/ICRC2/lib.mo:1088, 1241, 1244, 2092, 2270, 2272` | approve / transfer_from write `(now, idx)` **directly** into `icrc1.get_state().recent_transactions` (placeholders with idx 0 before an await, then the real index). |
| `vendor/icrc2-mo/src/ICRC2/lib.mo:1042, 2067` | lookups through `icrc1.find_dupe`. |
| `vendor/icrc2-mo/src/ICRC2/lib.mo:1254, ~2280` | call `icrc1.cleanUpRecents()`. |
| `.mops/icrc4-mo@0.2.1/src/ICRC4/lib.mo:736, 744` | the batch writes one entry per executed transfer directly into the map, then calls `handleCleanUp` **once per batch**. |

Defaults (`migrations/v000_001_000/lib.mo:52-53`): `permitted_drift = 60 s`,
`transaction_window = 24 h`. Both can be changed at runtime through
`admin_update_icrc1` (`lib.mo:783-784`).

## 1. The defects

### D1 — cleanup ignores drift (and `find_dupe` takes it into account only once)

A re-send carries the same `created_at_time` `C`, so it has the same hash. The
ledger accepts it (it is not `#TooOld`) while `now ≤ C + window + drift`.
At insertion `is_in_future` allowed `C ≤ T + drift` (`T` = `inserted_at`). So a
re-send can still be accepted until:

    now ≤ T + window + 2·drift          (the dedup horizon of the entry)

But:

- `cleanUpRecents` deletes the entry once `T + window < now` (`lib.mo:1763`).
  Between `T + window` and `C + window + drift` the key is gone, the re-send
  passes `is_too_old`, and it **executes as a new transfer**. For the normal
  case `C ≈ T` the gap is `drift` wide (60 s by default). A downstream
  contrast test against a real ledger built from this repo has reproduced it
  end to end (that test is consumer-side, not in this repo).
- `find_dupe` treats the entry as live only while `now < T + window + drift`
  (`lib.mo:1718`). For a key dated into the future (`C = T + drift`, which the
  ledger allows) a re-send in `(T + window + drift, T + window + 2·drift]` is
  not reported, even when the entry is still in the map. This gap does not need
  the cleanup to reach the key. It is the same defect seen from the read side,
  and the fix covers it too.

### D2 — the walk breaks early in hash order

`cleanUpRecents` (`lib.mo:1754-1774`) walks `Map.entries` (`:1762`). That is
**Blob (hash) order**, not insertion order. It `break`s at the first entry that
is still live (`:1766-1768`). The comment at `:1767`, «items are inserted in
order in this map», is false.

The effects:

1. An expired key is deleted only if no live key sorts before it. The D1 gap is
   therefore real but depends on state. The downstream test showed both
   outcomes on a fresh ledger: the key is forgotten iff `hash(req) < hash(nudge)`. The `nudge` is the
   transfer that triggers the cleanup. It is already in the map and live when the
   walk starts (`:1148` runs before `:1155`).
2. Expired entries stay in the map. When the live set is `L` entries spread
   uniformly in hash space, one walk removes about `(N − L)/(L + 1)` entries.
   Under steady traffic (one insert per walk) that settles near `N ≈ 2L`, with
   no bound the code enforces: T5 (48 transfers per window, 3 windows) breaks
   `N ≤ 2L + SWEEP_MIN` first at step 113 (size 115, live 49). It grows when
   more than one entry is added per walk (icrc2 adds two, an icrc4 batch `m`),
   and after a quiet period the walk stops at the first new live entry (T6:
   15 removed on the first call, then 0).

Note what D2 does **not** do. A lingering expired entry never causes a false
`#Duplicate`, because `find_dupe` checks the time. A re-send of that key is
`#TooOld` anyway. So D2 costs memory, and it hides or exposes D1 depending on
hash order.

## 2. Invariant the fix establishes

> **The dedup decision depends only on the time predicate. The cleanup is pure
> memory management: it may delete an entry only once the predicate says the
> entry is dead.**

One helper, used by both `find_dupe` and the sweep:

```motoko
// LOCAL PATCH (recents horizon): an entry inserted at `inserted_at` must answer
// #Duplicate for as long as a re-send of the same hash can pass `is_too_old`.
// A re-send has the same created_at_time C, and C ≤ inserted_at + drift
// (`is_in_future` at insertion). It passes `is_too_old` while
// now ≤ C + window + drift. Hence the horizon is inserted_at + window + 2·drift.
// The sum is computed in Nat so that a window raised by an admin cannot trap
// on Nat64 overflow.
func recentIsLive(inserted_at : Nat64, now : Nat64) : Bool {
  Nat64.toNat(inserted_at) + Nat64.toNat(state.transaction_window)
    + 2 * Nat64.toNat(state.permitted_drift) >= Nat64.toNat(now)
};
```

- `find_dupe` (`:1718`) becomes `if (recentIsLive(found.0, get_time64())) return ?found.1;`.
- The sweep deletes an entry iff `not recentIsLive(entry.0, now)`.

Consequences:

- (a) **window + drift are respected.** A deleted entry is one whose every
  re-send is `#TooOld`. An entry still in the map answers `#Duplicate` exactly
  until the same horizon. Neither the read side nor the write side has a gap.
- The predicate reads the **current** `window`/`drift`. If an admin raises
  either one, entries the sweep has not reached yet come back to life (safe).
  Entries already swept do not. See risk R3.
- The window is longer by up to `2·drift` (two minutes on 24 h by default,
  about +0.14 % of live entries). That is the price of storing only
  `inserted_at`. Storing `C` would need a value-type change that breaks
  `icrc4-mo` (§3, option B).

Why `inserted_at` and not `C`: `C` is not stored anywhere. It is inside the
hashed value. Every writer, including the registry `icrc4-mo`, writes
`get_time64()` into slot 0. Changing slot 0 to mean `C` would change the meaning
of a field that code we do not own writes.

## 3. Walking without the early break — options

### Option A (recommended) — bounded incremental sweep with a transient cursor

`cleanUpRecents` no longer walks from the start and stops at the first live
entry. It resumes from a cursor and looks at a **bounded budget** of entries,
in hash order, wrapping around at the end. It collects the dead keys and deletes
them after the loop, keeping the collect-then-delete shape of the existing
LOCAL PATCH. It never breaks on a live entry.

```motoko
// LOCAL PATCH (recents sweep) — class-level, NOT stable: both reset on upgrade,
// which is harmless (the sweep restarts from the smallest key).
var sweepCursor : ?Blob = null;       // last key examined
var sizeAfterSweep : ?Nat = null;      // map size after the previous sweep (null: none yet)

let SWEEP_MIN : Nat = 16;              // floor per call
let SWEEP_PER_INSERT : Nat = 2;        // entries examined per entry added since last sweep

public func cleanUpRecents() : () {
  let now = get_time64();
  let size = Map.size(state.recent_transactions);
  let added = switch (sizeAfterSweep) { case null 0; case (?s) if (size > s) size - s else 0 };
  var budget = Nat.min(size, SWEEP_MIN + SWEEP_PER_INSERT * added);
  let dead = List.empty<Blob>();
  var last : ?Blob = sweepCursor;
  // pass 1: from the cursor (exclusive) to the end; pass 2: wrap from the start
  label sweep for (pass in [0, 1].values()) {
    let it = switch (pass, sweepCursor) {
      case (0, ?k) Map.entriesFrom(state.recent_transactions, Blob.compare, k);
      case (0, null) Map.entries(state.recent_transactions);
      case (_, _) Map.entries(state.recent_transactions);
    };
    for ((k, v) in it) {
      if (budget == 0) break sweep;
      if (pass == 0 and ?k == sweepCursor) { /* entriesFrom is inclusive: skip */ }
      else if (pass == 1 and Option.isSome(sweepCursor) and Blob.compare(k, Option.unwrap(sweepCursor)) == #greater) break sweep; // lap closed, cursor key included
      else {
        budget -= 1;
        last := ?k;
        if (not recentIsLive(v.0, now)) List.add(dead, k);
      };
    };
    if (pass == 0 and sweepCursor == null) break sweep; // started at the beginning: one pass is the lap
  };
  for (k in List.values(dead)) ignore Map.take(state.recent_transactions, Blob.compare, k);
  sweepCursor := last;
  sizeAfterSweep := ?Map.size(state.recent_transactions);
};
```

Two corrections were made at apply time (approved before coding):

- **(a) the size counter starts unset.** With `sizeAfterSweep = 0`, the first
  call after an upgrade counts the whole map as "added" and walks all of it in
  one transfer: `O(N)` over the backlog §6 says no single message processes.
  With `null`, nothing counts as added and the first budget is `SWEEP_MIN`.
  Counterproof CP-a.
- **(b) the wrap-around pass includes the cursor key.** Breaking at
  `k ≥ cursor` never examines the cursor key in the lap; when it is the only
  entry left, it stays forever. Counterproof CP-b.

(The sketch shows the shape. The apply writes it with the repo's style and with
`mo:core` APIs confirmed: `Map.entriesFrom` exists in `core@2.1.0`
`src/Map.mo:783`, and so do `Map.size :258` and `Map.take :620`.)

Why this shape:

- **No break on a live entry**, so hash order no longer decides what gets
  deleted. Order no longer decides correctness either: §2 makes the sweep pure
  memory management.
- **No stable state change.** `recent_transactions` keeps its type. The cursor
  and the counter are fields of the `ICRC1` class instance. That instance is
  rebuilt from the stable state after every upgrade (a class with mutable fields
  and functions cannot be a stable value), so the two fields are transient by
  construction. See §6.
- **It catches every writer.** icrc2's and icrc4's direct `Map.add`s land in the
  same map. The sweep sees them, and `added` counts them because it is derived
  from `Map.size`. There is no second index for them to forget to update.
- **Minimal divergence.** It touches one function (`cleanUpRecents`), one line
  (`find_dupe`) and adds one helper plus two `var`s and two constants in
  `vendor/icrc1-mo/src/ICRC1/lib.mo`. `vendor/icrc2-mo` and `icrc4-mo` are
  untouched.

Memory bound: every sweep examines at least `2·added` entries, so a full lap
over the `N` entries finishes within `N/2` inserts. An entry that died at the
start of a lap is gone by its end. Hence `N ≤ L + N/2`, so **`N ≤ 2·L`**
(`L` = live entries), plus `SWEEP_MIN` slack. In quiet periods nothing is
inserted, so nothing grows. The first transfers afterwards remove at least
`SWEEP_MIN` dead entries each until the map is back to its live set.

### Option B — secondary time index (rejected)

Add `recent_by_time : Map<(Nat64, Blob), ()>` (or a FIFO keyed by
`inserted_at`), then pop from the front while dead. That is the exact cleanup in
`O(dead · log N)`.

Rejected because:

1. **Every writer must keep the index in sync.** That means 2 sites in icrc1,
   6 in the vendored icrc2 and 1 in **registry `icrc4-mo`**. The last one means
   vendoring a fourth package (`icrc4-mo`) only to add one line, or accepting
   orphan entries that only an extra fallback sweep would ever reach (then the
   index buys nothing).
2. **Stable state change.** It needs a new ICRC1 migration `v000_003_000`, a new
   `#v0_3_0` tag on `ICRC1.State`, and an index rebuild of `O(N log N)` inside
   one upgrade message. Every exhaustive switch over `icrc1_migration_state`
   must learn the tag: `src/Token.mo:731-739`, `src/token-mixin.mo:266`,
   `pic/TokenWithICRC85.mo`.
3. **About 2× the per-entry memory** of recents (one more key and one more
   B-tree slot).

### Option C — full walk without break (rejected)

`O(N)` per transfer forever. Total cost is quadratic in traffic. The
instruction cost of a single transfer grows with the window's volume.

## 4. Cost (c) — estimates, and the CP-M measurement

The memory figures are order-of-magnitude estimates from the data-structure
shapes. The instruction figures were measured by CP-M (§10); the measured table
is at the end of this section.

Per entry, in the main heap (64-bit enhanced orthogonal persistence): a 32-byte
`Blob` key plus its header, a boxed `(Nat64, Nat)` tuple, and a B-tree slot.
That is on the order of **~100–150 B/entry**.

| Traffic inside the horizon (24 h + 2 min) | Live `L` | Memory with fix (`≤ 2L`) | Memory today (D2: about all-time) |
|---|---|---|---|
| 1 k transfers/day | ~1 k | ≤ ~0.3 MB | grows ~0.1–0.15 MB/day, never shrinks |
| 100 k transfers/day | ~100 k | ≤ ~30 MB | grows ~10–15 MB/day |

icrc2 operations can add 2 entries each (pre and post hash).

Instructions per cleanup call (Option A): the budget `SWEEP_MIN + 2·added` is
iterated (a B-tree step plus one compare per entry, roughly 10²–10³
instructions), plus `Map.take` for each dead entry (`O(log₃₂ N)` nodes,
roughly 10³–10⁴ instructions). For one transfer this means about 18 examinations
and at most about 18 deletions, so **~10⁵ instructions, independent of `N`**.
For an icrc4 batch of `m` transfers the budget is `16 + 2m`, which is linear in
the batch and already paid per item by the batch itself. Today's cost is also
bounded per call, but only because of the break that causes D2.

**Measured (CP-M).** One `cleanUpRecents` call, counted with
`countInstructions` in RecentsProbe (moc 1.3.0, PocketIC, fix `009555d`), with
`N` synthetic entries in the index. The update-message limit is 40·10⁹
instructions.

| Case | N = 10³ | N = 10⁴ | N = 10⁵ | Worst share of the limit |
|---|---|---|---|---|
| B: steady state, `added = 0`, examines `SWEEP_MIN` live entries | 174 251 | 175 409 | 180 118 | 0.0005 % |
| D: drain step, `added = 0`, removes `SWEEP_MIN` dead entries | 410 405 | 425 106 | 476 009 | 0.0012 % |
| A: one call walks all `N`, all live (`added = N`) | 9 455 579 | 94 304 066 | 942 246 105 | 2.4 % |
| C: one call walks and removes all `N`, all dead (`added = N`) | 23 305 449 | 268 548 681 | 2 979 980 368 | 7.5 % |

B and D are what a transfer pays. They grow only with the B-tree depth, and stay
within a few times the 10⁵ estimate above. A and C need `N` entries added
since the previous call, which only a seed (or a batch of `N/2` icrc4
transfers) produces. They are linear in `N`: about 9.4·10³ instructions per
live entry examined and about 3·10⁴ per dead entry removed. A single call
reaches 10 % of the limit (4·10⁹) at about 1.3·10⁵ dead entries added in one
message.

## 5. Tests in B (d)

They live under `pic/`, follow the existing vitest + PocketIC pattern, and use
the wasm from `bash pic/build-token-wasm.sh`. `TOKEN_WASM=<path>` points any of
them at an unpatched build, as `dedup_cleanup.test.ts` does.

**Observability.** D1 shows through the public API. D2 (entries that stay in
the map) does not. Proposal: a pic-only harness actor `pic/RecentsProbe.mo`, in
the style of `pic/TokenWithICRC85.mo`. It wires the vendored `ICRC1` class the
way `src/Token.mo` does and adds one query,
`recents_size() : Nat = Map.size(icrc1().get_state().recent_transactions)`.
`src/Token.mo`'s public interface does not change. Exposing a stats query in
Token.mo instead is open question Q2.

**Determinism.** Fix the clock with `pic.setTime(<constant>)` before the first
call. `created_at_time` is inside the hash, so a wall-clock start makes the hash
order vary from run to run. Use a fresh canister per case, and assert the precondition (0 blocks)
first. Add a `pic/` helper that computes the ICRC-3 representation-independent hash
of the transfer value (`repIndyHash` / `transferTxValue`), so a test can **pin and assert** the hash order it depends on.
A test must never go green by luck.

| # | File / case | Wasm | Red on `main` | Green after fix |
|---|---|---|---|---|
| T1 | `recents_horizon.test.ts` «a re-send after insertion + window, before #TooOld, is #Duplicate when the cleanup ran first». Pay `req` (C = now), advance window + 10 s, nudge, advance 20 s, re-send. Pin `hash(req) < hash(nudge)`. | Token | `Ok` (paid twice) — D1 cleanup side | `Duplicate` |
| T2 | same file, «a key dated +drift is #Duplicate up to insertion + window + 2·drift». C = now + drift, advance window + 1.5·drift, re-send, no nudge. | Token | `Ok` — D1 `find_dupe` side, independent of hash order | `Duplicate` |
| T3a | same file, «the boundary»: re-send at `C + window + drift` + 1 ns is `#TooOld`. | Token | green (guard against overshooting) | green |
| T3b | same file: re-send exactly at `C + window + drift` (= insertion + window + 2·drift, C = insertion + drift) is `#Duplicate`. | Token | `Ok` — D1 `find_dupe` side | `Duplicate` |
| T4 | `recents_sweep.test.ts` «expired entries that hash after a live one are swept». Seed 12 keyed transfers, advance window + 2·drift + 1 s, nudge. Pin: at least one seed hash > hash(nudge). Then `recents_size()`. | RecentsProbe | `> 1` — D2 | `== 1` (the nudge) |
| T5 | same file, «the map stays ≤ 2·live + SWEEP_MIN under steady traffic». 3 windows of traffic at a fixed rate, sample `recents_size()` each step. | RecentsProbe | settles near 2L; the bound breaks first at step 113 (size 115, live 49) — D2 | bound holds |
| T6 | same file, «a quiet period drains». 200 entries, jump 2 windows, k transfers, size falls by ≥ 16 per call until it reaches the live set. | RecentsProbe | does not drain | drains |
| T10 | `recents_sweep.test.ts` «the cursor key is swept when it is the only expired entry» | RecentsProbe | green | green (red under CP-b) |
| T7 | `recents_parity.test.ts` — **parity with the downstream contrast scenario**, timings verbatim (pay; +23 h re-send; +24 h 10 s nudge; +24 h 30 s re-send; +24 h 61 s re-send), both hash sides pinned (`hash(req)` before / after `hash(nudge)`). | Token | side −1: `["Ok","Duplicate","Ok","TooOld"]` (downstream case 1, paid twice) | **both sides**: `["Ok","Duplicate","Duplicate","TooOld"]`, recipient paid once |
| T8 | `dedup_cleanup.test.ts` (existing) — the delete-while-iterating regression | Token | — | still green |
| T9 | `icrc2_dedupe.test.ts` (existing) — icrc2 lookups through `find_dupe` | Token | — | still green |

T1 and T7 side −1 are the "red without the fix" proof of D1 through the cleanup.
T2 is the proof through `find_dupe`. T4 is the proof of D2. T7 side +1 is green
on `main` too: it is the downstream case 2.

## 6. Stable state across the upgrade (f)

With Option A **the stable signature does not change**:

- `ICRC1.State` keeps `#v0_2_0`. `recent_transactions : Map<Blob,(Nat64,Nat)>`
  keeps its type (`types.mo:69`). No migration file and no new variant tag.
  Neither `Token.mo:731-739` nor `token-mixin.mo:266` changes.
- `sweepCursor` and `sizeAfterSweep` live in the class instance and reset on
  upgrade. A reset only restarts the lap at the smallest key, with a first
  budget of `SWEEP_MIN`.
- Entries that piled up under D2 in a canister built from `main` are read with
  the new predicate after the upgrade. They are dead, so the sweep drains them
  at ≥ 16 per transfer (T6). No single message has to process the backlog, so
  the upgrade itself carries no instruction-limit risk. (`stable-memory`: "an
  incompatible upgrade is rejected at runtime with `RTS error:
  Memory-incompatible program upgrade`". There is none here.
  `migrating-motoko-actors` § Stable-Compatible: an unchanged field type is
  trivially compatible, and no migration is required.)
- Behaviour across the upgrade: an entry inserted before the upgrade is still
  `#Duplicate` up to `T + window + 2·drift`. Before the upgrade it was until
  `T + window + drift`. That is a strict widening, so no gap opens during the
  transition.

Tests:

- **U1** `recents_upgrade.test.ts`: install a baseline built from `main 091b5e34`
  (`pic/build-baseline-wasm.sh 091b5e34 token_recents_base`), then build up live
  and dead recents (dead ones lingering through D2). Upgrade to the fixed wasm.
  Assert: the upgrade succeeds; a live key re-send is `#Duplicate`; a dead key
  re-send is `#TooOld`; balances and the block log are unchanged; the dead
  backlog drains under T6's rule (the size is read through RecentsProbe built
  at both refs, or by block count if Q2 says otherwise).
- A consumer that builds `src/Token.mo` runs its own stable-compatibility
  check against its deployed base. It must report **compatible**: the
  signature is identical (§9).

If the owner prefers Option B, §3-B lists what changes. That route needs
`writing-motoko` and `migrating-motoko-actors` (§ "Add or extend variant type",
§ "Migration-Time Semantics": the rebuild runs once, in the upgrade context)
applied to ICRC1's in-library migration chain (`migrations/lib.mo`), plus U1
against a large backlog.

## 7. ICRC-85 stays OFF (e)

The patch does not touch any ICRC-85 path. It does not touch the kill switches
in `src/Token.mo:345-350, 410-414, 492-500`, `state.org_icdevs_ovs_fixed_state`
(the `activeActions` increment at `lib.mo:1152` stays as it is), or
`openvaluesharing.mo`.

Proof that it stays off:

- `pic/icrc85_off.test.ts` and `pic/icrc85_off_mixin.test.ts` are green on the
  fixed wasms.
- **Counterproof**: `bash pic/icrc85-counterproof.sh` builds the same sources
  with every kill switch flipped on (`pic/build-icrc85-on-wasm.sh`). It must
  exit 0, which means every "off" guard went red on its own ICRC-85 assertion
  (`pic/icrc85-counterproof-check.mjs`).
- A consumer that runs its own ICRC-85 counterproof re-runs it after bumping
  its pin.

## 8. Fork today, applying the patch, upstream (g)

- **Today**: `vendor/icrc1-mo` is a full copy of registry icrc1-mo 0.2.1, wired
  by local path. It carries two `LOCAL PATCH`es: `cleanUpRecents`
  collect-then-delete (commit `7f76539`) and ICRC-106 as text (`3471dc6`). Both
  are documented in `vendor/README.md` with their regression tests.
- **This patch** becomes the third `LOCAL PATCH` in the same file. It is placed
  in the same function as the first one, so the README entry for
  `cleanUpRecents` grows one paragraph («recents horizon + bounded sweep»). The
  regression tests are T1, T2, T4 and T7.
  `mops sources | grep icrc1-mo` must still print `vendor/icrc1-mo/src`. No
  `mops.toml` or `mops.lock` change is needed.
- **Divergence**: about 40 changed lines in one file, no type changes, no new
  files under `vendor/`. icrc2 and icrc4 are not touched.
- **Upstream (note only)**: `icdevsorg/icrc1.mo` has the same three issues
  (delete-while-iterating, no drift, early break). A separate upstream PR could
  carry all three. Check upstream `main` first, since it may have moved since
  0.2.1. It is not part of this unit.

## 9. Consumer pin bump (h)

This repo stays consumer-agnostic (`CLAUDE.md`), so consumer-specific steps,
paths and suite names are tracked outside it. What is generic:

1. A consumer that pins a commit of this repo bumps the pin to the merge
   `<SHA>`. Nothing in its mops manifests changes: dependency paths and package
   versions are the same.
2. Its stable-compatibility check against its deployed base must report
   compatible. The ledger's stable signature is identical (§6).
3. Every suite that installs a ledger built from this repo is re-run, including
   any ICRC-85-off counterproof (§7).
4. A downstream test that asserts the **dedup gap is open** turns red on
   purpose. That is a re-send executing between `inserted_at + window` and
   `created_at_time + window + drift`, the T7 side −1 sequence
   `["Ok","Duplicate","Ok","TooOld"]`. From `<SHA>` on, the real ledger answers
   `["Ok","Duplicate","Duplicate","TooOld"]` on both hash sides, and the
   recipient is paid once. A test double that is pessimistic by design (it
   still opens the gap) no longer matches the real ledger in that case.
   Consumer-side retry gates that stay below the window remain correct, and
   become merely conservative.

## 10. Counterproofs planned (i)

Same pattern as `635e984` / `52bf4b4`: one commit marked TEMPORARY on
`fix/icrc1-recents-cleanup`, run, then reverted in the next commit. The
recorded literal is the vitest assertion text.

| CP | Mutation (in `vendor/icrc1-mo/src/ICRC1/lib.mo`) | Test that must go red | Literal expected |
|---|---|---|---|
| CP1 | `recentIsLive` uses `window + drift` (one drift) | T2 | `expected 'Ok' to deeply equal 'Duplicate(+0)'` |
| CP2 | `recentIsLive` uses `window` only (the old cleanup bound) | T1, T7 side −1 | T7: `expected [ 'Ok', …, 'Ok', … ] to deeply equal [ 'Ok', …, 'Duplicate(+0)', … ]` |
| CP3 | restore `break` at the first live entry in the sweep | T4 | `expected <n > 1> to be 1` (recents_size) |
| CP4 | `SWEEP_PER_INSERT = 0`, `SWEEP_MIN = 0` (sweep disabled) | T4, T5, T6 red; **T1, T2, T7 stay green** | proves dedup correctness does not depend on the sweep (§2) |
| CP5 | `recentIsLive` uses `>` instead of `>=` | T3b (re-send exactly at the horizon) | `expected 'Ok' to deeply equal 'Duplicate(+0)'` |
| CP-a | `sizeAfterSweep` starts at `?0` | U1 probe, first call after the upgrade | `expected 34 to be less than or equal to 16` |
| CP-b | wrap-around pass breaks at `k ≥ cursor` | T10 (and T4) | `expected 1n to deeply equal 0n` |
| CP-85 | (existing script) kill switches flipped on | `icrc85_off*.test.ts` | `bash pic/icrc85-counterproof.sh` exit 0 |
| CP-M | none: measurement. `ExperimentalInternetComputer.countInstructions` around `cleanUpRecents` in RecentsProbe at N = 10³, 10⁴, 10⁵ | — | fills the §4 table with measured numbers |

## 11. Risks and open questions (j)

Risks:

- **R1 — the sweep is amortized, not instant.** Dead entries can linger for up
  to one lap. That affects memory only (§2), and it is bounded by `N ≤ 2L`.
- **R2 — `2·drift` of over-retention.** A key stays `#Duplicate` up to
  `2·drift` (2 min by default) after the last moment a re-send could be valid.
  It is harmless: such a re-send is `#TooOld` first, because `testCreatedAt`
  runs before `deduplicate` (`lib.mo:2108-2114`).
- **R3 — raising `transaction_window` / `permitted_drift` at runtime.** Entries
  already swept under the old values cannot come back. For one horizon after
  the change, a re-send of such a key could execute. This is not new (today's
  code has it too). The admin procedure is: change these only while no keyed
  traffic is in flight, or do not raise them.
- **R4 — the RecentsProbe harness is not the Token wasm.** T4–T6 test the
  library through a mirror of Token.mo's wiring. If Token.mo's ICRC1 wiring
  changes, the probe can drift away from it. Mitigation: the probe imports the
  same `ICRC1` and sets the same window and drift. T1, T2, T3 and T7 run on the
  real Token wasm.
- **R5 — downstream tests that pin the old gap** (§9.4) turn red on purpose
  at the pin bump.
- **R6 — many entries added between two cleanups.** icrc4 batches write their
  entries into the index without a cleanup of their own. The next cleanup
  (an icrc1 transfer, or icrc2 `transfer_from`) counts them all as added, and
  examines `16 + 2·added` entries in one message. The worst case measured in
  §4 (C: every examined entry dead and removed, ~3·10⁴ instructions each)
  reaches 10 % of the 40·10⁹ update limit at ~1.3·10⁵ entries removed in
  one call. That needs ~6.5·10⁴ entries added since the previous cleanup,
  with no icrc1 transfer or `transfer_from` in between: ~325 batches at
  Token.mo's default `max_transfers = 200`, and never fewer than ~15, because
  `BATCH_ARG_CEILING` (1 MiB) caps any batch at about 4.5·10³ transfers. An
  admin who raises `max_transfers` should keep this in mind.

Questions for the owner:

- **Q1** Option A (bounded sweep, no state change) or Option B (time index,
  migration v0_3_0, fourth vendored package)? The design recommends **A**.
- **Q2** Observability of D2: a pic-only `RecentsProbe` (recommended, Token.mo
  interface unchanged), or a public `get_recents_stats` query in Token.mo (also
  useful for ops memory monitoring, but it changes the ledger's Candid for every consumer)?
- **Q3** Should the patch also stop adding recents for transfers **without**
  `created_at_time` (`lib.mo:1148`)? Their hash never matches a lookup, since
  every lookup carries `ts`, so they are pure memory. It is a one-line change in
  icrc1 that would cut memory for unkeyed traffic. icrc2 and icrc4 would still
  add theirs, which the sweep handles. The design does **not** include it, to
  keep divergence minimal.
- **Q4** (downstream) How consumer tests that pin the old gap are updated is
  tracked outside this repo (§9.4).
- **Q5** Should `SWEEP_MIN = 16` and `SWEEP_PER_INSERT = 2` stay library
  constants (recommended, no new state), or become init args?
- **Q6** Upstream PR to `icdevsorg/icrc1.mo` with the three fixes: open it as a
  separate unit, or not at all?
