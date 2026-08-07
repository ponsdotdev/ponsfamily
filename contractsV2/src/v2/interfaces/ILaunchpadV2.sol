// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice Shared pons v2 interfaces: fee escrow, fee policy, and the launch
 * factory/curve records. Uniswap V4 core and periphery types are imported
 * directly from the vendored packages by the contracts that need them,
 * rather than re-declared here.
 */

/**
 * @notice Claimable balance ledger shared by every v2 bonding curve and the
 * meme hook. Native ETH crediting is permissionless (callers attach the ETH
 * they are crediting). Token crediting requires the caller to hold the
 * tokens themselves, pulled via `transferFrom`, so it is equally safe to
 * leave open. Token support exists for launches whose deployer-chosen
 * pairToken is a non-native ERC-20: those curves trade and credit in that
 * asset from the first trade through to graduation.
 */
interface IPonsV2FeeEscrow {
    function credit(address recipient) external payable;
    function creditToken(address recipient, address token, uint256 amount) external;
    function claim() external returns (uint256 amount);
    function claim(uint256 amount) external returns (uint256);
    function claimToken(address token) external returns (uint256 amount);
    function claimToken(address token, uint256 amount) external returns (uint256);
    function balanceOf(address recipient) external view returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
}

/**
 * @notice Fee terms frozen for one launch when its curve is created and its
 * graduated pool is registered. Global hook configuration only governs
 * launches created after a later policy update.
 */
struct FeePolicySnapshot {
    address protocolFeeRecipient;
    uint16 protocolFeeShareBps;
    uint16 buybackBurnBps;
    uint16 hookFeeBps;
    uint16 maxInternalPriceImpactBps;
}

/**
 * @notice Opening-window buy tax terms, frozen into a curve at deployment.
 *
 * The tax decays from `startBps` to zero over `window` seconds, halving once
 * per `halfLife` seconds, and applies to buys only. It exists to price out
 * latency racing at t=0: Robinhood Chain sequences first-come-first-served
 * with no public mempool, so the contestable edge is measured in the
 * milliseconds between the launch transaction landing and a listener's buy
 * reaching the sequencer. A quantity cap cannot reach that edge because it is
 * defeated by splitting wallets; a tax priced per unit of capital can.
 *
 * `startBps == 0` disables the mechanism entirely and restores the curve's
 * original behaviour, so existing launch configs remain expressible.
 *
 * @dev Resolution is deliberately whole seconds. `block.timestamp` is the
 * only clock available here: on an Arbitrum Orbit chain `block.number`
 * approximates the *L1* block number and cannot be used to measure L2 time.
 * Every block inside the same second therefore sees the same tax, which is
 * the intended behaviour rather than a limitation — a bot's advantage over a
 * human is sub-second, so a one-second floor removes it wholesale.
 */
struct SnipeTaxTerms {
    uint16 startBps;
    uint32 window;
    uint32 halfLife;
}

/**
 * @notice Protocol-owned fee policy read by every bonding curve and by the
 * meme hook. The current policy is snapshotted at launch, while the live
 * sweep operator remains rotatable for operational liveness.
 */
interface IPonsV2FeePolicy {
    function protocolFeeShareBps() external view returns (uint256);
    function buybackBurnBps() external view returns (uint256);
    function protocolFeeRecipient() external view returns (address);
    function feeEscrow() external view returns (IPonsV2FeeEscrow);
    // Ceiling on how much a single internal buyback conversion is allowed
    // to move the pool's own price, read by the meme hook's real internal
    // swaps and by the bonding curve's pre-graduation buyback pricing so
    // both phases apply the same conservative bound.
    function maxInternalPriceImpactBps() external view returns (uint256);
    function feeSweepOperator() external view returns (address);
    function currentFeePolicy() external view returns (FeePolicySnapshot memory);
}

/**
 * @notice Minimal ERC-721 receiver signature used by PonsV2LaunchLocker to
 * accept the graduated Uniswap V4 position NFT.
 */
interface IERC721ReceiverLike {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/**
 * @notice Graduation proceeds in two phases so the slippage-sensitive step
 * is never bundled with the automatic, threshold-crossing trigger:
 * - NotGraduated: still trading on the bonding curve.
 * - Swept: the curve has been drained (fees swept, trading halted, ETH and
 *   the remaining token supply pulled into the factory); still needs a V4
 *   pool.
 * - PoolCreated: the V4 pool exists, its full-range position is locked, and
 *   the meme hook is registered for it.
 * - Rescued: the swept reserves were released manually because the launch's
 *   quote asset stopped being able to deliver an exact transfer, which no
 *   retry of the seed step could ever satisfy. Terminal, like PoolCreated.
 */
enum GraduationPhase {
    NotGraduated,
    Swept,
    PoolCreated,
    Rescued
}

/**
 * @notice Record kept by PonsV2LaunchFactory for every launch, readable by
 * the locker and by off-chain indexers.
 */
interface IPonsV2LaunchFactory {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        // Snapshotted from the launch config at launch time, so a later
        // config edit can never change the pool a token graduates into.
        uint24 poolFee;
        int24 tickSpacing;
        // Creator-chosen at launch, capped by the protocol's maxCreatorTaxBps
        // at the time of launch; an additional trade fee charged the same
        // way the base fee is, paid entirely to the creator.
        uint16 creatorTaxBps;
        bool buybackEnabled;
        GraduationPhase phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}

/**
 * @notice Narrow surface the factory needs from a bonding curve to trigger
 * graduation once the ETH threshold has been crossed.
 */
interface IPonsV2BondingCurve {
    function token() external view returns (address);
    function pairToken() external view returns (address);
    function graduationThreshold() external view returns (uint256);
    function graduated() external view returns (bool);
    function quoteReserve() external view returns (uint256);
    function realQuoteReserve() external view returns (uint256);
    function tokenReserve() external view returns (uint256);
    function readyToGraduate() external view returns (bool);
    function sweepFees(uint256 minBuybackTokensOut) external;
    function graduate(address recipient) external returns (uint256 ethOut, uint256 tokenOut);
}
