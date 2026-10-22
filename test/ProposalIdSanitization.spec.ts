import { expect } from 'chai'
import hre, { ethers } from 'hardhat'

// Sync describe (not `async () => {}`) so the cases register reliably.
describe('proposalId sanitization', () => {
  const txHash = '0x' + '11'.repeat(32)

  async function deployModule() {
    const [user1] = await ethers.getSigners()
    const a = await user1.getAddress()
    const Module = await hre.ethers.getContractFactory('RealityModuleETH')
    // (owner, avatar, target, oracle, timeout, cooldown, expiration, bond, templateId, arbitrator)
    return Module.deploy(a, a, a, a, 42, 23, 0, 0, 1337, a)
  }

  it('accepts ASCII alphanumerics, hyphen and underscore', async () => {
    const module = await deployModule()
    const id = 'Abc-123_xyz-0xDEADbeef'
    const q = await module.buildQuestion(id, [txHash])
    expect(q).to.contain(id) // proposalId survives verbatim, before the ␟ delimiter
  })

  it('accepts a real bytes32-hex Snapshot proposalId', async () => {
    const module = await deployModule()
    const id =
      '0xb4c8c69b55a442948a7d66b42ac418ae22cad057fee7fbcb0c27a8768bfd3541'
    expect(await module.buildQuestion(id, [txHash])).to.contain(id)
  })

  it('rejects an empty proposalId', async () => {
    const module = await deployModule()
    await expect(module.buildQuestion('', [txHash])).to.be.revertedWith(
      'proposalId must not be empty',
    )
  })

  it('accepts a proposalId of exactly 128 bytes', async () => {
    const module = await deployModule()
    const id = 'a'.repeat(128)
    expect(await module.buildQuestion(id, [txHash])).to.contain(id)
  })

  it('rejects a proposalId longer than 128 bytes', async () => {
    const module = await deployModule()
    await expect(
      module.buildQuestion('a'.repeat(129), [txHash]),
    ).to.be.revertedWith('proposalId too long')
  })

  // One case per dangerous class. `.` and `:` are intentionally rejected:
  // the chosen charset is alphanumeric + hyphen + underscore only.
  const bad: Record<string, string> = {
    space: 'has space',
    'json double-quote breakout': 'x","title":"pwned',
    backslash: 'back\\slash',
    dot: 'dot.ted',
    colon: 'colon:x',
    slash: 'ipfs/path',
    'reality.eth ␟ delimiter (U+241F)': 'a␟b',
    'non-ascii / homoglyph': 'аdmin', // leading char is Cyrillic U+0430
    emoji: 'gm\u{1F600}',
  }
  for (const [name, payload] of Object.entries(bad)) {
    it(`rejects ${name}`, async () => {
      const module = await deployModule()
      await expect(module.buildQuestion(payload, [txHash])).to.be.revertedWith(
        'proposalId has invalid characters',
      )
    })
  }

  it('rejects the real-world injection payload seen on mainnet', async () => {
    const module = await deployModule()
    const payload =
      'x","title":"Will the sun rise tomorrow?","lang":"en","type":"bool","x":"'
    await expect(module.buildQuestion(payload, [txHash])).to.be.revertedWith(
      'proposalId has invalid characters',
    )
  })
})
