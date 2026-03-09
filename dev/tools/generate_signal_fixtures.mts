import { mkdirSync, writeFileSync } from 'node:fs'
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

function toBase64(value: Uint8Array | Buffer) {
	return Buffer.from(value).toString('base64')
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

async function main() {
	const fixture = {
		meta: {
			source: 'dev/reference/Baileys-master',
			baileys_version: '7.0.0-rc.9',
			scope: [
				'jidToSignalProtocolAddress parity',
				'LID mapping forward/reverse parity',
				'sender-key distribution and group cipher parity'
			]
		},
		addresses: await buildAddressFixtures(),
		lid_mapping: await buildLidMappingFixtures(),
		sender_key: await buildSenderKeyFixtures()
	}

	mkdirSync(dirname(fixturePath), { recursive: true })
	writeFileSync(fixturePath, JSON.stringify(fixture, null, 2) + '\n')
}

await main()
