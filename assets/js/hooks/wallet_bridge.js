// WalletBridge — client-side localStorage wallet for eCash tokens.
//
// Tokens are bearer instruments stored in the browser. The server never
// sees token secrets — only blinded messages (B') cross the wire during
// minting. Communication uses LiveView push_event (server→client) and
// pushEvent (client→server).

import * as cashew from "../cashew_wasm"

const TOKENS_KEY = "minted:tokens"
const ACTIVITIES_KEY = "minted:activities"
// Pending blinding state per quote, persisted across page reload so a
// browser crash mid-deposit doesn't lose the secrets/r values needed to
// unblind the server's signatures. The key is the quote_id; the value
// is the same shape as the in-memory `_blindingStates[quote_id]` entry.
const BLINDING_KEY = "minted:pending_blinding"
const MAX_ACTIVITIES = 50

// Wrap every setItem so the caller can react to QuotaExceededError or
// any other DOMException without crashing the rest of the flow.
function safeSetItem(key, value) {
  try {
    localStorage.setItem(key, value)
    return { ok: true }
  } catch (e) {
    console.error(`localStorage write failed for ${key}:`, e)
    return { ok: false, error: e }
  }
}

// JSON parse with corruption logging. Returns the fallback value when
// the entry is missing OR corrupt; the caller cannot tell the
// difference, so it must treat both as "no data" — but at least the
// console gets a breadcrumb so a user reporting "my wallet is empty"
// can be debugged.
function safeReadJson(key, fallback) {
  let raw
  try {
    raw = localStorage.getItem(key)
  } catch (e) {
    console.error(`localStorage read failed for ${key}:`, e)
    return fallback
  }
  if (!raw) return fallback
  try {
    return JSON.parse(raw)
  } catch (e) {
    console.error(`localStorage corrupt JSON in ${key} (length=${raw.length}):`, e)
    return fallback
  }
}

function readTokens() {
  return safeReadJson(TOKENS_KEY, [])
}

function writeTokens(tokens) {
  return safeSetItem(TOKENS_KEY, JSON.stringify(tokens))
}

function readActivities() {
  return safeReadJson(ACTIVITIES_KEY, [])
}

function writeActivities(activities) {
  return safeSetItem(ACTIVITIES_KEY, JSON.stringify(activities.slice(0, MAX_ACTIVITIES)))
}

// Pending blinding state — Uint8Array fields are encoded to/from hex
// because JSON can't round-trip them. Hex decoding is strict so a
// corrupted entry surfaces via the catch block rather than silently
// becoming an array of NaN bytes that would later fail BDHKE.
function readPendingBlinding() {
  const parsed = safeReadJson(BLINDING_KEY, null)
  if (parsed == null) return {}

  const out = {}
  for (const [qid, encoded] of Object.entries(parsed)) {
    try {
      out[qid] = {
        keyset_id: encoded.keyset_id,
        keyset_keys: encoded.keyset_keys,
        items: encoded.items.map(it => ({
          amount: it.amount,
          secret: cashew.fromHex(it.secret),
          r: cashew.fromHex(it.r),
          bPrime: cashew.fromHex(it.bPrime)
        }))
      }
    } catch (e) {
      console.error(`pending blinding entry corrupt for quote ${qid}, dropping:`, e)
    }
  }
  return out
}

function writePendingBlinding(states) {
  const encoded = {}
  for (const [qid, state] of Object.entries(states)) {
    encoded[qid] = {
      keyset_id: state.keyset_id,
      keyset_keys: state.keyset_keys,
      items: state.items.map(it => ({
        amount: it.amount,
        secret: cashew.toHex(it.secret),
        r: cashew.toHex(it.r),
        bPrime: cashew.toHex(it.bPrime)
      }))
    }
  }
  return safeSetItem(BLINDING_KEY, JSON.stringify(encoded))
}

function countWhere(list, pred) {
  return Array.isArray(list) ? list.filter(pred).length : 0
}

function computeState(tokens) {
  let balance = 0
  const tokensByDenom = {}

  for (const t of tokens) {
    balance += t.amount
    const key = String(t.amount)
    tokensByDenom[key] = (tokensByDenom[key] || 0) + 1
  }

  return {
    balance,
    token_count: tokens.length,
    tokens_by_denom: tokensByDenom
  }
}

const WalletBridge = {
  mounted() {
    // Initialize WASM module (async, completes before any deposit can finish)
    this._wasmStatus = "pending"
    this._wasmReady = cashew.init().then(() => {
      this._wasmStatus = "ready"
      this.pushEvent("wallet:wasm_status", { status: "ready" })
    }).catch(e => {
      this._wasmStatus = "failed"
      console.error("WASM init failed:", e)
      this.pushEvent("wallet:wasm_status", { status: "failed" })
    })

    // Per-quote blinding state. Keyed by quote_id so concurrent deposits
    // don't clobber each other. Persisted to localStorage so a browser
    // reload between blinding and unblinding doesn't lose the deposit.
    this._blindingStates = readPendingBlinding()

    // In-memory per-quote retry counter. After MAX_REQUEST_RETRIES
    // unsuccessful redelivery requests we drop the entry from
    // localStorage — the signatures are gone (server-side reconciliation
    // or genuine loss) and we'd otherwise pile up state forever.
    this._requestRetries = {}

    // Push current wallet state to server
    this._pushState()

    // Listen for cross-tab localStorage changes. Merge rather than
    // replace — replacing would clobber an in-flight blinding entry
    // we've already pushed to the server. Symptom is a DLEQ
    // verification failure when signatures come back and our
    // in-memory bPrime / r values no longer match what the server
    // signed. Adopt unseen quote_ids from storage; never overwrite
    // an entry our own tab already owns.
    this._onStorage = (e) => {
      if (e.key === BLINDING_KEY) {
        const fromStorage = readPendingBlinding()
        for (const [qid, state] of Object.entries(fromStorage)) {
          if (!(qid in this._blindingStates)) {
            this._blindingStates[qid] = state
          }
        }
      }
    }
    window.addEventListener("storage", this._onStorage)

    // On mount, ask the server to redeliver signatures for any deposits
    // that were blinded but never confirmed stored. The LiveView holds
    // signatures in `pending_signatures` until it receives our
    // `wallet:tokens_stored_ok` ACK.
    this._wasmReady.then(() => {
      this._requestPendingSignatures()
    })

    // Server tells us a pending deposit has been reconciled (orphaned
    // for too long, compensating burn written, signatures gone). Drop
    // the matching localStorage entry so we stop asking for it.
    this.handleEvent("wallet:quote_expired", ({ quote_id }) => {
      if (this._blindingStates[quote_id]) {
        console.warn(`Quote ${quote_id} expired server-side; dropping pending blinding state`)
        delete this._blindingStates[quote_id]
        delete this._requestRetries[quote_id]
        writePendingBlinding(this._blindingStates)
      }
    })

    // Server asks us to store newly minted tokens (legacy path — kept for compatibility)
    this.handleEvent("wallet:tokens_minted", ({ tokens }) => {
      const current = readTokens()
      const existingSecrets = new Set(current.map(t => t.secret))
      const fresh = tokens.filter(t => !existingSecrets.has(t.secret))
      const result = writeTokens(current.concat(fresh))
      if (!result.ok) {
        console.error("Token storage failed (legacy path) — tokens not persisted")
      }
      this._pushState()
    })

    // Server asks us to remove tokens by secret (after successful melt)
    this.handleEvent("wallet:tokens_removed", ({ secrets }) => {
      const secretSet = new Set(secrets)
      const current = readTokens()
      const remaining = current.filter(t => !secretSet.has(t.secret))
      const result = writeTokens(remaining)
      if (!result.ok) {
        console.error("Failed to remove spent tokens — wallet state may be inconsistent")
      }
      this._pushState()
    })

    // Server requests current state (e.g. on reconnect)
    this.handleEvent("wallet:request_state", () => {
      this._pushState()
    })

    // Server asks us to select tokens for a given amount (withdrawal)
    this.handleEvent("wallet:select_tokens", ({ amount }) => {
      const tokens = readTokens()
      const selected = this._selectTokens(tokens, amount)

      if (selected) {
        this.pushEvent("wallet:tokens_selected", { tokens: selected })
      } else {
        this.pushEvent("wallet:tokens_selected", { error: "insufficient_balance" })
      }
    })

    // Server asks for all tokens (backup export)
    this.handleEvent("wallet:request_all_tokens", () => {
      const tokens = readTokens()
      this.pushEvent("wallet:all_tokens", { tokens })
    })

    // Server sends verified tokens to store (restore flow)
    this.handleEvent("wallet:store_verified_tokens", ({ tokens }) => {
      const current = readTokens()
      // Deduplicate by secret
      const existingSecrets = new Set(current.map(t => t.secret))
      const newTokens = tokens.filter(t => !existingSecrets.has(t.secret))
      const merged = current.concat(newTokens)
      writeTokens(merged)
      this._pushState()
    })

    // Server asks us to send all secrets for spent-checking (after restore)
    this.handleEvent("wallet:request_spent_check", () => {
      const tokens = readTokens()
      const secrets = tokens.map(t => t.secret)
      this.pushEvent("wallet:spent_check", { secrets })
    })

    // Server pushes a new activity entry
    this.handleEvent("wallet:add_activity", (entry) => {
      const activities = readActivities()
      activities.unshift(entry)
      writeActivities(activities)
      this._pushState()
    })

    // --- Phase 2: Client-side blinding (WASM) ---

    // Server detected payment — send us keyset keys + amounts to blind
    this.handleEvent("wallet:payment_received", async (payload) => {
      const { quote_id, amounts, keyset_id, keyset_keys } = payload

      try {
        await this._wasmReady

        const items = []
        const blindedMessages = []

        for (const amount of amounts) {
          // Generate secret and blinding factor via browser CSPRNG
          const secret = new Uint8Array(32)
          const r = new Uint8Array(32)
          crypto.getRandomValues(secret)
          crypto.getRandomValues(r)

          // Blind: B' = hash_to_curve(secret) + r*G
          const bPrime = cashew.step1Alice(secret, r)

          items.push({ amount, secret, r, bPrime })
          blindedMessages.push({
            amount,
            b_prime: cashew.toHex(bPrime)
          })
        }

        // Persist blinding state per quote_id BEFORE sending to server,
        // so a crash between blind and sign doesn't strand the deposit.
        // If the persist fails (quota exhausted), bail out — pushing
        // blinded messages without durable state would risk the same
        // signature-loss bug this flow exists to prevent.
        this._blindingStates[quote_id] = { keyset_id, keyset_keys, items }
        const persisted = writePendingBlinding(this._blindingStates)
        if (!persisted.ok) {
          delete this._blindingStates[quote_id]
          const reason = "client_storage_quota_exceeded"
          this.pushEvent("wallet:tokens_stored_failed", {
            quote_id,
            reason,
            diagnostic: this._buildDiagnostic(quote_id, reason, {
              keyset_id: keyset_id ?? null,
              item_count: items.length
            })
          })
          return
        }

        // Send blinded messages to server for signing
        this.pushEvent("wallet:blinded_messages", {
          quote_id,
          blinded_messages: blindedMessages
        })
      } catch (e) {
        console.error("Blinding failed:", e)
      }
    })

    // Server returns blind signatures — unblind, store, and ACK.
    // The activity log entry on the server is gated on this ACK so a
    // failed unblinding never leaves a phantom "tokens minted" entry.
    this.handleEvent("wallet:blind_signatures", async (payload) => {
      const { quote_id, signatures } = payload

      const failAndKeepState = (reason) => {
        console.error(`Unblinding failed (${reason}) for quote ${quote_id} — state retained for retry`)
        const st = this._blindingStates[quote_id]
        const items = st?.items
        this.pushEvent("wallet:tokens_stored_failed", {
          quote_id,
          reason,
          diagnostic: this._buildDiagnostic(quote_id, reason, {
            keyset_id: st?.keyset_id ?? null,
            item_count: Array.isArray(items) ? items.length : 0,
            items_with_secret: countWhere(items, it => it?.secret?.length > 0),
            items_with_r: countWhere(items, it => it?.r?.length > 0),
            items_with_b_prime: countWhere(items, it => it?.bPrime?.length > 0),
            sig_count: Array.isArray(signatures) ? signatures.length : -1,
            sigs_with_c_prime: countWhere(signatures, s => typeof s?.c_prime === "string" && s.c_prime.length > 0),
            sigs_with_dleq: countWhere(signatures, s => !!s?.dleq)
          })
        })
      }

      try {
        await this._wasmReady

        const state = this._blindingStates[quote_id]
        if (!state) {
          failAndKeepState("no_blinding_state")
          return
        }

        if (!Array.isArray(signatures) || signatures.length !== state.items.length) {
          failAndKeepState("signature_count_mismatch")
          return
        }

        const tokens = []

        for (let i = 0; i < signatures.length; i++) {
          const sig = signatures[i]
          const item = state.items[i]

          const mintPkHex = state.keyset_keys[String(item.amount)]
          if (!mintPkHex) {
            failAndKeepState(`no_pubkey_for_amount_${item.amount}`)
            return
          }

          const mintPk = cashew.fromHex(mintPkHex)
          const cPrime = cashew.fromHex(sig.c_prime)
          const c = cashew.step3Alice(cPrime, item.r, mintPk)

          if (sig.dleq) {
            const e = cashew.fromHex(sig.dleq.e)
            const s = cashew.fromHex(sig.dleq.s)
            if (!cashew.verifyDleqProof(mintPk, item.bPrime, cPrime, e, s)) {
              failAndKeepState(`dleq_verification_failed_index_${i}`)
              return
            }
          }

          tokens.push({
            amount: item.amount,
            secret: cashew.toHex(item.secret),
            C: cashew.toHex(c),
            id: state.keyset_id
          })
        }

        // Persist tokens BEFORE clearing the pending blinding state so a
        // crash between the two leaves the secrets recoverable. Dedup
        // by secret on append — replayed signatures (e.g. after a
        // server-side request_signatures retry that races with the
        // user's first successful unblind) would otherwise create
        // duplicate entries that waste one copy on melt.
        const current = readTokens()
        const existingSecrets = new Set(current.map(t => t.secret))
        const fresh = tokens.filter(t => !existingSecrets.has(t.secret))
        const tokensWritten = writeTokens(current.concat(fresh))
        if (!tokensWritten.ok) {
          failAndKeepState("token_write_failed")
          return
        }

        delete this._blindingStates[quote_id]
        delete this._requestRetries[quote_id]
        const blindingPersisted = writePendingBlinding(this._blindingStates)
        if (!blindingPersisted.ok) {
          // Tokens are durably stored; pending blinding cleanup failed.
          // The stale entry is harmless (its tokens are now in the
          // wallet, secret-dedup blocks any redelivery from re-adding)
          // but log so debugging is possible.
          console.warn(`Pending blinding cleanup failed for ${quote_id}; entry will resolve on next clean write`)
        }

        this._pushState()
        this.pushEvent("wallet:tokens_stored_ok", { quote_id })
      } catch (e) {
        // Generic unhandled failure — keep state, surface to server.
        failAndKeepState(e?.message || "unknown")
      }
    })
  },

  reconnected() {
    // Re-push WASM status on LiveView reconnect (e.g. after deploy)
    if (this._wasmReady) {
      this._wasmReady.then(() => {
        this.pushEvent("wallet:wasm_status", { status: "ready" })
        this._requestPendingSignatures()
      })
    }
  },

  destroyed() {
    if (this._onStorage) {
      window.removeEventListener("storage", this._onStorage)
    }
  },

  // Asks the server to redeliver signatures for any pending quote we
  // haven't finished. After MAX_REQUEST_RETRIES unsuccessful attempts
  // we drop the entry — the server has either reconciled it or genuinely
  // lost it, and we'd otherwise spam request events forever on every
  // mount/reconnect.
  _requestPendingSignatures() {
    const MAX_REQUEST_RETRIES = 5
    const dropped = []

    for (const quote_id of Object.keys(this._blindingStates || {})) {
      const retries = (this._requestRetries[quote_id] || 0) + 1
      if (retries > MAX_REQUEST_RETRIES) {
        console.warn(`Quote ${quote_id} exceeded retry limit; dropping pending blinding state`)
        // Surface the drop before it happens — this is the last moment
        // the failure has a client-side context to report from.
        const reason = "redelivery_exhausted"
        const st = this._blindingStates[quote_id]
        this.pushEvent("wallet:tokens_stored_failed", {
          quote_id,
          reason,
          diagnostic: this._buildDiagnostic(quote_id, reason, {
            keyset_id: st?.keyset_id ?? null,
            item_count: Array.isArray(st?.items) ? st.items.length : 0,
            retries: retries - 1
          })
        })
        delete this._blindingStates[quote_id]
        delete this._requestRetries[quote_id]
        dropped.push(quote_id)
        continue
      }

      this._requestRetries[quote_id] = retries
      this.pushEvent("wallet:request_signatures", { quote_id })
    }

    if (dropped.length > 0) {
      writePendingBlinding(this._blindingStates)
    }
  },

  // Field-presence snapshot attached to failure reports. Counts and
  // status strings only — never secrets, blinding factors, or proofs —
  // so the resulting blob is safe to paste in public channels.
  _buildDiagnostic(quote_id, reason, extra = {}) {
    return {
      reason,
      quote_id,
      at: new Date().toISOString(),
      wasm: this._wasmStatus,
      ua: navigator.userAgent,
      ...extra
    }
  },

  // Greedy largest-first token selection
  _selectTokens(tokens, amount) {
    const sorted = [...tokens].sort((a, b) => b.amount - a.amount)
    const selected = []
    let total = 0

    for (const t of sorted) {
      if (total >= amount) break
      selected.push(t)
      total += t.amount
    }

    return total >= amount ? selected : null
  },

  _pushState() {
    const tokens = readTokens()
    const state = computeState(tokens)
    const activities = readActivities()
    state.activities = activities

    // Flash balance on change
    if (this._lastBalance !== undefined && this._lastBalance !== state.balance) {
      const el = document.querySelector(".mt-balance-amount")
      if (el) {
        el.classList.remove("mt-balance-flash")
        void el.offsetWidth // force reflow to restart animation
        el.classList.add("mt-balance-flash")
      }
    }
    this._lastBalance = state.balance

    this.pushEvent("wallet:state", state)
  }
}

export default WalletBridge
