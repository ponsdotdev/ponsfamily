# Two-way creator-fee splitter

`PonsV2TwoWayFeeSplitter` is an optional creator-fee recipient for teams that
want to divide pons v2 proceeds between two fixed wallets. It supports native
ETH and every ERC-20 supported by the pons fee escrow.

The recipients and ratio are immutable. Each recipient's share is configured as
an integer number of units, both shares must be non-zero and add to 20, and each
unit represents 5%. The supported range is therefore 5%/95% through 95%/5%.
Fractional remainders carry across allocations, so splitting funds into many
small allocations produces the same result as allocating the total once.

Either recipient's accrued balance can be released independently, so a
recipient that rejects ETH does not block the other recipient.

## Deploy

This example assigns 80% to `recipientOne` and 20% to `recipientTwo` while
preserving the two pons creator-control calls through an immutable controller:

```solidity
PonsV2TwoWayFeeSplitter splitter = new PonsV2TwoWayFeeSplitter(
    feeEscrow,
    payable(recipientOne),
    payable(recipientTwo),
    16, // 80%
    4,  // 20%
    IPonsV2CreatorControls(address(launchFactory)),
    controller
);
```

For a completely ownerless deployment, permanently disable creator controls by
setting both final constructor arguments to zero:

```solidity
PonsV2TwoWayFeeSplitter splitter = new PonsV2TwoWayFeeSplitter(
    feeEscrow,
    payable(recipientOne),
    payable(recipientTwo),
    16, // 80%
    4,  // 20%
    IPonsV2CreatorControls(address(0)),
    address(0)
);
```

Disabling controls means the splitter can never call
`transferCreatorFeeRecipient` or `setBuybackEnabled` for a launch that names it
as the creator fee recipient. A configured controller can invoke only those two
factory calls; it cannot change the split, replace itself, or move accrued funds
to any other wallet.

## Launch with the splitter

Pass the deployed splitter as `creatorFeeRecipient` when constructing the
factory's token parameters:

```solidity
PonsV2LaunchFactory.TokenParams memory params = PonsV2LaunchFactory.TokenParams({
    name: name,
    symbol: symbol,
    logo: logo,
    description: description,
    socials: socials,
    creatorFeeRecipient: address(splitter),
    creatorTaxBps: creatorTaxBps,
    buybackEnabled: buybackEnabled,
    expectedEconomics: expectedEconomics,
    salt: salt
});

(address token, address curve) = launchFactory.launchToken{value: launchFee}(
    params,
    launchConfigId,
    pairToken
);
```

The split applies to the creator proceeds credited by pons after the protocol
and optional buyback shares have been calculated. It does not alter pons's fee
policy or divide the launched token's supply.

## Claim and release

All operational functions are permissionless. A keeper, either recipient, or
any third party may call them:

```solidity
splitter.claimNativeFromPons();
splitter.releaseNative(recipientOne);
splitter.releaseNative(recipientTwo);

splitter.claimTokenFromPons(IERC20(pairToken));
splitter.releaseToken(IERC20(pairToken), recipientOne);
splitter.releaseToken(IERC20(pairToken), recipientTwo);
```

Direct transfers are handled with `allocateNative()` and `allocateToken(token)`.
Failed releases preserve the recipient's pending balance for a later retry.
