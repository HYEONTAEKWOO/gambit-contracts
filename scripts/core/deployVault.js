const { deployContract, contractAt , sendTxn } = require("../shared/helpers")
const { expandDecimals } = require("../../test/shared/utilities")
const { toUsd } = require("../../test/shared/units")

async function main() {
  const nativeToken = { address: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c" }
  const vault = await deployContract("Vault", [])
  const usdg = await deployContract("USDG", [vault.address])
  const router = await deployContract("Router", [vault.address, usdg.address, nativeToken.address])
  const vaultPriceFeed = await deployContract("VaultPriceFeed", [])

  const btc = { address: "0x7130d2a12b9bcbfae4f2634d864a1ee1ce3ead9c" }
  const eth = { address: "0x2170ed0880ac9a755fd29b2688956bd959f933f8" }
  const bnb = nativeToken
  const bnbBusd = { address: "0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16" }
  const ethBnb = { address: "0x74E4716E431f45807DCF19f284c7aA99F18a4fbc" }
  const btcBnb = { address: "0x61EB789d75A95CAa3fF50ed7E47b96c132fEc082" }

  await sendTxn(vaultPriceFeed.setTokens(btc.address, eth.address, bnb.address), "vaultPriceFeed.setTokens")
  await sendTxn(vaultPriceFeed.setPairs(bnbBusd.address, ethBnb.address, btcBnb.address), "vaultPriceFeed.setPairs")

  await sendTxn(vault.initialize(
    router.address, // router
    usdg.address, // usdg
    vaultPriceFeed.address, // priceFeed
    expandDecimals(3000 * 1000, 18), // maxUsdgBatchSize
    expandDecimals(600 * 1000, 18), // maxUsdgBuffer
    toUsd(5), //  liquidationFeeUsd
    600, // fundingRateFactor
    30000000000, // maxGasPrice, 30 gwei
    20000 // maxDebtBasisPoints
  ), "vault.initialize")

  await sendTxn(vaultPriceFeed.setMaxStrictPriceDeviation(expandDecimals(5, 28)), "vaultPriceFeed.setMaxStrictPriceDeviation") // 0.05 USD

  await sendTxn(vault.setFees(
    20, // swapFeeBasisPoints, 0.2%
    10, // stableSwapFeeBasisPoints, 0.1%
    10, // marginFeeBasisPoints, 0.1%
    toUsd(5) // liquidationFeeUsd, 5 USD
  ), "vault.setFees")

  await sendTxn(vaultPriceFeed.setPriceSampleSpace(2), "vaultPriceFeed.setPriceSampleSpace")
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error)
    process.exit(1)
  })
