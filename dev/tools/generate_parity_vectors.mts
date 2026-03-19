import { Buffer } from 'node:buffer'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { BinaryInfo } from '../reference/Baileys-master/src/WAM/BinaryInfo.ts'
import { WEB_EVENTS, WEB_GLOBALS } from '../reference/Baileys-master/src/WAM/constants.ts'
import { encodeWAM } from '../reference/Baileys-master/src/WAM/encode.ts'
import { generateSyncdVectors } from '../scripts/generate_syncd_vectors.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)
const repoRoot = resolve(__dirname, '..', '..')
const parityRoot = resolve(repoRoot, 'test/fixtures/parity')

async function main() {
	await mkdir(parityRoot, { recursive: true })

	const signalFixture = await readJson(resolve(repoRoot, 'test/fixtures/signal/baileys_v7.json'))
	const mediaFixture = await readJson(resolve(repoRoot, 'test/fixtures/media/baileys_v7.json'))
	const wamDefinitions = await readJson(resolve(repoRoot, 'priv/wam/definitions.json'))
	const syncdVectors = await generateSyncdVectors()

	const wamFixture = {
		meta: {
			reference: 'dev/reference/Baileys-master/src/WAM',
			source: 'priv/wam/definitions.json'
		},
		counts: {
			events: WEB_EVENTS.length,
			globals: WEB_GLOBALS.length
		},
		samples: {
			mixed_event_hex: Buffer.from(
				encodeWAM(
					new BinaryInfo({
						sequence: 7,
						events: [
							{
								WamDroppedEvent: {
									props: {
										droppedEventCode: 5,
										droppedEventCount: 300,
										isFromWamsys: true
									},
									globals: {
										appIsBetaRelease: true,
										appVersion: '2.24.7'
									}
								}
							}
						]
					})
				)
			).toString('hex')
		},
		definitions: {
			event_names: Object.keys(wamDefinitions.events || {}),
			global_names: Object.keys(wamDefinitions.globals || {})
		}
	}

	const syncdFixture = {
		meta: {
			reference: 'dev/reference/Baileys-master/src/Utils/chat-utils.ts',
			source: 'dev/scripts/generate_syncd_vectors.mjs'
		},
		hkdf: {
			input_base64: hexToBase64(syncdVectors.hkdf.input_hex),
			index_key_hex: syncdVectors.hkdf.index_key_hex,
			value_encryption_key_hex: syncdVectors.hkdf.value_encryption_key_hex,
			value_mac_key_hex: syncdVectors.hkdf.value_mac_key_hex,
			snapshot_mac_key_hex: syncdVectors.hkdf.snapshot_mac_key_hex,
			patch_mac_key_hex: syncdVectors.hkdf.patch_mac_key_hex
		},
		mac: {
			data_base64: hexToBase64(syncdVectors.mac.data_hex),
			key_id_base64: hexToBase64(syncdVectors.mac.key_id_hex),
			value_mac_set_hex: syncdVectors.mac.value_mac_set_hex,
			value_mac_remove_hex: syncdVectors.mac.value_mac_remove_hex,
			snapshot_mac_hex: syncdVectors.mac.snapshot_mac_hex,
			patch_mac_hex: syncdVectors.mac.patch_mac_hex
		},
		lt_hash: syncdVectors.lt_hash,
		proto: syncdVectors.proto
	}

	const manifest = {
		meta: {
			reference: 'dev/reference/Baileys-master',
			version: '7.00rc9'
		},
		fixtures: {
			signal: {
				path: 'test/fixtures/parity/signal/baileys_rc9.json',
				source: 'test/fixtures/signal/baileys_v7.json',
				regenerate_with: 'dev/tools/generate_signal_fixtures.mts'
			},
			media: {
				path: 'test/fixtures/parity/media/baileys_rc9.json',
				source: 'test/fixtures/media/baileys_v7.json',
				regenerate_with: 'existing media fixture source'
			},
			syncd: {
				path: 'test/fixtures/parity/syncd/baileys_rc9.json',
				source: 'dev/scripts/generate_syncd_vectors.mjs',
				regenerate_with: 'dev/scripts/generate_syncd_vectors.mjs'
			},
			wam: {
				path: 'test/fixtures/parity/wam/baileys_rc9.json',
				source: 'priv/wam/definitions.json',
				regenerate_with: 'dev/scripts/generate_wam_definitions.mjs'
			}
		}
	}

	await writeJson(resolve(parityRoot, 'signal/baileys_rc9.json'), signalFixture)
	await writeJson(resolve(parityRoot, 'media/baileys_rc9.json'), mediaFixture)
	await writeJson(resolve(parityRoot, 'syncd/baileys_rc9.json'), syncdFixture)
	await writeJson(resolve(parityRoot, 'wam/baileys_rc9.json'), wamFixture)
	await writeJson(resolve(parityRoot, 'manifest.json'), manifest)
}

function hexToBase64(value: string) {
	return Buffer.from(value, 'hex').toString('base64')
}

async function readJson(path: string) {
	return JSON.parse(await readFile(path, 'utf8'))
}

async function writeJson(path: string, value: unknown) {
	await mkdir(dirname(path), { recursive: true })
	await writeFile(path, `${JSON.stringify(value, null, 2)}\n`)
}

void main()
