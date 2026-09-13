# Security policy

If you found a bug that can steal funds, break a lock, strand reserves,
mint, bypass a fee, or otherwise put launch or trade funds at risk, send
it here. Do not open a public GitHub issue or a public pull request that
contains the bug.

## How to report

1. Open a private advisory:
   https://github.com/ponsdotdev/ponsfamily/security/advisories/new
2. If you cannot use GitHub, email contact@ponsfamily.com with the
   subject "Security".

The mailbox is also used for ordinary support. Mark the mail so it is
not treated as an integration question.

Do not send private keys, seed phrases, or wallet credentials.

## What to include

- Contracts and files (path + commit, or the live address)
- What an attacker can do, and whose funds it hits
- Steps on a local fork. A mainnet transaction is not required.
- Any special preset, pair token, or factory owner action needed

A write-up without a reachable loss or lock-break path is still welcome.
We may treat it as a design note rather than a vulnerability.

## In scope

- First-party contracts in `contractsV1/` and `contractsV2/`
- The live factories, when the bytecode matches this repo:
  - V1 `PonsLaunchFactory` `0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB`
  - V2 `PonsV2LaunchFactory` `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e`
- Launch, curve, graduation, locker, hook, fee escrow, and buyback vault
  behavior that can move or freeze user or protocol funds

Only the bytecode that is live and matches the verified sources is
supported. Forks and unverified deploys are not.

## Out of scope

- OpenZeppelin or Uniswap bugs that are not caused by how we call them
- Missing headers, scanner dumps, or theoretical issues with no path
- Public-mempool MEV / ordinary sandwiching, unless a contract bug
  makes it strictly worse than a normal Uniswap pool
- Griefing or draining a live launch to prove the report
- Social engineering, physical access, or knocking the website over
- The website and docs, unless the bug is "this UI points at the wrong
  factory." Product and phishing reports can go to the same email.

## How we handle it

We will acknowledge a clear report within two business days and say
whether we think it is real.

These contracts are deployed. A fix may be a new factory and a public
notice, not an in-place patch. We will tell you before we publish
detail. Please wait until we have a path for users, or 90 days, before
you write it up. If we are silent past that, you can publish.

We will credit you in the advisory if you want that. There is no bug
bounty.

Good-faith research on a local fork, reported privately, will not get
you a lawyer. Exploiting a live launch, holding user funds, or posting
the bug in Issues or on X is not good faith.

A hardening pull request that closes a hole without showing how to
empty a launch is fine. Anything that is a working steal stays private.
