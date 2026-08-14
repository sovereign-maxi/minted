// Thin JS wrapper around the nutty WASM module (Alice-side BDHKE).
//
// Loads .wasm via fetch + WebAssembly.instantiateStreaming (no wasm-bindgen).
// Manages WASM linear memory: alloc/dealloc/copy bytes in and out.

let wasm = null

export async function init() {
  if (wasm) return
  const response = fetch("/assets/nutty.wasm")
  const { instance } = await WebAssembly.instantiateStreaming(response, {})
  wasm = instance.exports
}

// --- Hex utilities ---

export function toHex(bytes) {
  let hex = ""
  for (let i = 0; i < bytes.length; i++) {
    hex += bytes[i].toString(16).padStart(2, "0")
  }
  return hex
}

export function fromHex(hex) {
  if (typeof hex !== "string") {
    throw new TypeError(`fromHex expects a string, got ${typeof hex}`)
  }
  if (hex.length % 2 !== 0) {
    throw new Error(`fromHex: odd-length input (length=${hex.length})`)
  }
  if (!/^[0-9a-fA-F]*$/.test(hex)) {
    throw new Error("fromHex: non-hex character in input")
  }
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.substr(i * 2, 2), 16)
  }
  return bytes
}

// --- WASM memory helpers ---

function writeToWasm(data) {
  const ptr = wasm.alloc(data.length)
  if (!ptr) throw new Error("WASM alloc failed")
  new Uint8Array(wasm.memory.buffer, ptr, data.length).set(data)
  return { ptr, len: data.length }
}

function readFromWasm(ptr, len) {
  return new Uint8Array(wasm.memory.buffer, ptr, len).slice()
}

function freeWasm(ptr, len) {
  wasm.dealloc(ptr, len)
}

// --- Crypto operations ---

/**
 * BDHKE Step 1 (Alice): Blind a secret.
 * B' = hash_to_curve(secret) + r * G
 *
 * @param {Uint8Array} secret - Token secret (any length, typically 32 bytes)
 * @param {Uint8Array} r - 32-byte blinding factor from crypto.getRandomValues()
 * @returns {Uint8Array} 33-byte compressed B' (blinded message)
 */
export function step1Alice(secret, r) {
  const secretMem = writeToWasm(secret)
  const rMem = writeToWasm(r)
  const outPtr = wasm.alloc(33)

  try {
    const rc = wasm.step1_alice(secretMem.ptr, secretMem.len, rMem.ptr, outPtr)
    if (rc !== 0) throw new Error(`step1_alice failed: ${rc}`)
    return readFromWasm(outPtr, 33)
  } finally {
    freeWasm(secretMem.ptr, secretMem.len)
    freeWasm(rMem.ptr, rMem.len)
    freeWasm(outPtr, 33)
  }
}

/**
 * BDHKE Step 3 (Alice): Unblind a signature.
 * C = C' - r * K
 *
 * @param {Uint8Array} cPrime - 33-byte compressed blind signature from mint
 * @param {Uint8Array} r - 32-byte blinding factor from step 1
 * @param {Uint8Array} mintPk - 33-byte compressed mint public key
 * @returns {Uint8Array} 33-byte compressed C (unblinded signature)
 */
export function step3Alice(cPrime, r, mintPk) {
  const cpMem = writeToWasm(cPrime)
  const rMem = writeToWasm(r)
  const pkMem = writeToWasm(mintPk)
  const outPtr = wasm.alloc(33)

  try {
    const rc = wasm.step3_alice(cpMem.ptr, rMem.ptr, pkMem.ptr, outPtr)
    if (rc !== 0) throw new Error(`step3_alice failed: ${rc}`)
    return readFromWasm(outPtr, 33)
  } finally {
    freeWasm(cpMem.ptr, cpMem.len)
    freeWasm(rMem.ptr, rMem.len)
    freeWasm(pkMem.ptr, pkMem.len)
    freeWasm(outPtr, 33)
  }
}

/**
 * Verify a NUT-12 DLEQ proof on a blind signature.
 *
 * @param {Uint8Array} pk - 33-byte compressed mint public key
 * @param {Uint8Array} bPrime - 33-byte compressed blinded message B'
 * @param {Uint8Array} cPrime - 33-byte compressed blind signature C'
 * @param {Uint8Array} e - 32-byte DLEQ challenge
 * @param {Uint8Array} s - 32-byte DLEQ response
 * @returns {boolean} true if valid
 */
export function verifyDleqProof(pk, bPrime, cPrime, e, s) {
  const pkMem = writeToWasm(pk)
  const bpMem = writeToWasm(bPrime)
  const cpMem = writeToWasm(cPrime)
  const eMem = writeToWasm(e)
  const sMem = writeToWasm(s)

  try {
    const rc = wasm.verify_dleq(pkMem.ptr, bpMem.ptr, cpMem.ptr, eMem.ptr, sMem.ptr)
    return rc === 0
  } finally {
    freeWasm(pkMem.ptr, pkMem.len)
    freeWasm(bpMem.ptr, bpMem.len)
    freeWasm(cpMem.ptr, cpMem.len)
    freeWasm(eMem.ptr, eMem.len)
    freeWasm(sMem.ptr, sMem.len)
  }
}
