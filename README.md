# Callpad contracts

A token launchpad on Uniswap v4. Every handle gets exactly one token. The right to launch it is either won in a USD auction or exercised directly by the owner of the handle. The whole tradable supply goes into a Uniswap v4 pool whose hook charges a swap fee in USD and splits it between the treasury, the token creator and the handle's account.

## Contracts

| File | Purpose |
| --- | --- |
| [`src/Launchpad.sol`](src/Launchpad.sol) | Handle auctions, the creator's prebuy, token deployment, pool initialization and liquidity, admin settings. Upgradeable, lives behind a UUPS proxy |
| [`src/Hook.sol`](src/Hook.sol) | Uniswap v4 hook: restricts pool creation to the Launchpad, takes the swap fee and accounts for fee recipients |
| [`src/Token.sol`](src/Token.sol) | ERC-20 implementation behind minimal-proxy clones, fixed supply minted once to the Launchpad |
| [`src/Proofs.sol`](src/Proofs.sol) | EIP-712 struct hashes and signature checks for off-chain proofs |

## Concepts

- **Handle** — identified on-chain by `handleId = handleIdOf(symbol)`, the hash of the symbol in lowercase. The symbol keeps the case it was proven with, so `ParikPatelCFA` and `parikpatelcfa` are one handle. A handle can be launched once.
- **USD** — the ERC-20 passed to the Launchpad constructor. All bids, prebuys and fees are denominated in it. It is always `currency0` of the pool: token addresses are required to be greater than the USD address, which is enforced through the clone salt.
- **Proof** — an EIP-712 signature (domain `Callpad`, version `1`) by `proofSigner` with a deadline. Proofs gate starting an auction, launching as the handle owner, confirming the call, binding the handle's account and claiming the airdrop. `SignatureChecker` is used, so the signer may be an EOA or an ERC-1271 contract.
- **Creator** — the address that launched the token: the auction winner or the handle owner.
- **Account** — the address of the handle owner. It is known at launch for owner launches and bound later through `setAccount` for auction launches.

## Lifecycle

### Auction

1. `startAuction(name, symbol, salt, minBid, amount, buyAmount, proofDeadline, proof)` opens an auction for the handle and places the first bid of `amount`, which must be at least `minBid`. The proof covers `name`, `symbol`, `minBid` and the deadline, so one proof is valid for any opening bid from `minBid` up. The auction lasts `auctionDuration` (24 hours by default). The auction also records the settings in force at that moment: `auctionExtension`, `auctionMinBidIncrementBps`, `airdropBps` and `startTick`. They stay with it until launch, whatever the owner changes later.
2. `bid(handleId, amount, buyAmount)` outbids the current highest bid by at least the auction's bid increment (10% by default). The previous bidder is refunded in the same transaction. A bid placed within the auction's extension (the last 5 minutes by default) extends the auction by that same interval.
3. Every bid, the first one included, carries a prebuy: `buyAmount` of USD deposited on top of the bid, which may be zero. Only the highest bidder has a prebuy. When they are outbid, it is refunded together with their bid, and the prebuy of the new bid takes its place. The prebuy does not count towards the bid.
4. `launch(handleId)` is callable by anyone once the auction has ended. The highest bidder becomes the creator, the account stays unset.

### Owner launch

`launchOwn(name, symbol, salt, proofDeadline, buyAmount, proof)` lets the handle owner launch directly. The proof covers `name`, `symbol`, the caller and the deadline. If an auction for the handle is in progress or finished but not yet launched, it is cancelled: the highest bidder gets their bid and prebuy back, the auction's salt is reused so the token address announced in `AuctionStarted` stays valid, and its start tick is reused. An owner launch without an auction uses the current `startTick`. The owner may prebuy too: `buyAmount` of USD is taken from the caller, and it may be zero. The caller becomes both the creator and the account. The token counts as called from the start: `calledAt` is set at launch, so `confirmCall` reverts with `AlreadyCalled`.

### Launch

Both paths end in the same steps:

1. The token is deployed as a deterministic clone with salt `keccak256(abi.encode(handleId, salt))` and `TOKEN_SUPPLY` (1,000,000,000 tokens with 18 decimals) is minted to the Launchpad.
2. The token is registered in the hook together with its creator and account. For auction launches the winning bid is credited as fees: `TREASURY_SHARE_BPS` (30%) to the treasury and the rest to the account, held in escrow until the account is set.
3. The auction's `airdropBps` of the supply (1% by default) stays in the Launchpad and is recorded as `airdropTokens`, the part of the airdrop that has not been claimed yet. An owner launch has no airdrop: its whole supply goes to the pool.
4. A USD/token pool is initialized at the start tick with LP fee `0`, tick spacing `200` and the hook. The remaining supply is added as single-sided token liquidity over the range from the minimum usable tick to the start tick. The position belongs to the Launchpad, which has no function to remove it.
5. The creator's prebuy USD is swapped for tokens in that pool, as the first trade. The swap pays the regular hook fee. The tokens received are sent to the creator in the same transaction.

`Launched(handleId, token, launcher, name, symbol, airdropTokens, buyAmount, startTick)` reports what the token launched with: the airdrop kept in the Launchpad, the creator's prebuy in USD and the tick the pool started at. It is emitted before the pool is created, so the `Swapped` of the prebuy follows it. `BidPlaced(handleId, bidder, amount, buyAmount, endTime)` reports the prebuy of every bid.

### After launch

- `confirmCall(handleId, proofDeadline, proof)` records that the handle owner has called the token, once, as `calledAt`. The proof covers `handleId` and the deadline, not the caller, so anyone holding it can submit it.
- `setAccount(handleId, proofDeadline, proof)` binds the caller as the handle's account, once, after the call is confirmed: before that it reverts with `NotCalled`. The proof covers `handleId`, the caller and the deadline. Fees escrowed for the token are released to the account.
- `claimAirdrop(handleId, userId, amount, proofDeadline, proof)` transfers airdrop tokens to the caller. The proof covers `handleId`, `userId`, the caller, `amount` and the deadline. `userId` identifies the off-chain user the share belongs to: claims are counted per `userId`, not per address, so a user may claim to any address and never gets more than one share. `amount` is the user's whole share of the airdrop, not the size of one claim, and may not exceed `AIRDROP_CAP` (1,000,000 tokens). The share unlocks evenly over `AIRDROP_UNLOCK_PERIOD` (7 days) from `calledAt`, so there is nothing to claim before `confirmCall`: the claim reverts with `NotCalled`. It does not wait for `setAccount`. It pays the unlocked part of `amount` minus what the user has already claimed (`airdropClaimOf`) and reverts with `NothingToClaim` when that is zero, so a proof cannot be used twice at the same moment and a later claim pays only what has unlocked since. Claims are taken out of `airdropTokens` and revert once it runs out.

## Fees

The pool's LP fee is zero. The hook charges `FEE_BPS` (1%) of the USD side of every swap, in USD, for both swap directions and for both exact-input and exact-output swaps:

- when the USD amount is the specified one, the fee is computed from the specified amount and taken in `beforeSwap` through the before-swap delta;
- otherwise it is computed from the resulting USD delta and taken in `afterSwap`.

Each fee is split:

| Recipient | Share |
| --- | --- |
| Treasury | `TREASURY_SHARE_BPS` = 30% |
| Creator | `CREATOR_SHARE_BPS` = 35% |
| Account | the remainder, 35% plus rounding |

While a token has no account, the account share accumulates in `escrowedFees[token]`.

Fees are held by the hook as ERC-6909 claims on the PoolManager. `takeFees()` burns the caller's claims and sends them the USD. The treasury share is paid to whichever address is `Launchpad.treasury()` at the time of the call.

Every swap emits `Swapped(token, usdAmount, tokenAmount, fee, sqrtPriceX96)`, where `usdAmount` is the swapper's net USD delta with the fee already applied: the total paid when buying, the amount received when selling.

## Roles and trust assumptions

- **Owner** of the Launchpad (`OwnableUpgradeable`) can upgrade the Launchpad to a new implementation and change `proofSigner`, `treasury`, the auction settings (`auctionDuration`, `auctionExtension`, `auctionMinBidIncrementBps`) and the launch settings (`airdropBps`, `startTick`). Changes apply only to auctions and owner launches that start after them: an auction already in progress keeps the settings it started with, and a launched token is not affected.
- **Proof signer** is trusted to attest handle ownership and calls, and to authorize which handles may be auctioned, under which name and with which minimum opening bid. It also decides who gets how much of each airdrop: the contract caps one `userId` at `AIRDROP_CAP`, the total at the handle's `airdropTokens`, and unlocks the shares over `AIRDROP_UNLOCK_PERIOD` after the call.
- **Treasury** receives its share of bids and swap fees.
- The hook accepts `register` and `setAccount` calls only from the Launchpad and allows pool initialization only by the Launchpad.

## Deployment notes

The Launchpad is an `ERC1967Proxy` over the `Launchpad` implementation (UUPS). The address everyone uses, the hook included, is the address of the proxy.

- The implementation constructor takes `usd`, `poolManager` and `hook` and keeps them as immutables. They live in the code of the implementation, not in the storage of the proxy, so every new implementation has to be deployed with the same three values.
- `initialize(proofSigner, treasury)` is called once through the proxy, in the transaction that deploys it. It makes the caller the owner, sets the default settings and deploys the token implementation. The token implementation is kept in storage, so token addresses announced in `AuctionStarted` survive an upgrade.
- `upgradeToAndCall(implementation, data)` is restricted to the owner. A new implementation may only append storage variables after the existing ones.
- The contract is built with the optimizer on: without it the Launchpad does not fit into the 24,576-byte code size limit.

The proxy and the hook reference each other, the hook as an immutable, so one of the two addresses has to be known before deployment. The hook address must also encode its permissions: `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` and `afterSwapReturnDelta`. [`test/LaunchFixture.sol`](test/LaunchFixture.sol) shows the wiring used in tests.

[`script/Deploy.s.sol`](script/Deploy.s.sol) deploys the implementation, the proxy and the hook on Robinhood Chain, over its USDG and Uniswap v4 PoolManager. It predicts the proxy address from the deployer's nonce, mines the hook salt for that address and deploys the hook through the CREATE2 factory. The deployer becomes the owner, `PROOF_SIGNER` and `TREASURY` are addresses taken from the environment. The script returns the addresses of the Launchpad proxy and the hook.

```shell
PROOF_SIGNER=<address> TREASURY=<address> forge script script/Deploy.s.sol --rpc-url <rpc> --account <keystore> --broadcast
```

## Development

Requires [Foundry](https://book.getfoundry.sh/).

```shell
git clone --recursive https://github.com/callpad-app/contracts
cd contracts
forge build
forge test
```

Dependencies are git submodules pinned in [`foundry.lock`](foundry.lock):

| Dependency | Version |
| --- | --- |
| forge-std | v1.17.0 |
| openzeppelin-contracts | v5.5.0 |
| openzeppelin-contracts-upgradeable | v5.5.0 |
| uniswap-hooks | v1.2.1 |
| v4-periphery | `c6e4754` |

## License

[MIT](LICENSE)
