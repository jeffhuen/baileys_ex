import { Buffer } from 'node:buffer'
import { readFile } from 'node:fs/promises'

import { proto } from '../reference/Baileys-master/WAProto/index.js'
import { BinaryInfo } from '../reference/Baileys-master/src/WAM/BinaryInfo.ts'
import { WEB_EVENTS, WEB_GLOBALS } from '../reference/Baileys-master/src/WAM/constants.ts'
import { encodeWAM } from '../reference/Baileys-master/src/WAM/encode.ts'
import { getPlatformId } from '../reference/Baileys-master/src/Utils/browser-utils.ts'
import { aesEncryptCTR, derivePairingCodeKey } from '../reference/Baileys-master/src/Utils/crypto.ts'
import { generateWAMessageContent } from '../reference/Baileys-master/src/Utils/messages.ts'
import { decodeBinaryNode, encodeBinaryNode } from '../reference/Baileys-master/src/WABinary/index.ts'
import {
	areJidsSameUser,
	jidEncode,
	jidDecode,
	jidNormalizedUser
} from '../reference/Baileys-master/src/WABinary/jid-utils.ts'

type JsonBinary =
	| null
	| string
	| { type: 'binary'; base64: string }
	| JsonBinaryNode[]

type JsonBinaryNode = {
	tag: string
	attrs?: Record<string, string | null | undefined>
	content?: JsonBinary
}

type RunnerRequest = {
	operation: string
	input: Record<string, unknown>
}

async function main() {
	try {
		const request = parseRequest(await readPayload())
		const result = await runOperation(request)
		writeResponse({ ok: true, result })
	} catch (error) {
		writeResponse({
			ok: false,
			error: {
				message: error instanceof Error ? error.message : String(error)
			}
		})
		process.exitCode = 1
	}
}

async function runOperation(request: RunnerRequest) {
	switch (request.operation) {
		case 'wabinary.encode':
			return runWABinaryEncode(request.input)
		case 'wabinary.decode':
			return runWABinaryDecode(request.input)
		case 'jid.decode':
			return runJidDecode(request.input)
		case 'jid.encode':
			return runJidEncode(request.input)
		case 'jid.normalized_user':
			return runJidNormalizedUser(request.input)
		case 'jid.same_user':
			return runJidSameUser(request.input)
		case 'auth.derive_pairing_code_key':
			return runAuthDerivePairingCodeKey(request.input)
		case 'auth.build_pairing_request':
			return runAuthBuildPairingRequest(request.input)
		case 'message.generate_content':
			return runMessageGenerateContent(request.input)
		case 'feature.presence_send':
			return runFeaturePresenceSend(request.input)
		case 'feature.presence_subscribe':
			return runFeaturePresenceSubscribe(request.input)
		case 'feature.presence_parse':
			return runFeaturePresenceParse(request.input)
		case 'feature.privacy_query':
			return runFeaturePrivacyQuery(request.input)
		case 'wam.registry_counts':
			return runWAMRegistryCounts()
		case 'wam.encode':
			return runWAMEncode(request.input)
		default:
			throw new Error(`unsupported operation: ${request.operation}`)
	}
}

function runWABinaryEncode(input: Record<string, unknown>) {
	const node = decodeJsonNode(assertJsonNode(input.node))
	const encoded = Buffer.from(encodeBinaryNode(node))

	return {
		encoded_hex: encoded.toString('hex')
	}
}

async function runWABinaryDecode(input: Record<string, unknown>) {
	const encodedHex = input.encoded_hex
	if (typeof encodedHex !== 'string') {
		throw new Error('expected input.encoded_hex to be a string')
	}

	const node = await decodeBinaryNode(Buffer.from(encodedHex, 'hex'))

	return {
		node: normalizeJsonNode(node)
	}
}

function runJidDecode(input: Record<string, unknown>) {
	const jid = input.jid
	if (typeof jid !== 'string') {
		throw new Error('expected input.jid to be a string')
	}

	return {
		jid: normalizeDecodedJid(jidDecode(jid))
	}
}

function runJidEncode(input: Record<string, unknown>) {
	const server = input.server
	const user = input.user
	const device = input.device
	const agent = input.agent

	if (typeof server !== 'string') {
		throw new Error('expected input.server to be a string')
	}

	if (user !== null && user !== undefined && typeof user !== 'string' && typeof user !== 'number') {
		throw new Error('expected input.user to be a string, number, or null')
	}

	if (device !== null && device !== undefined && typeof device !== 'number') {
		throw new Error('expected input.device to be a number or null')
	}

	if (agent !== null && agent !== undefined && typeof agent !== 'number') {
		throw new Error('expected input.agent to be a number or null')
	}

	return {
		jid: jidEncode(
			(user as string | number | null | undefined) ?? null,
			server as Parameters<typeof jidEncode>[1],
			(device as number | null | undefined) ?? undefined,
			(agent as number | null | undefined) ?? undefined
		)
	}
}

function runJidNormalizedUser(input: Record<string, unknown>) {
	const jid = input.jid
	if (typeof jid !== 'string') {
		throw new Error('expected input.jid to be a string')
	}

	return {
		jid: jidNormalizedUser(jid)
	}
}

function runJidSameUser(input: Record<string, unknown>) {
	const jid1 = input.jid1
	const jid2 = input.jid2

	if (typeof jid1 !== 'string' || typeof jid2 !== 'string') {
		throw new Error('expected input.jid1 and input.jid2 to be strings')
	}

	return {
		same_user: areJidsSameUser(jid1, jid2)
	}
}

async function runAuthDerivePairingCodeKey(input: Record<string, unknown>) {
	const pairingCode = assertString(input.pairing_code, 'input.pairing_code')
	const salt = decodeBase64Field(input.salt_base64, 'input.salt_base64')

	return {
		key_hex: Buffer.from(await derivePairingCodeKey(pairingCode, salt)).toString('hex')
	}
}

async function runAuthBuildPairingRequest(input: Record<string, unknown>) {
	const pairingCode = assertString(input.pairing_code, 'input.pairing_code')
	const phoneNumber = assertString(input.phone_number, 'input.phone_number')
	const pairingEphemeralPublic = decodeBase64Field(
		input.pairing_ephemeral_public_base64,
		'input.pairing_ephemeral_public_base64'
	)
	const noisePublic = decodeBase64Field(input.noise_public_base64, 'input.noise_public_base64')
	const salt = decodeBase64Field(input.salt_base64, 'input.salt_base64')
	const iv = decodeBase64Field(input.iv_base64, 'input.iv_base64')
	const browserInput = assertRecord(input.browser, 'input.browser')
	const platformName = assertString(browserInput.platform_name, 'input.browser.platform_name')
	const browser = assertString(browserInput.browser, 'input.browser.browser')

	const key = await derivePairingCodeKey(pairingCode, salt)
	const wrappedPublicKey = aesEncryptCTR(pairingEphemeralPublic, key, iv)
	const jid = jidEncode(phoneNumber, 's.whatsapp.net')

	return {
		pairing_code: pairingCode,
		node: normalizeJsonNode({
			tag: 'iq',
			attrs: {
				to: 's.whatsapp.net',
				type: 'set',
				xmlns: 'md'
			},
			content: [
				{
					tag: 'link_code_companion_reg',
					attrs: {
						jid,
						stage: 'companion_hello',
						should_show_push_notification: 'true'
					},
					content: [
						{
							tag: 'link_code_pairing_wrapped_companion_ephemeral_pub',
							attrs: {},
							content: Buffer.concat([salt, iv, wrappedPublicKey])
						},
						{
							tag: 'companion_server_auth_key_pub',
							attrs: {},
							content: noisePublic
						},
						{
							tag: 'companion_platform_id',
							attrs: {},
							content: getPlatformId(browser)
						},
						{
							tag: 'companion_platform_display',
							attrs: {},
							content: `${browser} (${platformName})`
						},
						{
							tag: 'link_code_pairing_nonce',
							attrs: {},
							content: '0'
						}
					]
				}
			]
		})
	}
}

async function runMessageGenerateContent(input: Record<string, unknown>) {
	const content = assertRecord(input.content, 'input.content')
	const nowMs = input.now_ms
	const messageSecret = input.message_secret_base64
		? decodeBase64Field(input.message_secret_base64, 'input.message_secret_base64')
		: null

	const message = await withOptionalDateNow(nowMs, async () => {
		return generateWAMessageContent(content as any, {} as any)
	})

	if (messageSecret) {
		message.messageContextInfo = message.messageContextInfo || {}
		message.messageContextInfo.messageSecret = messageSecret
	}

	return {
		message_hex: Buffer.from(proto.Message.encode(message).finish()).toString('hex')
	}
}

function runFeaturePresenceSend(input: Record<string, unknown>) {
	const type = assertString(input.type, 'input.type')
	const toJid = input.to_jid
	const meId = optionalString(input.me_id)
	const meLid = optionalString(input.me_lid)
	const meName = optionalString(input.me_name)

	if (type === 'available' || type === 'unavailable') {
		if (!meName) {
			return { node: null }
		}

		return {
			node: normalizeJsonNode({
				tag: 'presence',
				attrs: {
					name: meName.replace(/@/g, ''),
					type
				}
			})
		}
	}

	const decoded = jidDecode(assertString(toJid, 'input.to_jid'))
	if (!decoded) {
		throw new Error('invalid input.to_jid')
	}

	const from = decoded.server === 'lid' ? meLid : meId
	if (!from) {
		throw new Error('missing from jid')
	}

	return {
		node: normalizeJsonNode({
			tag: 'chatstate',
			attrs: {
				from,
				to: assertString(toJid, 'input.to_jid')
			},
			content: [
				{
					tag: type === 'recording' ? 'composing' : type,
					attrs: type === 'recording' ? { media: 'audio' } : {}
				}
			]
		})
	}
}

function runFeaturePresenceSubscribe(input: Record<string, unknown>) {
	const toJid = assertString(input.to_jid, 'input.to_jid')
	const messageTag = assertString(input.message_tag, 'input.message_tag')
	const tcToken = input.tc_token_base64 ? decodeBase64Field(input.tc_token_base64, 'input.tc_token_base64') : null

	return {
		node: normalizeJsonNode({
			tag: 'presence',
			attrs: {
				to: toJid,
				id: messageTag,
				type: 'subscribe'
			},
			content: tcToken
				? [
						{
							tag: 'tctoken',
							attrs: {},
							content: tcToken
						}
					]
				: undefined
		})
	}
}

function runFeaturePresenceParse(input: Record<string, unknown>) {
	const node = decodeJsonNode(assertJsonNode(input.node))
	const update = parsePresenceUpdate(node)

	return {
		update
	}
}

function runFeaturePrivacyQuery(input: Record<string, unknown>) {
	const name = assertString(input.name, 'input.name')
	const value = assertString(input.value, 'input.value')

	return {
		node: normalizeJsonNode({
			tag: 'iq',
			attrs: {
				xmlns: 'privacy',
				to: 's.whatsapp.net',
				type: 'set'
			},
			content: [
				{
					tag: 'privacy',
					attrs: {},
					content: [
						{
							tag: 'category',
							attrs: { name, value }
						}
					]
				}
			]
		})
	}
}

function runWAMRegistryCounts() {
	return {
		events: WEB_EVENTS.length,
		globals: WEB_GLOBALS.length
	}
}

function runWAMEncode(input: Record<string, unknown>) {
	const sequence = assertNumber(input.sequence, 'input.sequence')
	const events = Array.isArray(input.events) ? input.events : []

	const binaryInfo = new BinaryInfo({
		sequence,
		events: events.map(assertWAMEvent)
	})

	return {
		wam_hex: Buffer.from(encodeWAM(binaryInfo)).toString('hex')
	}
}

function assertJsonNode(value: unknown): JsonBinaryNode {
	if (!value || typeof value !== 'object' || Array.isArray(value)) {
		throw new Error('expected input.node to be an object')
	}

	const node = value as JsonBinaryNode
	if (typeof node.tag !== 'string') {
		throw new Error('expected input.node.tag to be a string')
	}

	return node
}

function decodeJsonNode(node: JsonBinaryNode) {
	return {
		tag: node.tag,
		attrs: decodeAttrs(node.attrs),
		content: decodeContent(node.content)
	}
}

function normalizeJsonNode(node: { tag: string; attrs?: Record<string, string>; content?: unknown }): JsonBinaryNode {
	return {
		tag: node.tag,
		attrs: node.attrs || {},
		content: normalizeContent(node.content)
	}
}

function normalizeDecodedJid(
	jid:
		| {
				user: string
				server: string
				device?: number
				domainType?: number
		  }
		| undefined
) {
	if (!jid) {
		return null
	}

	return {
		user: jid.user,
		server: jid.server,
		device: jid.device ?? null,
		agent: jid.domainType && jid.domainType > 1 && jid.domainType < 128 ? jid.domainType : null
	}
}

function parsePresenceUpdate(node: { tag: string; attrs?: Record<string, string>; content?: unknown }) {
	const attrs = node.attrs || {}
	const jid = attrs.from
	const participant = attrs.participant || attrs.from

	if (!jid || !participant) {
		throw new Error('invalid presence node')
	}

	let presence: { last_known_presence: string; last_seen: number | null } | undefined

	if (node.tag === 'presence') {
		presence = {
			last_known_presence: attrs.type === 'unavailable' ? 'unavailable' : 'available',
			last_seen: attrs.last && attrs.last !== 'deny' ? Number(attrs.last) : null
		}
	} else if (Array.isArray(node.content)) {
		const firstChild = node.content[0] as { tag?: string; attrs?: Record<string, string> } | undefined
		if (!firstChild || typeof firstChild.tag !== 'string') {
			throw new Error('invalid chatstate node')
		}

		let type = firstChild.tag
		if (type === 'paused') {
			type = 'available'
		}

		if (firstChild.attrs?.media === 'audio') {
			type = 'recording'
		}

		presence = {
			last_known_presence: type,
			last_seen: null
		}
	}

	if (!presence) {
		throw new Error('invalid presence node')
	}

	return {
		id: jid,
		presences: {
			[participant]: presence
		}
	}
}

function decodeAttrs(attrs: JsonBinaryNode['attrs']) {
	if (!attrs) {
		return {}
	}

	return Object.fromEntries(
		Object.entries(attrs).filter(([, value]) => value !== null && value !== undefined)
	) as Record<string, string>
}

function assertRecord(value: unknown, label: string) {
	if (!value || typeof value !== 'object' || Array.isArray(value)) {
		throw new Error(`expected ${label} to be an object`)
	}

	return value as Record<string, unknown>
}

function assertString(value: unknown, label: string) {
	if (typeof value !== 'string') {
		throw new Error(`expected ${label} to be a string`)
	}

	return value
}

function optionalString(value: unknown) {
	return typeof value === 'string' ? value : null
}

function assertNumber(value: unknown, label: string) {
	if (typeof value !== 'number') {
		throw new Error(`expected ${label} to be a number`)
	}

	return value
}

function decodeBase64Field(value: unknown, label: string) {
	return Buffer.from(assertString(value, label), 'base64')
}

function assertWAMEvent(value: unknown) {
	const event = assertRecord(value, 'event')
	const name = assertString(event.name, 'event.name')

	return {
		[name]: {
			props: Object.fromEntries(normalizeOrderedPairs(event.props)),
			globals: Object.fromEntries(normalizeOrderedPairs(event.globals))
		}
	}
}

function normalizeOrderedPairs(value: unknown) {
	if (!Array.isArray(value)) {
		return []
	}

	return value.map(entry => {
		if (!Array.isArray(entry) || entry.length !== 2 || typeof entry[0] !== 'string') {
			throw new Error('expected ordered pair entries shaped as [name, value]')
		}

		return [entry[0], entry[1]]
	})
}

function decodeContent(content: JsonBinary) {
	if (content === null || content === undefined) {
		return undefined
	}

	if (typeof content === 'string') {
		return content
	}

	if (Array.isArray(content)) {
		return content.map(decodeJsonNode)
	}

	if (typeof content === 'object' && content.type === 'binary' && typeof content.base64 === 'string') {
		return Buffer.from(content.base64, 'base64')
	}

	throw new Error('unsupported binary node content')
}

function normalizeContent(content: unknown): JsonBinary {
	if (content === undefined || content === null) {
		return null
	}

	if (typeof content === 'string') {
		return content
	}

	if (content instanceof Uint8Array || Buffer.isBuffer(content)) {
		return {
			type: 'binary',
			base64: Buffer.from(content).toString('base64')
		}
	}

	if (Array.isArray(content)) {
		return content.map(item => normalizeJsonNode(item as JsonBinaryNode))
	}

	throw new Error('unsupported decoded node content')
}

async function withOptionalDateNow<T>(value: unknown, work: () => Promise<T>) {
	if (typeof value !== 'number') {
		return work()
	}

	const originalDateNow = Date.now
	Date.now = () => value

	try {
		return await work()
	} finally {
		Date.now = originalDateNow
	}
}

function parseRequest(raw: string): RunnerRequest {
	const decoded = JSON.parse(raw) as Partial<RunnerRequest>

	if (typeof decoded.operation !== 'string') {
		throw new Error('expected operation to be a string')
	}

	if (!decoded.input || typeof decoded.input !== 'object' || Array.isArray(decoded.input)) {
		throw new Error('expected input to be an object')
	}

	return {
		operation: decoded.operation,
		input: decoded.input as Record<string, unknown>
	}
}

async function readPayload() {
	const payloadPath = process.argv[2]
	if (payloadPath) {
		return readFile(payloadPath, 'utf8')
	}

	return readStdin()
}

function readStdin() {
	return new Promise<string>((resolve, reject) => {
		const chunks: Buffer[] = []

		process.stdin.on('data', chunk => {
			chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
		})

		process.stdin.on('end', () => {
			resolve(Buffer.concat(chunks).toString('utf8'))
		})

		process.stdin.on('error', reject)
	})
}

function writeResponse(payload: unknown) {
	process.stdout.write(`${JSON.stringify(payload)}\n`)
}

void main()
