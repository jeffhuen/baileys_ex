import { mkdirSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { makeLibSignalRepository } from '../reference/Baileys-master/src/Signal/libsignal.ts'
import { LIDMappingStore } from '../reference/Baileys-master/src/Signal/lid-mapping.ts'
import { GroupCipher } from '../reference/Baileys-master/src/Signal/Group/group_cipher.ts'
import { GroupSessionBuilder } from '../reference/Baileys-master/src/Signal/Group/group-session-builder.ts'
import { SenderKeyDistributionMessage } from '../reference/Baileys-master/src/Signal/Group/sender-key-distribution-message.ts'
import { SenderKeyName } from '../reference/Baileys-master/src/Signal/Group/sender-key-name.ts'
import { SenderKeyRecord } from '../reference/Baileys-master/src/Signal/Group/sender-key-record.ts'

type KeyFamily = string
type KeyValue = Uint8Array | string | null | undefined
type KeyUpdates = Record<string, KeyValue>

class MemoryKeys {
	private readonly families = new Map<KeyFamily, Map<string, KeyValue>>()
	private transactionDepth = 0

	async get(type: KeyFamily, ids: Array<string | number>) {
		const family = this.family(type)
		return Object.fromEntries(ids.map(id => [String(id), family.get(String(id))]))
	}

	async set(data: Record<string, KeyUpdates>) {
		for (const [type, updates] of Object.entries(data)) {
			const family = this.family(type)
			for (const [id, value] of Object.entries(updates)) {
				if (value == null) {
					family.delete(id)
				} else {
					family.set(id, value)
				}
			}
		}
	}

	async transaction<T>(work: () => Promise<T>, _key?: string) {
		this.transactionDepth += 1

		try {
			return await work()
		} finally {
			this.transactionDepth -= 1
		}
	}

	isInTransaction() {
		return this.transactionDepth > 0
	}

	private family(type: KeyFamily) {
		let family = this.families.get(type)
		if (!family) {
			family = new Map()
			this.families.set(type, family)
		}

		return family
	}
}

class MemorySenderKeyStore {
	private readonly records = new Map<string, SenderKeyRecord>()

	async loadSenderKey(senderKeyName: SenderKeyName) {
		return this.records.get(senderKeyName.toString()) ?? new SenderKeyRecord()
	}

	async storeSenderKey(senderKeyName: SenderKeyName, record: SenderKeyRecord) {
		this.records.set(senderKeyName.toString(), record)
	}
}

const silentLogger = {
	trace() {},
	debug() {},
	info() {},
	warn() {},
	error() {}
}

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)
const fixturePath = resolve(__dirname, '../../test/fixtures/signal/baileys_v7.json')
const requireFromReference = createRequire(resolve(__dirname, '../reference/Baileys-master/package.json'))
const libsignal = requireFromReference('libsignal')
const libsignalCurve = requireFromReference('libsignal/src/curve')

type DirectKeyPair = {
	public: Buffer
	private: Buffer
	signalPublic: Buffer
}

type StoredPreKey = {
	privKey: Buffer
	pubKey: Buffer
}

class DirectMessageStorage {
	private readonly sessions = new Map<string, any>()

	constructor(
		private readonly opts: {
			identityKeyPair: DirectKeyPair
			registrationId: number
			signedPreKeyPair: DirectKeyPair & { keyId: number }
			preKeyPairs?: Map<string, StoredPreKey>
		}
	) {}

	async loadSession(id: string) {
		return this.sessions.get(id)
	}

	async storeSession(id: string, record: any) {
		this.sessions.set(id, record)
	}

	async isTrustedIdentity() {
		return true
	}

	async loadIdentityKey() {
		return undefined
	}

	async saveIdentity() {
		return false
	}

	async loadPreKey(id: string | number) {
		return this.opts.preKeyPairs?.get(String(id))
	}

	async removePreKey(id: string | number) {
		this.opts.preKeyPairs?.delete(String(id))
	}

	async loadSignedPreKey(id: string | number) {
		if (Number(id) !== this.opts.signedPreKeyPair.keyId) {
			return undefined
		}

		return toLibsignalKeyPair(this.opts.signedPreKeyPair)
	}

	async getOurRegistrationId() {
		return this.opts.registrationId
	}

	async getOurIdentity() {
		return toLibsignalKeyPair(this.opts.identityKeyPair)
	}
}

function toBase64(value: Uint8Array | Buffer) {
	return Buffer.from(value).toString('base64')
}

function directKeyPair(seed: number): DirectKeyPair {
	const privateKey = Buffer.alloc(32)
	privateKey.writeUInt32BE(seed, 28)

	const signalPublic = Buffer.from(libsignalCurve.getPublicFromPrivateKey(privateKey))

	return {
		public: signalPublic.subarray(1),
		private: Buffer.from(privateKey),
		signalPublic
	}
}

function toFixtureKeyPair(keyPair: DirectKeyPair) {
	return {
		public: toBase64(keyPair.public),
		private: toBase64(keyPair.private)
	}
}

function toLibsignalKeyPair(keyPair: DirectKeyPair): StoredPreKey {
	return {
		privKey: Buffer.from(keyPair.private),
		pubKey: Buffer.from(keyPair.signalPublic)
	}
}

async function withQueuedSignalKeyPairs<T>(queue: DirectKeyPair[], work: () => Promise<T>) {
	const originalGenerateKeyPair = libsignalCurve.generateKeyPair

	libsignalCurve.generateKeyPair = () => {
		const next = queue.shift()
		if (!next) {
			throw new Error('libsignal key queue exhausted')
		}

		return toLibsignalKeyPair(next)
	}

	try {
		return await work()
	} finally {
		libsignalCurve.generateKeyPair = originalGenerateKeyPair
	}
}

function protocolAddress(address: string) {
	const separatorIndex = address.lastIndexOf('.')
	const id = address.slice(0, separatorIndex)
	const deviceId = Number.parseInt(address.slice(separatorIndex + 1), 10)

	return {
		id,
		deviceId,
		toString() {
			return `${id}.${deviceId}`
		}
	}
}

function createRepository() {
	const keys = new MemoryKeys()
	const auth = { creds: {}, keys } as any
	const repository = makeLibSignalRepository(auth, silentLogger as any)

	return { keys, repository }
}

async function buildAddressFixtures() {
	const { repository } = createRepository()

	const jids = [
		'5511999887766@s.whatsapp.net',
		'5511999887766:2@s.whatsapp.net',
		'12345_128@s.whatsapp.net',
		'12345_128:3@c.us',
		'abc123@lid',
		'user:99@hosted',
		'user:99@hosted.lid',
		'user:99@s.whatsapp.net'
	]

	return jids.map(jid => {
		try {
			return { jid, signal_address: repository.jidToSignalProtocolAddress(jid) }
		} catch {
			return { jid, error: true }
		}
	})
}

async function buildLidMappingFixtures() {
	const keys = new MemoryKeys()
	const store = new LIDMappingStore(keys as any, silentLogger as any)
	const storedPairs = [{ lid: '12345@lid', pn: '5511999887766@s.whatsapp.net' }]

	await store.storeLIDPNMappings(storedPairs)

	const forwardPns = [
		'5511999887766@s.whatsapp.net',
		'5511999887766:2@s.whatsapp.net',
		'5511999887766:99@hosted'
	]

	const reverseLids = ['12345@lid', '12345:2@lid', '12345:99@lid', '12345:99@hosted.lid']

	return {
		stored_pairs: storedPairs,
		forward_lookups: await Promise.all(
			forwardPns.map(async pn => ({ pn, lid: await store.getLIDForPN(pn) }))
		),
		reverse_lookups: await Promise.all(
			reverseLids.map(async lid => ({ lid, pn: await store.getPNForLID(lid) }))
		)
	}
}

async function buildSenderKeyFixtures() {
	const { repository } = createRepository()
	const group = '120363001234567890@g.us'
	const authorJid = '5511999887766:3@s.whatsapp.net'
	const authorAddress = repository.jidToSignalProtocolAddress(authorJid)
	const sender = protocolAddress(authorAddress)
	const senderKeyName = new SenderKeyName(group, sender)

	const keyId = 1729
	const iteration = 0
	const chainKey = Buffer.from('00112233445566778899aabbccddeefffedcba98765432100123456789abcdef', 'hex')
	const signingPrivateKey = Buffer.from('AAIcmaF2D5rTsgGZo9h4oqGa393qFKjilfMfUDqr8G8=', 'base64')
	const signingPublicKey = Buffer.from('BYBnBY4toVNm9NPplrAdbCEr09r7ZvolG0erkS7zMnBY', 'base64')

	const distribution = new SenderKeyDistributionMessage(keyId, iteration, chainKey, signingPublicKey)
	const distributionBytes = Buffer.from(distribution.serialize())

	const senderStore = new MemorySenderKeyStore()
	const senderRecord = new SenderKeyRecord()
	senderRecord.setSenderKeyState(keyId, iteration, chainKey, {
		public: signingPublicKey,
		private: signingPrivateKey
	})
	await senderStore.storeSenderKey(senderKeyName, senderRecord)

	const senderCipher = new GroupCipher(senderStore as any, senderKeyName)
	const plaintexts = [Buffer.from('fixture-one'), Buffer.from('fixture-two'), Buffer.from('fixture-three')]
	const messages = []

	for (const plaintext of plaintexts) {
		const ciphertext = await senderCipher.encrypt(plaintext)
		messages.push({
			plaintext: toBase64(plaintext),
			ciphertext: toBase64(ciphertext)
		})
	}

	const recipientStore = new MemorySenderKeyStore()
	const builder = new GroupSessionBuilder(recipientStore as any)
	await recipientStore.storeSenderKey(senderKeyName, new SenderKeyRecord())
	await builder.process(
		senderKeyName,
		new SenderKeyDistributionMessage(null, null, null, null, distributionBytes)
	)

	const recipientCipher = new GroupCipher(recipientStore as any, senderKeyName)
	for (const index of [1, 0, 2]) {
		const ciphertext = Buffer.from(messages[index]!.ciphertext, 'base64')
		await recipientCipher.decrypt(ciphertext)
	}

	return {
		group,
		author_jid: authorJid,
		sender_key_name: senderKeyName.serialize(),
		state: {
			key_id: keyId,
			iteration,
			chain_key: toBase64(chainKey),
			signing_private_key: toBase64(signingPrivateKey),
			signing_public_key: toBase64(signingPublicKey)
		},
		distribution_message: toBase64(distributionBytes),
		messages,
		decrypt_order: [1, 0, 2]
	}
}

async function buildDirectMessageFixtures() {
	const aliceIdentity = directKeyPair(1001)
	const aliceBaseKey = directKeyPair(1002)
	const aliceSendingRatchet = directKeyPair(1003)
	const aliceNextRatchet = directKeyPair(1004)

	const bobIdentity = directKeyPair(2001)
	const bobSignedPreKey = directKeyPair(2002)
	const bobPreKey = directKeyPair(2003)
	const bobReplyRatchet = directKeyPair(2004)

	const aliceRegistrationId = 1234
	const bobRegistrationId = 5678
	const bobSignedPreKeyId = 77
	const bobPreKeyId = 88

	const signedPreKeySignature = Buffer.from(
		libsignalCurve.calculateSignature(bobIdentity.private, bobSignedPreKey.signalPublic)
	)

	const aliceStorage = new DirectMessageStorage({
		identityKeyPair: aliceIdentity,
		registrationId: aliceRegistrationId,
		signedPreKeyPair: { ...aliceIdentity, keyId: 1 }
	})

	const bobStorage = new DirectMessageStorage({
		identityKeyPair: bobIdentity,
		registrationId: bobRegistrationId,
		signedPreKeyPair: { ...bobSignedPreKey, keyId: bobSignedPreKeyId },
		preKeyPairs: new Map([[String(bobPreKeyId), toLibsignalKeyPair(bobPreKey)]])
	})

	const alicePlaintext = Buffer.from('hello from alice')
	const bobPlaintext = Buffer.from('hello from bob')

	const aliceAddress = new libsignal.ProtocolAddress('alice', 0)
	const bobAddress = new libsignal.ProtocolAddress('bob', 0)

	await withQueuedSignalKeyPairs([aliceBaseKey, aliceSendingRatchet], async () => {
		const aliceBuilder = new libsignal.SessionBuilder(aliceStorage as any, bobAddress)

		await aliceBuilder.initOutgoing({
			identityKey: bobIdentity.signalPublic,
			registrationId: bobRegistrationId,
			signedPreKey: {
				keyId: bobSignedPreKeyId,
				publicKey: bobSignedPreKey.signalPublic,
				signature: signedPreKeySignature
			},
			preKey: {
				keyId: bobPreKeyId,
				publicKey: bobPreKey.signalPublic
			}
		})
	})

	const aliceCipher = new libsignal.SessionCipher(aliceStorage as any, bobAddress)
	const aliceToBob = await aliceCipher.encrypt(alicePlaintext)

	const bobCipher = new libsignal.SessionCipher(bobStorage as any, aliceAddress)

	const decryptedAlicePlaintext = await withQueuedSignalKeyPairs([bobReplyRatchet], async () =>
		bobCipher.decryptPreKeyWhisperMessage(Buffer.from(aliceToBob.body))
	)

	if (Buffer.compare(Buffer.from(decryptedAlicePlaintext), alicePlaintext) !== 0) {
		throw new Error('direct-message fixture sanity check failed for Alice -> Bob decrypt')
	}

	const bobToAlice = await bobCipher.encrypt(bobPlaintext)

	const decryptedBobPlaintext = await withQueuedSignalKeyPairs([aliceNextRatchet], async () =>
		aliceCipher.decryptWhisperMessage(Buffer.from(bobToAlice.body))
	)

	if (Buffer.compare(Buffer.from(decryptedBobPlaintext), bobPlaintext) !== 0) {
		throw new Error('direct-message fixture sanity check failed for Bob -> Alice decrypt')
	}

	return {
		alice: {
			registration_id: aliceRegistrationId,
			identity_key: toFixtureKeyPair(aliceIdentity),
			base_key: toFixtureKeyPair(aliceBaseKey),
			sending_ratchet: toFixtureKeyPair(aliceSendingRatchet),
			next_ratchet: toFixtureKeyPair(aliceNextRatchet)
		},
		bob: {
			registration_id: bobRegistrationId,
			identity_key: toFixtureKeyPair(bobIdentity),
			signed_pre_key_id: bobSignedPreKeyId,
			signed_pre_key: toFixtureKeyPair(bobSignedPreKey),
			pre_key_id: bobPreKeyId,
			pre_key: toFixtureKeyPair(bobPreKey),
			reply_ratchet: toFixtureKeyPair(bobReplyRatchet)
		},
		messages: {
			alice_to_bob: {
				plaintext: toBase64(alicePlaintext),
				ciphertext: toBase64(Buffer.from(aliceToBob.body))
			},
			bob_to_alice: {
				plaintext: toBase64(bobPlaintext),
				ciphertext: toBase64(Buffer.from(bobToAlice.body))
			}
		}
	}
}

async function main() {
	const fixture = {
		meta: {
			source: 'dev/reference/Baileys-master',
			baileys_version: '7.0.0-rc.9',
			scope: [
				'jidToSignalProtocolAddress parity',
				'LID mapping forward/reverse parity',
				'sender-key distribution and group cipher parity',
				'1:1 Signal session and ciphertext parity'
			]
		},
		addresses: await buildAddressFixtures(),
		lid_mapping: await buildLidMappingFixtures(),
		sender_key: await buildSenderKeyFixtures(),
		direct_message: await buildDirectMessageFixtures()
	}

	mkdirSync(dirname(fixturePath), { recursive: true })
	writeFileSync(fixturePath, JSON.stringify(fixture, null, 2) + '\n')
}

await main()
