// Generate cross-language test vectors for Syncd protocol parity testing.
// Outputs JSON with hex-encoded binaries that Elixir tests can pin against.
//
// Usage: node dev/scripts/generate_syncd_vectors.mjs

import { createHmac, hkdf as nodeHkdf } from 'node:crypto'
import { createHash } from 'node:crypto'

// ============================================================================
// 1. HKDF Key Expansion vectors
// ============================================================================

// Matches Baileys expandAppStateKeys: HKDF-SHA256, salt=empty, info="WhatsApp Mutation Keys", len=160
async function generateHkdfVectors() {
  const keyData = Buffer.alloc(32, 0xAB)

  const expanded = await new Promise((resolve, reject) => {
    nodeHkdf('sha256', keyData, Buffer.alloc(0), 'WhatsApp Mutation Keys', 160, (err, key) => {
      if (err) reject(err)
      else resolve(Buffer.from(key))
    })
  })

  return {
    input_hex: keyData.toString('hex'),
    expanded_hex: expanded.toString('hex'),
    index_key_hex: expanded.subarray(0, 32).toString('hex'),
    value_encryption_key_hex: expanded.subarray(32, 64).toString('hex'),
    value_mac_key_hex: expanded.subarray(64, 96).toString('hex'),
    snapshot_mac_key_hex: expanded.subarray(96, 128).toString('hex'),
    patch_mac_key_hex: expanded.subarray(128, 160).toString('hex'),
  }
}

// ============================================================================
// 2. MAC Generation vectors
// ============================================================================

function hmacSign(buffer, key, variant = 'sha256') {
  return createHmac(variant, key).update(buffer).digest()
}

function generateMac(operation, data, keyId, key) {
  const opByte = operation === 0 ? 0x01 : 0x02  // SET=0→0x01, REMOVE=1→0x02
  const keyIdBuffer = Buffer.from(keyId)
  const keyData = Buffer.alloc(1 + keyIdBuffer.length)
  keyData[0] = opByte
  keyIdBuffer.copy(keyData, 1)

  const last = Buffer.alloc(8)
  last[7] = keyData.length

  const total = Buffer.concat([keyData, data, last])
  const hmac = hmacSign(total, key, 'sha512')
  return hmac.subarray(0, 32)
}

function to64BitNetworkOrder(e) {
  const buff = Buffer.alloc(8)
  buff.writeUInt32BE(e, 4)
  return buff
}

function generateSnapshotMac(lthash, version, name, key) {
  const total = Buffer.concat([lthash, to64BitNetworkOrder(version), Buffer.from(name, 'utf-8')])
  return hmacSign(total, key, 'sha256')
}

function generatePatchMac(snapshotMac, valueMacs, version, type, key) {
  const total = Buffer.concat([snapshotMac, ...valueMacs, to64BitNetworkOrder(version), Buffer.from(type, 'utf-8')])
  return hmacSign(total, key, 'sha256')
}

function generateMacVectors(keys) {
  const data = Buffer.from('test payload')
  const keyId = Buffer.from([1, 2, 3, 4])

  // Value MAC (SET)
  const valueMacSet = generateMac(0, data, keyId, Buffer.from(keys.value_mac_key_hex, 'hex'))

  // Value MAC (REMOVE)
  const valueMacRemove = generateMac(1, data, keyId, Buffer.from(keys.value_mac_key_hex, 'hex'))

  // Snapshot MAC
  const lthash = Buffer.alloc(128)
  const snapshotMac = generateSnapshotMac(
    lthash, 1, 'regular_high',
    Buffer.from(keys.snapshot_mac_key_hex, 'hex')
  )

  // Patch MAC
  const patchMac = generatePatchMac(
    snapshotMac, [valueMacSet], 1, 'regular_high',
    Buffer.from(keys.patch_mac_key_hex, 'hex')
  )

  return {
    data_hex: data.toString('hex'),
    key_id_hex: keyId.toString('hex'),
    value_mac_set_hex: valueMacSet.toString('hex'),
    value_mac_remove_hex: valueMacRemove.toString('hex'),
    snapshot_mac_hex: snapshotMac.toString('hex'),
    patch_mac_hex: patchMac.toString('hex'),
  }
}

// ============================================================================
// 3. LTHash vectors
// ============================================================================

// The LTHash algorithm from whatsapp-rust-bridge expands each 32-byte valueMac
// to 128 bytes via SHA-256(i || valueMac) for i=0..3, then treats the state
// and expansion as arrays of 64 uint16 LE values with wrapping arithmetic.
function ltHashExpand(buf) {
  const parts = []
  for (let i = 0; i < 4; i++) {
    const hash = createHash('sha256').update(Buffer.from([i])).update(buf).digest()
    parts.push(hash)
  }
  return Buffer.concat(parts)
}

function ltHashSubtractThenAdd(hash, subBuffs, addBuffs) {
  const state = new Uint16Array(64)
  for (let i = 0; i < 64; i++) {
    state[i] = hash.readUInt16LE(i * 2)
  }

  for (const buf of subBuffs) {
    const expanded = ltHashExpand(buf)
    for (let i = 0; i < 64; i++) {
      state[i] = (state[i] - expanded.readUInt16LE(i * 2)) & 0xFFFF
    }
  }

  for (const buf of addBuffs) {
    const expanded = ltHashExpand(buf)
    for (let i = 0; i < 64; i++) {
      state[i] = (state[i] + expanded.readUInt16LE(i * 2)) & 0xFFFF
    }
  }

  const result = Buffer.alloc(128)
  for (let i = 0; i < 64; i++) {
    result.writeUInt16LE(state[i], i * 2)
  }
  return result
}

function generateLtHashVectors() {
  const macA = createHash('sha256').update('value_mac_a').digest()
  const macB = createHash('sha256').update('value_mac_b').digest()
  const zeroHash = Buffer.alloc(128)

  // Add single value to zero hash
  const afterAddA = ltHashSubtractThenAdd(zeroHash, [], [macA])

  // Add two values
  const afterAddAB = ltHashSubtractThenAdd(zeroHash, [], [macA, macB])

  // Add A then subtract A (should return to zero)
  const afterAddSubA = ltHashSubtractThenAdd(afterAddA, [macA], [])

  // Replace A with B
  const afterReplace = ltHashSubtractThenAdd(afterAddA, [macA], [macB])

  return {
    mac_a_hex: macA.toString('hex'),
    mac_b_hex: macB.toString('hex'),
    after_add_a_hex: afterAddA.toString('hex'),
    after_add_ab_hex: afterAddAB.toString('hex'),
    after_add_sub_a_hex: afterAddSubA.toString('hex'),
    after_replace_a_with_b_hex: afterReplace.toString('hex'),
  }
}

// ============================================================================
// 4. Protobuf serialization vectors
// ============================================================================

async function generateProtoVectors() {
  // Use the WAProto from Baileys reference
  const { proto } = await import('../../dev/reference/Baileys-master/WAProto/index.js')

  // SyncdMutation with SET operation
  const mutation = proto.SyncdMutation.encode({
    operation: proto.SyncdMutation.SyncdOperation.SET,
    record: {
      index: { blob: Buffer.alloc(32, 0x11) },
      value: { blob: Buffer.alloc(64, 0x22) },
      keyId: { id: Buffer.from([1, 2, 3, 4]) },
    }
  }).finish()

  // SyncActionData with mute action
  const syncActionData = proto.SyncActionData.encode({
    index: Buffer.from('["mute","user@s.whatsapp.net"]'),
    value: {
      timestamp: 1710000000,
      muteAction: { muted: true, muteEndTimestamp: 1710086400 }
    },
    padding: Buffer.alloc(0),
    version: 2,
  }).finish()

  // SyncdPatch
  const patch = proto.SyncdPatch.encode({
    version: { version: 42 },
    mutations: [{
      operation: proto.SyncdMutation.SyncdOperation.SET,
      record: {
        index: { blob: Buffer.alloc(32, 0xAA) },
        value: { blob: Buffer.alloc(64, 0xBB) },
        keyId: { id: Buffer.from([5, 6, 7]) },
      }
    }],
    snapshotMac: Buffer.alloc(32, 0xCC),
    patchMac: Buffer.alloc(32, 0xDD),
    keyId: { id: Buffer.from([8, 9]) },
  }).finish()

  return {
    mutation_hex: Buffer.from(mutation).toString('hex'),
    sync_action_data_hex: Buffer.from(syncActionData).toString('hex'),
    patch_hex: Buffer.from(patch).toString('hex'),
  }
}

// ============================================================================
// Main
// ============================================================================

async function main() {
  const hkdf = await generateHkdfVectors()
  const mac = generateMacVectors(hkdf)
  const ltHash = generateLtHashVectors()

  let protoVectors = null
  try {
    protoVectors = await generateProtoVectors()
  } catch (e) {
    console.error('Proto vector generation failed (WAProto not loadable):', e.message)
  }

  const vectors = {
    hkdf,
    mac,
    lt_hash: ltHash,
    proto: protoVectors,
  }

  console.log(JSON.stringify(vectors, null, 2))
}

main().catch(console.error)
