// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PonsV2BondingCurveMath} from "./libraries/PonsV2BondingCurveMath.sol";
import {PonsV2BuybackVault} from "./PonsV2BuybackVault.sol";
import {PonsV2LauncherToken} from "./PonsV2LauncherToken.sol";
import {FeePolicySnapshot, IPonsV2FeeEscrow, IPonsV2FeePolicy, SnipeTaxTerms} from "./interfaces/ILaunchpadV2.sol";
import {IPonsV2LaunchFactoryGraduation} from "./interfaces/ILaunchpadV2Graduation.sol";

/**
 * @title PonsV2BondingCurve
 * @notice Constant-product bonding curve for one v2 launch, adapted from
 * BootstrapPool.sol (code-423n4/2025-01-iq-ai). The curve trades against the
 * same quote asset its graduated Uniswap V4 pool will use: native ETH when
 * `pairToken` is the zero address, otherwise that ERC-20. Collecting the
 * eventual pool asset from the very first trade is what lets graduation seed
 * the pool directly, with no swap and therefore no price oracle anywhere in
 * the system.
 *
 * Every trade fee is charged against the quote leg regardless of trade
 * direction, so the curve never accrues fees denominated in the memecoin:
 * protocol and creator revenue is quote-denominated from the first trade,
 * before graduation ever happens. Fees are split and swept through the same
 * protocol/creator/buyback-and-lock policy the post-graduation hook uses,
 * read from `feePolicy` so both phases behave identically.
 */
contract PonsV2BondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant MAX_TOTAL_TRADE_FEE_BPS = 2_000; // 20%
    // The opening tax is deliberately outside MAX_TOTAL_TRADE_FEE_BPS. That
    // ceiling protects traders from a creator's standing rake for the life of
    // the launch; this one is a transient anti-latency measure that expires on
    // its own within seconds. Folding the two together would either cap the
    // opening tax at a level a bot would happily pay, or raise the standing
    // rake ceiling to 99%. They are separate risks and get separate limits.
    uint256 private constant MAX_SNIPE_TAX_START_BPS = 9_900; // 99%
    // Whatever the combined legs come to, a buyer keeps at least this share of
    // their input. It is what stops the clamped-fill gross-up denominator from
    // approaching zero, where the ceil-rounding would blow up.
    uint256 private constant MIN_BUYER_SHARE_BPS = 100; // 1%
    // Written in a single launch transaction and never extended, so the bound
    // is what keeps the launch fee from becoming a gas-griefing surface.
    uint256 private constant MAX_SNIPE_TAX_EXEMPTIONS = 32;

    error CurveGraduated();
    error ZeroAmount();
    error ZeroAddress();
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error NotFactory();
    error TransferFailed();
    error AlreadyGraduated();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidLaunchEconomics();
    error NotReadyToGraduate();
    error NotFeeSweepOperator();
    error InternalSwapRequiresOperator();
    error InvalidFeePolicy();
    error MinimumOutputRequired();
    error NativeValueMismatch(uint256 supplied, uint256 expected);
    error UnexpectedNativeValue();
    error InvalidSnipeTaxTerms();
    error ExemptionListTooLong();

    // `fee` and `tax` are reported separately because they fund different
    // parties: the fee splits across protocol, buyback and creator, while the
    // tax is paid to the creator in full.
    event CurveBuy(
        address indexed buyer, address indexed recipient, uint256 quoteIn, uint256 tokensOut, uint256 fee, uint256 tax
    );
    event CurveBuyRefunded(address indexed buyer, uint256 refund);
    event CurveSell(
        address indexed seller, address indexed recipient, uint256 tokensIn, uint256 quoteOut, uint256 fee, uint256 tax
    );
    event FeesSwept(uint256 protocolAmount, uint256 buybackAmount, uint256 creatorAmount);
    event FeesRescued(
        address indexed protocolRecipient,
        address indexed creatorRecipient,
        uint256 protocolAmount,
        uint256 creatorAmount
    );
    event BuybackLocked(uint256 quoteSpent, uint256 tokensLocked);
    event CurveCompleted(address recipient, uint256 quoteOut, uint256 tokenOut);
    event Initialized(address token);
    event CreatorFeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event BuybackEnabledUpdated(bool enabled);
    event AutoGraduationFailed(address indexed token, uint256 gasRemaining);
    // Emitted alongside CurveBuy, never instead of it. CurveBuy's `fee` field
    // reports the combined amount routed through the fee split so that field
    // keeps meaning "quote the protocol took"; this event lets an indexer
    // decompose it back out without a second ABI for CurveBuy itself.
    event SnipeTaxCharged(address indexed payer, address indexed recipient, uint256 amount, uint256 bps);
    event SnipeTaxExempted(address indexed account);

    // Not immutable: the token's constructor needs this curve's real address,
    // so the factory deploys the curve first, then the token, then wires the
    // token here via `initialize()`. Set exactly once, guarded by onlyFactory.
    address public token;
    // Quote asset for both curve trading and the graduated pool. The zero
    // address denotes native ETH.
    address public immutable pairToken;
    // Not immutable: the creator can hand off future fee sweeps to a new
    // address (or the factory can override on the protocol owner's behalf)
    // via `setCreatorFeeRecipient`, both gated through `onlyFactory`.
    address public deployer;
    address public immutable factory;
    IPonsV2FeePolicy public immutable feePolicy;
    IPonsV2FeeEscrow public immutable feeEscrow;
    PonsV2BuybackVault public immutable buybackVault;
    // These terms are frozen when the launch is created. Global hook policy
    // updates affect future launches but cannot redirect an active curve's
    // protocol share or change its buyback economics.
    address public immutable protocolFeeRecipient;
    address public immutable buybackCreatorRecipient;
    uint16 public immutable protocolFeeShareBps;
    uint16 public immutable buybackBurnBps;
    uint16 public immutable maxInternalPriceImpactBps;
    // Virtual quote reserve seeded at deploy, denominated in the quote
    // asset's own decimals rather than always in wei.
    uint256 public immutable phantomQuote;
    uint256 public immutable feeBps;
    // Creator-chosen at launch, capped by the protocol at launch time. Kept
    // entirely separate from feeBps: it is layered on top of the base trade
    // fee, not part of the protocol/buyback/creator split, and is paid to
    // the creator in full.
    uint256 public immutable creatorTaxBps;
    uint256 public immutable graduationThreshold;
    // Opening-window terms, frozen at deployment. `launchedAt` is set in the
    // constructor rather than in initialize() so the window cannot be extended
    // by delaying the wiring call, and so it stays immutable.
    uint64 public immutable launchedAt;
    uint16 public immutable snipeTaxStartBps;
    uint32 public immutable snipeTaxWindow;
    uint32 public immutable snipeTaxHalfLife;
    bool public buybackEnabled;
    // Written once, inside the launch transaction, by initialize(). There is
    // deliberately no setter: an exemption granted after launch would let a
    // creator wave a friendly address through the window that everyone else
    // paid to cross.
    mapping(address => bool) public snipeTaxExempt;

    uint256 public quoteFeeBalance;
    // The slice of `quoteFeeBalance` already earmarked for buyback-and-lock,
    // set aside as each fee was charged under whatever the buyback flag said
    // at that moment. Bucketing at accrual rather than deriving the slice at
    // sweep time keeps the flag forward-looking: toggling it decides how the
    // next trade's fee is split, never how an already-charged one is. It is
    // not a separate pot, only a marker on part of the pending balance, so
    // the protocol's share is still taken off the whole fee.
    uint256 public buybackQuoteBalance;
    uint256 public creatorTaxBalance;
    // Net real quote asset held from curve trading: buys add their value,
    // sell payouts and swept protocol/creator fees subtract theirs. Tracked
    // explicitly instead of reading a live balance, so a forced transfer in
    // (an ERC-20 airdrop, or ETH from a selfdestruct) can neither inflate
    // curve pricing nor push a launch past its graduation threshold with no
    // tokens actually sold.
    uint256 public trackedQuote;
    // Launch tokens this curve holds as tradeable reserve: set to the minted
    // allocation at initialize, reduced by buys and the internal buyback,
    // increased by sells. The token side needs the same treatment as the
    // quote side because both feed the constant-product price. Reading a
    // live balance would let any holder transfer tokens straight in to move
    // the curve's pricing, delay graduation past the point the launch's
    // economics were quoted at, and shift what the graduated pool opens at.
    uint256 public trackedTokens;
    bool public graduated;
    // Token balance the curve will never sell below, set once at initialize
    // and handed to the graduated pool intact. Everything above it is the
    // sellable allocation, and graduation is exactly its exhaustion.
    uint256 public reservedTokens;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyInitialized() {
        if (token == address(0)) revert NotInitialized();
        _;
    }

    /**
     * @param pairToken_ Quote asset for curve trading and the graduated pool; zero for native ETH.
     * @param deployer_ Token creator, credited as the creator fee recipient.
     * @param factory_ PonsV2LaunchFactory address, the only caller allowed through `onlyFactory`.
     * @param feePolicy_ Shared policy used only for the rotatable sweep operator.
     * @param policy_ Economic terms frozen for this launch's fee sweeps.
     * @param feeEscrow_ Shared claimable balance ledger for both ETH and ERC-20 revenue.
     * @param buybackVault_ Shared five-year vesting lock the buyback leg deposits into instead of burning.
     * @param phantomQuote_ Virtual quote reserve seeded at deploy, never physically held.
     * @param feeBps_ Trade fee in basis points, always charged on the quote leg.
     * @param creatorTaxBps_ Additional creator-chosen trade tax in basis points, layered on top of feeBps_.
     * @param buybackEnabled_ Whether this launch initially routes its configured fee share into buyback-and-lock.
     * @param graduationThreshold_ Real quote reserve required before graduation unlocks.
     */
    constructor(
        address pairToken_,
        address deployer_,
        address factory_,
        IPonsV2FeePolicy feePolicy_,
        FeePolicySnapshot memory policy_,
        IPonsV2FeeEscrow feeEscrow_,
        PonsV2BuybackVault buybackVault_,
        uint256 phantomQuote_,
        uint256 feeBps_,
        uint256 creatorTaxBps_,
        bool buybackEnabled_,
        uint256 graduationThreshold_,
        SnipeTaxTerms memory snipeTax_
    ) {
        if (deployer_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        if (address(feePolicy_) == address(0) || address(feeEscrow_) == address(0)) revert ZeroAddress();
        if (address(buybackVault_) == address(0)) revert ZeroAddress();
        if (
            policy_.protocolFeeRecipient == address(0) || policy_.protocolFeeShareBps > BASIS_POINTS
                || policy_.buybackBurnBps > BASIS_POINTS || policy_.maxInternalPriceImpactBps == 0
                || policy_.maxInternalPriceImpactBps >= BASIS_POINTS
        ) {
            revert InvalidFeePolicy();
        }
        // The factory applies the same ceiling before deploying, but the curve
        // defends its own invariant rather than inheriting it: a combined fee
        // at or above the whole trade would break the quote accounting.
        if (feeBps_ + creatorTaxBps_ > MAX_TOTAL_TRADE_FEE_BPS) revert InvalidFeePolicy();
        // Zero start disables the window; anything else has to describe a
        // window that actually closes, or a launch could tax buys forever.
        if (snipeTax_.startBps != 0) {
            if (snipeTax_.startBps > MAX_SNIPE_TAX_START_BPS) revert InvalidSnipeTaxTerms();
            if (snipeTax_.window == 0 || snipeTax_.halfLife == 0) revert InvalidSnipeTaxTerms();
            if (snipeTax_.halfLife > snipeTax_.window) revert InvalidSnipeTaxTerms();
            // The binding constraint for buy(): at maximum tax the gross-up
            // denominator is BASIS_POINTS minus all three legs, and it has to
            // stay comfortably positive. Checked here so buy() can rely on it
            // unconditionally rather than re-deriving it every call.
            if (feeBps_ + creatorTaxBps_ + snipeTax_.startBps > BASIS_POINTS - MIN_BUYER_SHARE_BPS) {
                revert InvalidSnipeTaxTerms();
            }
        } else if (snipeTax_.window != 0 || snipeTax_.halfLife != 0) {
            // Terms that look configured but do nothing are almost always a
            // caller mistake, and a silently inert window is worse than a
            // revert at launch.
            revert InvalidSnipeTaxTerms();
        }

        launchedAt = uint64(block.timestamp);
        snipeTaxStartBps = snipeTax_.startBps;
        snipeTaxWindow = snipeTax_.window;
        snipeTaxHalfLife = snipeTax_.halfLife;

        pairToken = pairToken_;
        deployer = deployer_;
        // Passed explicitly rather than read from msg.sender: PonsV2LaunchFactory
        // deploys this curve indirectly through PonsV2LaunchDeployer to keep its
        // own bytecode under EIP-170's size limit, so msg.sender at construction
        // time would otherwise resolve to that deployer helper, not the factory.
        factory = factory_;
        feePolicy = feePolicy_;
        feeEscrow = feeEscrow_;
        buybackVault = buybackVault_;
        protocolFeeRecipient = policy_.protocolFeeRecipient;
        buybackCreatorRecipient = deployer_;
        protocolFeeShareBps = policy_.protocolFeeShareBps;
        buybackBurnBps = policy_.buybackBurnBps;
        maxInternalPriceImpactBps = policy_.maxInternalPriceImpactBps;
        phantomQuote = phantomQuote_;
        feeBps = feeBps_;
        creatorTaxBps = creatorTaxBps_;
        buybackEnabled = buybackEnabled_;
        graduationThreshold = graduationThreshold_;
    }

    /**
     * @notice True when this launch trades and graduates against native ETH.
     */
    function isNativeQuote() public view returns (bool) {
        return pairToken == address(0);
    }

    /**
     * @notice Wires the launch token this curve dispenses. Called once by the
     * factory immediately after deploying the token with this curve's (now
     * known) address, before either contract is reachable by anyone else.
     *
     * @dev Also fixes the pool's token allocation, which is why this cannot
     * happen in the constructor: the supply is only known once the token
     * exists. Holding `phantomQuote * supply` constant, the curve reaches a
     * real quote reserve of `graduationThreshold` exactly when its token
     * balance falls to `supply * phantomQuote / (phantomQuote + threshold)`.
     * Reserving that balance therefore does not change where a launch
     * graduates, it only stops the curve selling through it: the quote
     * threshold and the token allocation are the same point, so whichever
     * one is used as the trigger, the graduated pool is seeded with the same
     * amounts at the same price on every launch.
     */
    function initialize(address token_, address launcher, address[] calldata snipeTaxExemptions)
        external
        onlyFactory
    {
        if (token != address(0)) revert AlreadyInitialized();
        if (token_ == address(0)) revert ZeroAddress();
        // Bounded, and written in the same transaction as the launch itself.
        if (snipeTaxExemptions.length > MAX_SNIPE_TAX_EXEMPTIONS) revert ExemptionListTooLong();
        // Both excused unconditionally. A creator paying a 99% levy to seed
        // their own launch would make this a tax on launching rather than a
        // tax on racing. `deployer` holds the creator fee recipient here.
        _exempt(launcher);
        _exempt(deployer);
        for (uint256 i = 0; i < snipeTaxExemptions.length; ++i) {
            _exempt(snipeTaxExemptions[i]);
        }
        token = token_;

        uint256 supply = IERC20(token_).totalSupply();
        uint256 reserved = Math.mulDiv(supply, phantomQuote, phantomQuote + graduationThreshold);
        // A launch whose allocation rounds away has nothing to seed its pool
        // with, and its final buy would revert against an empty token side.
        // Rejecting the config here fails at launch rather than at graduation.
        if (reserved == 0 || reserved >= supply) revert InvalidLaunchEconomics();
        reservedTokens = reserved;
        // The allocation the curve actually received, which is the whole
        // supply: the token mints to this curve in its own constructor.
        trackedTokens = IERC20(token_).balanceOf(address(this));

        emit Initialized(token_);
    }

    /**
     * @notice Tokens still available to buy before the curve graduates.
     */
    function sellableTokens() public view returns (uint256) {
        uint256 tracked = trackedTokens;
        return tracked > reservedTokens ? tracked - reservedTokens : 0;
    }

    /**
     * @notice Updates who receives creator fees from future sweeps.
     * Restricted to the factory, which gates both self-service creator
     * transfers and protocol-owner overrides before forwarding here, so
     * this contract only needs to trust one caller.
     */
    function setCreatorFeeRecipient(address newRecipient) external onlyFactory {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit CreatorFeeRecipientUpdated(deployer, newRecipient);
        deployer = newRecipient;
    }

    /**
     * @notice Enables or disables this launch's buyback-and-lock fee route.
     * The factory authorizes both the current creator recipient and protocol
     * owner before forwarding the setting here.
     * @dev Applies to fees charged from here on, not to fees already pending.
     * Each trade earmarks its buyback slice as it is charged, so a toggle
     * cannot reach back and reroute value that accrued under the opposite
     * setting. Without that, a disable landing before a sweep would divert a
     * buyback the creator had already earned into their own payout, and an
     * enable would sweep fees earned under a plain split into the vest.
     */
    function setBuybackEnabled(bool enabled) external onlyFactory {
        buybackEnabled = enabled;
        emit BuybackEnabledUpdated(enabled);
    }

    /**
     * @notice Returns the curve's current tradeable reserves, excluding fees pending sweep.
     */
    function getReserves() public view returns (uint256 quoteReserve_, uint256 tokenReserve_) {
        quoteReserve_ = phantomQuote + trackedQuote - quoteFeeBalance - creatorTaxBalance;
        tokenReserve_ = trackedTokens;
    }

    /**
     * @notice Tradeable quote reserve only, matching IPonsV2BondingCurve.
     */
    function quoteReserve() external view returns (uint256 quoteReserve_) {
        (quoteReserve_,) = getReserves();
    }

    /**
     * @notice Returns physically held tradeable quote asset, excluding virtual
     * liquidity and balances already earmarked as fees or creator tax.
     */
    function realQuoteReserve() public view returns (uint256) {
        return trackedQuote - quoteFeeBalance - creatorTaxBalance;
    }

    /**
     * @notice Tradeable token reserve only, matching IPonsV2BondingCurve.
     */
    function tokenReserve() external view returns (uint256 tokenReserve_) {
        (, tokenReserve_) = getReserves();
    }

    /**
     * @notice True once the curve's sellable allocation has been bought out.
     * @dev Equivalent to the real quote reserve reaching `graduationThreshold`,
     * since the reserved balance is derived from that same point. Expressed
     * against the token side because that is the one a buy cannot overshoot:
     * the quote side is a floor that a large trade could sail past, while the
     * token side is a hard stop the curve refuses to cross.
     */
    function readyToGraduate() public view returns (bool) {
        if (graduated) return false;
        return sellableTokens() == 0;
    }

    /**
     * @notice Buys the launch token with this launch's quote asset. The fee is
     * always taken from the quote leg, so this curve never holds a
     * memecoin-denominated fee.
     * @dev `quoteIn` must equal `msg.value` for a native launch, and must be
     * accompanied by no value at all for an ERC-20 launch. The credited
     * amount for an ERC-20 is the observed balance delta rather than the
     * requested amount, so a fee-on-transfer quote asset cannot make the
     * curve promise reserves it never received.
     *
     * A buy that would take the curve past its reserved allocation is filled
     * only up to that allocation, charged for what it actually received, and
     * refunded the difference. It is deliberately not rejected: the last buy
     * of a launch is the one most likely to be sized against a state someone
     * else has already moved, and reverting would let anyone grief it by
     * slipping a small buy in ahead.
     *
     * Partial fills reinterpret `minTokensOut` as a bound on price rather
     * than on quantity, since a caller who spends less than they offered
     * cannot expect the whole quantity they asked for. The requirement is
     * that the price paid is no worse than the price implied by the caller's
     * own arguments, and when nothing is clamped it reduces exactly to
     * `tokensOut >= minTokensOut`.
     */
    /**
     * @notice Opening buy tax in basis points that `recipient` would pay right
     * now. Zero once the window has closed, for an exempt address, or for a
     * launch configured without a window.
     *
     * @dev Exponential decay evaluated in integer arithmetic: the tax halves
     * every `snipeTaxHalfLife` seconds, with a linear interpolation between
     * halvings so the curve does not fall in visible cliffs. Deliberately not
     * a fixed-point exp(): this is read inside buy() on every trade, and an
     * approximation that is monotonically decreasing and provably bounded by
     * `snipeTaxStartBps` is worth more here than one that is precise.
     *
     * Keyed on the token recipient rather than msg.sender. Keying it on the
     * caller would mean any router — including one a sniper deploys — could
     * be exempted once and then resell entry to the window.
     */
    function _exempt(address account) private {
        // Duplicates and the zero address are skipped rather than rejected:
        // the list is assembled from three sources that do not know about each
        // other, and a cosmetic overlap should not fail a valid launch.
        if (account == address(0) || snipeTaxExempt[account]) return;
        snipeTaxExempt[account] = true;
        emit SnipeTaxExempted(account);
    }

    function currentSnipeTaxBps(address recipient) public view returns (uint256) {
        if (snipeTaxStartBps == 0 || snipeTaxExempt[recipient]) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed >= snipeTaxWindow) return 0;

        uint256 steps = elapsed / snipeTaxHalfLife;
        // Past sixteen halvings the result rounds to zero in basis points
        // anyway, and the shift below would be undefined for large shifts.
        if (steps >= 16) return 0;
        uint256 upper = uint256(snipeTaxStartBps) >> steps;
        uint256 lower = upper >> 1;
        uint256 into = elapsed % snipeTaxHalfLife;
        return upper - ((upper - lower) * into) / snipeTaxHalfLife;
    }

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        onlyInitialized
        returns (uint256 tokensOut)
    {
        if (graduated) revert CurveGraduated();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 received = _receiveQuote(quoteIn);
        if (received == 0) revert ZeroAmount();
        // graduate() is deliberately not nonReentrant and the factory's
        // trigger is permissionless, so a quote asset that yields control
        // during transferFrom can drain this curve between the check above
        // and the reserve reads below. Re-checking here rather than relying
        // on the downstream arithmetic to happen to revert.
        if (graduated) revert CurveGraduated();

        uint256 quoteReserveBefore = phantomQuote + trackedQuote - quoteFeeBalance - creatorTaxBalance;
        uint256 tokenReserveBefore = trackedTokens;

        // Read once and reused for the clamped-fill branch: a second read
        // would return the same value in the same block, but pinning it makes
        // the gross-up denominator provably the one the fill was priced with.
        uint256 snipeBps = currentSnipeTaxBps(recipient);

        uint256 spent = received;
        uint256 fee = (spent * feeBps) / BASIS_POINTS;
        uint256 tax = (spent * creatorTaxBps) / BASIS_POINTS;
        uint256 snipe = (spent * snipeBps) / BASIS_POINTS;
        tokensOut =
            PonsV2BondingCurveMath.getAmountOut(spent - fee - tax - snipe, quoteReserveBefore, tokenReserveBefore, 0);

        uint256 sellable = tokenReserveBefore > reservedTokens ? tokenReserveBefore - reservedTokens : 0;
        if (sellable == 0) revert CurveGraduated();

        if (tokensOut > sellable) {
            tokensOut = sellable;
            // Price the clamped fill from the token side, then gross the
            // result back up so the fee legs still come out of the input.
            // The denominator is bounded below by MIN_BUYER_SHARE_BPS by the
            // constructor's check, so it cannot approach zero here.
            uint256 net = PonsV2BondingCurveMath.getAmountIn(sellable, quoteReserveBefore, tokenReserveBefore, 0);
            spent = Math.min(
                Math.mulDiv(net, BASIS_POINTS, BASIS_POINTS - feeBps - creatorTaxBps - snipeBps, Math.Rounding.Ceil),
                received
            );
            fee = (spent * feeBps) / BASIS_POINTS;
            tax = (spent * creatorTaxBps) / BASIS_POINTS;
            snipe = (spent * snipeBps) / BASIS_POINTS;
        }

        // A buy that yields nothing is a buy that only pays fees. Reachable
        // for dust inside the opening window, where the levy consumes the
        // whole input before it reaches the curve. Refusing it is strictly
        // safer than settling it: nobody is denied a fill they would have
        // wanted, and the caller keeps their funds.
        if (tokensOut == 0) revert ZeroAmount();

        // Price bound rather than quantity bound, so a partial fill honours
        // the caller's terms instead of failing them. Identical to
        // `tokensOut >= minTokensOut` whenever `spent == received`.
        if (spent * minTokensOut > received * tokensOut) revert SlippageExceeded(tokensOut, minTokensOut);

        // The levy joins the base fee rather than travelling in its own
        // bucket, so it flows through the existing protocol / buyback /
        // creator split untouched. No new distribution path means no new
        // surface for it to be diverted through.
        _accrueFees(fee + snipe, tax);
        trackedQuote += spent;
        trackedTokens -= tokensOut;
        IERC20(token).safeTransfer(recipient, tokensOut);

        uint256 refund = received - spent;
        if (refund != 0) {
            emit CurveBuyRefunded(msg.sender, refund);
            _sendQuote(msg.sender, refund);
        }

        if (snipe != 0) emit SnipeTaxCharged(msg.sender, recipient, snipe, snipeBps);
        emit CurveBuy(msg.sender, recipient, spent, tokensOut, fee + snipe, tax);
        _tryAutoGraduate();
    }

    /**
     * @notice Sells the launch token back to the curve for the quote asset.
     * The fee is taken from the quote output, so it is always
     * quote-denominated here too.
     * @dev Closed once the sellable allocation is exhausted, not merely once
     * `graduated` is set. `_tryAutoGraduate` swallows a failed graduation so
     * a problem there cannot take the crossing buy down with it, which leaves
     * a window where the curve is ready but the flag is still false. `buy`
     * already refuses that state through its own `sellable == 0` check, and
     * `sell` has to match: `graduate` hands the pool whatever `trackedTokens`
     * holds, so a sell landing in the window would put tokens back on the
     * curve and take quote off it, and the pool would then be seeded deeper
     * and cheaper than the reserved allocation fixes it at. The deterministic
     * graduation price only holds if the window is closed on both sides.
     *
     * This cannot strand a holder. `graduate` is permissionless, so anyone
     * blocked here can settle the launch themselves in the same transaction
     * and trade the V4 pool instead.
     */
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient)
        external
        nonReentrant
        onlyInitialized
        returns (uint256 quoteOut)
    {
        if (graduated || readyToGraduate()) revert CurveGraduated();
        if (tokensIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        (uint256 quoteReserveBefore, uint256 tokenReserveBefore) = getReserves();
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);

        uint256 grossQuoteOut = PonsV2BondingCurveMath.getAmountOut(tokensIn, tokenReserveBefore, quoteReserveBefore, 0);
        uint256 fee = (grossQuoteOut * feeBps) / BASIS_POINTS;
        uint256 tax = (grossQuoteOut * creatorTaxBps) / BASIS_POINTS;
        quoteOut = grossQuoteOut - fee - tax;
        if (quoteOut < minQuoteOut) revert SlippageExceeded(quoteOut, minQuoteOut);

        _accrueFees(fee, tax);
        trackedQuote -= quoteOut;
        trackedTokens += tokensIn;
        _sendQuote(recipient, quoteOut);

        emit CurveSell(msg.sender, recipient, tokensIn, quoteOut, fee, tax);
    }

    /**
     * @notice Distributes pending quote fees across protocol, buyback-and-lock,
     * and the creator using this launch's frozen policy. The trusted sweep
     * operator is required when the sweep would execute an internal buyback.
     * The creator may still distribute fees when no swap is required.
     * @dev Reverts once graduated rather than silently no-op'ing. `graduate()`
     * already drains `quoteFeeBalance`/`creatorTaxBalance` to zero before
     * setting the flag, and trading is halted afterward so they can never
     * refill, but making the guard explicit here keeps that invariant
     * self-evident instead of depending on reasoning across two functions.
     */
    function sweepFees(uint256 minBuybackTokensOut) external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        bool isOperator = msg.sender == feePolicy.feeSweepOperator();
        if (!isOperator && msg.sender != deployer) {
            revert NotFeeSweepOperator();
        }
        if (!isOperator && _requiresTrustedOperator()) revert InternalSwapRequiresOperator();
        _sweepFees(minBuybackTokensOut, true);
    }

    /**
     * @notice Sweeps fees, halts trading, and hands the remaining tradeable
     * reserves to the factory so it can seed the graduated Uniswap V4 pool.
     * Because the curve already holds the pool's quote asset, the factory
     * receives exactly what it needs to seed with, and no conversion step
     * sits between the two. Restricted to the factory; deliberately not
     * `nonReentrant` since it may be invoked from within `buy()`'s own
     * reentrancy-guarded scope.
     */
    function graduate(address recipient) external onlyFactory returns (uint256 quoteOut, uint256 tokenOut) {
        if (graduated) revert AlreadyGraduated();
        if (recipient == address(0)) revert ZeroAddress();
        if (!readyToGraduate()) revert NotReadyToGraduate();

        // Halt trading before the sweep, not after. The sweep pays the escrow,
        // and a quote asset with a transfer callback can re-enter buy() or
        // sell() from inside that payment. This function is deliberately not
        // nonReentrant so it stays callable from within buy()'s own guarded
        // scope, so the flag is the only thing closing that window. Reentering
        // while it was still false repopulated the fee buckets after they had
        // been zeroed, leaving balances with no quote behind them once the
        // reserve was handed over, and no way to ever sweep them.
        //
        // Safe to set here: readyToGraduate() is already evaluated above, and
        // the private _sweepFees never reads the flag.
        graduated = true;

        // Graduation may be triggered by any caller or by the threshold-
        // crossing buyer. Skip the buyback rather than execute a predictable
        // market order without the sweep operator's minimum output.
        _sweepFees(0, false);

        // Hand over only the tracked trading reserves. Any quote asset or
        // launch token force-sent to this curve is deliberately left stranded
        // here rather than folded into the graduated pool's seed, so a
        // donation cannot move the price the pool opens at.
        quoteOut = trackedQuote;
        trackedQuote = 0;
        tokenOut = trackedTokens;
        trackedTokens = 0;

        if (quoteOut != 0) {
            _sendQuote(recipient, quoteOut);
        }
        if (tokenOut != 0) {
            IERC20(token).safeTransfer(recipient, tokenOut);
        }

        emit CurveCompleted(recipient, quoteOut, tokenOut);
    }

    /**
     * @dev Pulls `amount` of the quote asset from the caller and returns the
     * amount actually received. Native launches take it from `msg.value`;
     * ERC-20 launches measure the balance delta so a fee-on-transfer quote
     * asset is credited for what arrived, not what was asked for.
     */
    function _receiveQuote(uint256 amount) private returns (uint256) {
        if (isNativeQuote()) {
            if (msg.value != amount) revert NativeValueMismatch(msg.value, amount);
            return amount;
        }

        if (msg.value != 0) revert UnexpectedNativeValue();
        IERC20 quote = IERC20(pairToken);
        uint256 balanceBefore = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), amount);
        return quote.balanceOf(address(this)) - balanceBefore;
    }

    /**
     * @dev Pays `amount` of the quote asset out to `recipient`.
     */
    function _sendQuote(address recipient, uint256 amount) private {
        if (isNativeQuote()) {
            (bool sent,) = payable(recipient).call{value: amount}("");
            if (!sent) revert TransferFailed();
            return;
        }
        IERC20(pairToken).safeTransfer(recipient, amount);
    }

    /**
     * @dev Credits `amount` of the quote asset to `recipient`'s claimable
     * escrow balance, using whichever of the escrow's two ledgers matches.
     */
    function _creditQuote(address recipient, uint256 amount) private {
        if (isNativeQuote()) {
            feeEscrow.credit{value: amount}(recipient);
            return;
        }
        IERC20(pairToken).forceApprove(address(feeEscrow), amount);
        feeEscrow.creditToken(recipient, pairToken, amount);
    }

    /**
     * @dev Attempts to graduate the instant a buy crosses the threshold, so
     * the crossing trade itself triggers the migration atomically. Wrapped in
     * try/catch: if graduation reverts for any reason (for example a pool the
     * factory cannot yet seed), the underlying buy must still succeed, and
     * graduation stays permissionlessly retryable via the factory.
     *
     * A failure is announced rather than swallowed silently. The crossing
     * buyer sets their own gas limit and can starve this call under the 63/64
     * rule, pushing graduation's cost onto whoever calls next, so the event is
     * what lets a keeper notice a launch sitting ready but ungraduated.
     */
    function _tryAutoGraduate() private {
        if (readyToGraduate()) {
            try IPonsV2LaunchFactoryGraduation(factory).graduate(token) {}
            catch {
                emit AutoGraduationFailed(token, gasleft());
            }
        }
    }

    /**
     * @dev Books a trade's base fee and creator tax, earmarking the buyback
     * slice at the moment the fee is charged. The slice comes out of the
     * creator's bucket alone, so it is measured against what remains after
     * the protocol's share, and the tax never enters the split at all.
     */
    function _accrueFees(uint256 fee, uint256 tax) private {
        quoteFeeBalance += fee;
        creatorTaxBalance += tax;
        if (buybackEnabled && fee != 0) {
            uint256 creatorSlice = fee - (fee * protocolFeeShareBps) / BASIS_POINTS;
            buybackQuoteBalance += (creatorSlice * buybackBurnBps) / BASIS_POINTS;
        }
    }

    /**
     * @dev Returns whether a pending base-fee balance would execute a
     * pool-priced buyback. The creator can distribute direct fees but cannot
     * choose a permissive price floor for inventory shared with the protocol.
     */
    function _requiresTrustedOperator() private view returns (bool) {
        return buybackQuoteBalance != 0;
    }

    /**
     * @dev Splits pending quote fees into protocol / buyback-and-lock /
     * creator using the launch's frozen policy, swapping the buyback slice for
     * the memecoin against this curve's own reserves before locking it into
     * the shared five-year vest instead of burning it. Reserves for the swap
     * are read before `quoteFeeBalance` is cleared, so the entire pending
     * balance is correctly excluded from the pre-swap tradeable reserve. The
     * buyback's price impact is bounded by the same `maxInternalPriceImpactBps`
     * the post-graduation hook enforces on its own internal swaps, and its size
     * by the same `reservedTokens` floor `buy` respects. A caller cannot
     * execute the swap without supplying an explicit output floor.
     */
    function _sweepFees(uint256 minBuybackTokensOut, bool executeBuyback) private {
        uint256 pending = quoteFeeBalance;
        uint256 tax = creatorTaxBalance;
        if (pending == 0 && tax == 0) return;

        uint256 protocolAmount = (pending * protocolFeeShareBps) / BASIS_POINTS;
        uint256 creatorBucket = pending - protocolAmount;
        // The earmark was summed per trade, so its rounding can land a wei or
        // two above the bucket recomputed here on the aggregate. Clamping
        // keeps the subtraction below sound at a full buyback share, where
        // the two would otherwise be equal.
        uint256 buybackAmount = executeBuyback ? Math.min(buybackQuoteBalance, creatorBucket) : 0;
        // The creator tax bypasses the protocol/buyback split entirely: it is
        // charged on top of the base fee and paid to the creator in full.
        uint256 creatorAmount = creatorBucket - buybackAmount + tax;

        uint256 tokensLocked;
        if (buybackAmount != 0) {
            if (minBuybackTokensOut == 0) revert MinimumOutputRequired();
            (uint256 quoteReserve_, uint256 tokenReserve_) = getReserves();
            // This reserve-movement ratio is equivalent to the hook's
            // sqrtPriceX96 limit for a constant-product quote-to-token swap.
            uint256 reserveMovementBps = (buybackAmount * BASIS_POINTS) / (quoteReserve_ + buybackAmount);
            if (reserveMovementBps <= maxInternalPriceImpactBps) {
                // The non-reverting quote, so a curve too thin to price the
                // buyback reaches the fold-back below instead of taking the
                // whole fee sweep down with it.
                uint256 tokensOut =
                    PonsV2BondingCurveMath.quoteAmountOut(buybackAmount, quoteReserve_, tokenReserve_, 0);
                // The buyback takes tokens off the same reserve `buy` does, so
                // it answers to the same floor. Only the balance above
                // `reservedTokens` is sellable; the remainder is the graduated
                // pool's allocation. As a launch nears graduation the sellable
                // amount approaches zero and the buyback folds back into the
                // creator payout below rather than eating into that allocation.
                if (tokensOut != 0 && tokensOut <= sellableTokens()) {
                    tokensLocked = tokensOut;
                }
            }
            if (tokensLocked == 0) {
                // Curve too shallow or the buyback would move its price too
                // far; fold it back into the creator's payout instead.
                creatorAmount += buybackAmount;
                buybackAmount = 0;
            } else if (tokensLocked < minBuybackTokensOut) {
                // Only a buyback that actually executes is subject to the
                // caller's minimum. Applying it to the fold-back branch would
                // make that branch unreachable, since every accepted argument
                // is above the zero it produces, and pending fees would be
                // stranded exactly when the curve is too thin to buy back.
                revert SlippageExceeded(tokensLocked, minBuybackTokensOut);
            }
        }

        quoteFeeBalance = 0;
        // Cleared unconditionally. Whether the buyback executed, folded back
        // into the creator's payout, or was skipped outright by graduation,
        // the fees behind the earmark have now been distributed.
        buybackQuoteBalance = 0;
        creatorTaxBalance = 0;
        // Protocol and creator amounts leave the contract; the buyback slice
        // stays as tradeable reserve, so only the paid-out legs reduce the
        // tracked quote balance.
        trackedQuote -= protocolAmount + creatorAmount;

        if (tokensLocked != 0) {
            // The buyback buys the memecoin off this curve's own reserve, so
            // the tokens it locks leave the tradeable side.
            trackedTokens -= tokensLocked;
            IERC20(token).forceApprove(address(buybackVault), tokensLocked);
            buybackVault.lock(token, tokensLocked, buybackCreatorRecipient, protocolFeeRecipient, protocolFeeShareBps);
            emit BuybackLocked(buybackAmount, tokensLocked);
        }
        if (protocolAmount != 0) {
            _creditQuote(protocolFeeRecipient, protocolAmount);
        }
        if (creatorAmount != 0) {
            _creditQuote(deployer, creatorAmount);
        }

        emit FeesSwept(protocolAmount, buybackAmount, creatorAmount);
    }

    /**
     * @notice Pays this curve's pending fees straight to the protocol and
     * creator recipients, bypassing the escrow. Restricted to the factory,
     * which gates it on the protocol owner.
     *
     * @dev Exists because an ordinary sweep routes every payout through
     * PonsV2FeeEscrow, and a permissioned quote asset can stop delivering to
     * that one address while still permitting transfers between traders and
     * this curve. Trading then continues normally, but the fees are
     * unreachable, and graduation is unreachable with them: `graduate` sweeps
     * before it hands over the reserves, and fees accrue from the first
     * trade, so the sweep is never a no-op by the time the threshold is
     * crossed. The launch would be stuck on its curve forever.
     *
     * Clearing the buckets here is what unblocks that: the sweep inside
     * `graduate` then finds nothing pending and returns early, so graduation
     * proceeds without this function needing to touch it.
     *
     * The buyback slice is deliberately skipped rather than executed. It
     * would have to settle through the vault and the same escrow, which is
     * the dependency this path exists to route around, so the whole creator
     * bucket is paid out directly instead.
     *
     * Mirrors PonsV2MemeHook.rescuePoolFees for the post-graduation pool and
     * PonsV2LaunchFactory.rescueSweptGraduation for the reserves in between.
     */
    function rescueFees() external onlyFactory returns (uint256 protocolAmount, uint256 creatorAmount) {
        uint256 pending = quoteFeeBalance;
        uint256 tax = creatorTaxBalance;
        if (pending == 0 && tax == 0) revert ZeroAmount();

        protocolAmount = (pending * protocolFeeShareBps) / BASIS_POINTS;
        creatorAmount = pending - protocolAmount + tax;

        quoteFeeBalance = 0;
        // Symmetrical with the sweep. This pays the creator their whole
        // bucket, earmark included, so leaving the earmark behind would let a
        // settled claim survive into the next accrual and divert fees the
        // creator has not earned yet into the vest.
        buybackQuoteBalance = 0;
        creatorTaxBalance = 0;
        trackedQuote -= protocolAmount + creatorAmount;

        if (protocolAmount != 0) _sendQuote(protocolFeeRecipient, protocolAmount);
        if (creatorAmount != 0) _sendQuote(deployer, creatorAmount);

        emit FeesRescued(protocolFeeRecipient, deployer, protocolAmount, creatorAmount);
    }
}
