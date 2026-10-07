import { createConfig, createConnector, http } from 'wagmi'
import { defineChain, type Address } from 'viem'

export const localChain = defineChain({
  id: 31337,
  name: '本机 Anvil（虚拟资金）',
  nativeCurrency: { name: 'LOCAL', symbol: 'LOCAL', decimals: 18 },
  rpcUrls: { default: { http: ['http://127.0.0.1:8545'] } },
  testnet: true,
})

// This connector selects an unlocked local test identity. It is not a browser wallet or signature.
function localTestAccount() {
  let connected = false
  async function accounts(): Promise<readonly Address[]> {
    if (window.location.hostname !== '127.0.0.1') throw new Error('仅允许本机测试页面')
    const response = await fetch('/api/config')
    if (!response.ok) throw new Error('无法读取本地配置')
    const config = await response.json()
    if (config.network !== 'local' || config.chain_id !== 31337) throw new Error('仅支持本机 Anvil 31337')
    return [config.owner_address as Address]
  }
  return createConnector(() => ({
    id: 'local-test-account', name: '本机测试账户（无真实签名）', type: 'local',
    async connect() { const result = await accounts(); connected = true; return { accounts: result, chainId: 31337 } as never },
    async disconnect() { connected = false },
    async getAccounts() { return connected ? accounts() : [] },
    async getChainId() { return 31337 },
    async getProvider() { throw new Error('本机测试账户只通过受限后端接口操作，不提供钱包签名') },
    async isAuthorized() { return connected },
    async switchChain({ chainId }) { if (chainId !== 31337) throw new Error('不允许切换公链'); return localChain },
    onAccountsChanged() {}, onChainChanged() {}, onDisconnect() { connected = false },
  }))
}

export const wagmiConfig = createConfig({
  chains: [localChain], connectors: [localTestAccount()],
  transports: { [localChain.id]: http() }, multiInjectedProviderDiscovery: false,
})

declare module 'wagmi' {
  interface Register { config: typeof wagmiConfig }
}
