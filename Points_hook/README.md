# Building first hook 

A really simple "points hook"

Assume you have some ETH/TOKEN pool that exists. We wanna make a hook that can be attached to such kinds of pools where:

Aim: 

Every time somebody swaps ETH for TOKEN (i.e. spends ETH, purchases TOKEN) - we issue them some "points"

> A simple project based on PoC

a Proof of Concept (PoC) is a prototype or early implementation designed to demonstrate the feasibility of a decentralized application (dApp), protocol, smart contract, or blockchain-based solution.

### Design 
---
1. How many points do we give out per swap?

We're going to give 20% of the ETH spent in the swap in the form of points

e.g. if someone sells 1 ETH to purchase TOKEN, they get 20% of 1 = 0.2 POINTS

2. How do we represent these points?

Points themselves are going to be an ERC-1155 token.

ERC-1155 allows minting "x" number of tokens that are distinct based on some sort of "key"

Since one hook can be attached to multipple pools, ETH/A, ETH/B, ETH/C -

points = minting some amount of ERC-1155 tokens for that pool to the user
> Q: why not use ERC-6909 for doing this?

> A: you totally can! erc-1155 is just a bit more familiar to people so for the first workshop i wanted to stick with this

### beforeSwap vs afterSwap

we're giving out points as a & of the amount of ETH that was spent in the swap
how much ETH was spent in the swap?
this is not a question that can be answered in 'beforeSwap because it is literally unknown until the swap happens

1. potentially, slippage limits could hit causing only a partial swap to happen           
e.g. Alice could've said sell 1 ETH for TOKEN, but slippage limit is hit, and only 0.5 ETH was actually swapped
2. there are broadly two types of swaps that uniswap can do. these are referred to as exact-input and exact-output swaps.         
e.g. ETH/USDC pool. Alice wants to swap ETH for USDC.
exact input variant = Sell 1 ETH for USDC
e.g. she is "exactly" specifying how much ETH to sell, but not specifying how much USDC to get back
exact output variant = Sell UP TO 1 ETH for exactly 1500 USDC
e.g. she is "exactly" specifying how much USDC she wants back, and only a upper limit on how much ETH she's willing to spend

---
the "BalanceDelta" thing we have in 'afterSwap becomes very crucial to our use case
because 'BalanceDelta' = the exact amount of tokens that need to be transferred (how much ETH was spent, how much TOKEN to withdraw)


TL;DR: we gotta use 'afterSwap because we do not know how much ETH Alice spent before the swap happens

### miniting points to user 

who do we mint points to actually ?

Do we know the address of the user that made the swap ?
Do we have Alice's address?

Answer:  NO

Alice -> Router -> Pool Manager
                -> msg.sender = Router
                        -> Hook.afterSwap(sender)
                        address = Router address
                        msg.sender = Pool Manager

---

ok we cannot use 'sender' or 'msg.sender'

maybe we can use 'tx.origin'. is that true?

if Alice is using an account abstracted wallet (SC wallet)

'tx.origin' = address of the relayer

GENERAL PURPOSE: 'tx.origin' doesnt work either
--- 

how tf do we figure out who to mint points to

we're gonna ask the user to give us an address to mint points to (optionally)

if they don't specify an address/invalid address = don't mint any points

Now the issue is how do we get the address from the user and pass it throughout the chain => Solution: HookData

#### hookData

hookData allows users to pass in arbitrary information meant for use by the hook contract

Alice → Router. swap (...•, hookData) -> PoolManager.swap(...•, hookData) →> HookContract.before.. (..•, hookData)

the hook contract can figure out what it wants to do with that hookData

in our case, we're gonna use this as a way to ask the user for an address

to illustrate the concept a bit better, a couple examples of better ways to use hookData

e.g. KYC hook for example
verify a ZK Proof that somebody is actually a verified human (World App ZK Proof)
hook only lets you swap/become an LP if youre a human

ZK Proof => hookData