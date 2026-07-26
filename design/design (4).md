# THE ZONE AGORA — Design Direction

Version 2.0  
Updated: 2026-07-26  
Primary asset: `the-zone-agora-logo.svg`

## 1. Product idea

THE ZONE AGORA is trusted personal investment infrastructure powered by AgoraAgent.

The user does not browse competing Agents, follow a strategy creator, pay a Follow fee, or select a Crypto asset. The product should communicate one simple promise:

> Deposit with control. Agora operates within limits. Withdraw when you choose.

The experience must feel like established financial infrastructure: calm, inspectable and protective.

## 2. User journey

```text
Sign up
→ Connect wallet
→ Create personal Vault
→ Deposit USDC
→ AgoraAgent operates automatically
→ Review performance and risk
→ Withdraw to Wallet
```

Do not introduce the following screens:

- Agent Marketplace
- Agent comparison or Agent selection
- Follow button or Follow fee
- Crypto picker
- Signal Provider picker
- User-paid x402 confirmation

Signal Provider selection and x402 payment are internal AgoraAgent operations.

## 3. Brand attributes

- Trustworthy, not promotional
- Protective, not paternalistic
- Autonomous, not opaque
- Technical, not complicated
- Calm, not passive
- Crypto-native, not crypto-cliché
- Evidential, not speculative

## 4. Logo system

Use the signal-orange mark on a near-black rounded-square field.

- Field: `#11100F`
- Mark: `#FF5A1F`
- Canvas ratio: `1:1`
- Corner radius: `21.875%`
- The mirrored forms represent the user-controlled Vault and AgoraAgent operating across a protected center.
- The center remains open and represents the boundary where policy and custody are enforced.

Approved combinations:

| Use | Background | Mark |
| --- | --- | --- |
| Primary app icon | Near Black | Signal Orange |
| Light surface | Warm Ivory | Signal Orange |
| Orange campaign field | Signal Orange | Warm Ivory |
| Monochrome dark | Near Black | Warm Ivory |
| Monochrome light | Warm Ivory | Near Black |

Do not apply gradients, glow, bevels, shadows or crypto-coin imagery to the mark.

## 5. Color

| Token | Hex | Role |
| --- | --- | --- |
| `agora-orange` | `#FF5A1F` | Brand and primary action |
| `arena-black` | `#11100F` | Navigation and high-contrast surfaces |
| `warm-ivory` | `#FFF8ED` | Main light background |
| `surface-dark` | `#1B1917` | Dark cards |
| `surface-light` | `#F4EDE3` | Light cards and dividers |
| `muted-dark` | `#8D857B` | Secondary text |
| `muted-light` | `#B9B0A5` | Secondary dark-surface text |
| `positive` | `#24C77A` | Profit and healthy state |
| `negative` | `#F04F5F` | Loss and failure |
| `warning` | `#F6B73C` | Risk approaching limit |
| `neutral` | `#7F8A99` | Inactive or comparison data |

Orange is a signal, not a wallpaper. Never use orange alone to represent profit or loss.

## 6. Typography

Use Inter for product UI.

- Display: Inter Tight 600–700
- Interface headings: Inter 600
- Body and labels: Inter 400–500
- Financial numbers: Inter 500–600 with tabular numerals

Amounts, return, drawdown, current status and withdrawable balance are primary content.

## 7. Layout

Use a 4px grid.

| Token | Value |
| --- | ---: |
| `space-1` | 4px |
| `space-2` | 8px |
| `space-3` | 12px |
| `space-4` | 16px |
| `space-6` | 24px |
| `space-8` | 32px |
| `space-12` | 48px |

- Mobile margin: 20px
- Desktop: 12 columns, 24px gutters, max-width 1440px
- Major container radius: 24px
- Standard card radius: 16px
- Control radius: 12px

Avoid filling every surface with cards. Separate custody, performance and risk information clearly.

## 8. Primary screens

### 8.1 Onboarding

Show only:

1. Service explanation
2. Wallet connection
3. Vault creation
4. USDC deposit amount
5. Risk and custody acknowledgement

Do not show Agent or Crypto selection.

The app automatically uses:

- AgoraAgent operator address
- USDC Fiat type
- Agora-configured MVP investment type

### 8.2 Home dashboard

The opening screen answers:

1. How much is deposited?
2. What is the current value?
3. What has AgoraAgent done?
4. What is the current risk state?
5. How much can the user withdraw?

Recommended hierarchy:

```text
Total Vault Value
→ Net Return
→ Available USDC
→ Invested Position
→ AgoraAgent Status
→ Recent Decisions
```

### 8.3 Activity

Each AgoraAgent decision should show:

- BUY or SELL
- amount
- timestamp
- Vault ID abbreviation
- signal digest abbreviation
- risk score
- transaction status

Do not expose private Signal Provider response bodies. Provider-level details are internal unless an explicit transparency policy is introduced.

### 8.4 Risk controls

Show the three states clearly:

```text
ACTIVE       BUY and SELL enabled
REDUCE_ONLY  New BUY disabled, SELL enabled
PAUSED       Automated BUY and SELL disabled
```

Use plain-language explanations beside technical labels.

### 8.5 Deposit and withdrawal

Primary user capital actions:

- `Deposit USDC`
- `Withdraw to Wallet`
- `Withdraw All`

Secondary safety actions:

- `Reduce Risk`
- `Pause Automation`
- `Resume Automation`

Never use:

- `Follow`
- `Select Agent`
- `Choose Crypto`
- `Pay Agent`

## 9. Gas communication

Wallet connection and account creation:

```text
No network gas
```

User-signed onchain actions:

```text
Create Vault
Deposit USDC
Withdraw to Wallet
Owner risk-setting changes
```

Agora-paid operations:

```text
Signal Provider x402 payment
Automated BUY/SELL
Future DEX execution
```

Recommended copy:

> Agora covers network gas for automated investment operations. User-signed Vault creation, deposits and withdrawals may require Sui network gas.

Do not claim that the blockchain operation itself has no gas.

## 10. Data visualization

- Use orange for the Agora-managed primary portfolio line.
- Use green and red only for positive and negative outcomes.
- Always place maximum drawdown beside return.
- Prefer direct labels and restrained gridlines.
- Do not recreate a competitive Agent leaderboard.
- Do not rank Signal Providers in the user interface.

## 11. Motion

- Default duration: 160–240ms
- Major transition: up to 360ms
- Easing: `cubic-bezier(0.22, 1, 0.36, 1)`
- Status changes should be visible but restrained.
- PAUSED and REDUCE_ONLY transitions require explicit confirmation.

Avoid game-like ranking animation, collisions, particles and trading-floor visual noise.

## 12. Voice

Use:

- `Your Vault is active.`
- `AgoraAgent reduced portfolio risk.`
- `USDC deposit confirmed.`
- `Automated investing is paused.`
- `Withdrawal sent to your Wallet.`
- `Signal verified. Decision recorded.`

Avoid:

- `Choose your winning Agent.`
- `Follow the top trader.`
- `Capital follows winners.`
- `Pick the next 100x coin.`
- `Guaranteed return.`

## 13. Accessibility

- Meet WCAG AA contrast.
- Never rely on color alone.
- Pair ACTIVE, REDUCE_ONLY and PAUSED with text and icons.
- Display full amounts in accessible labels.
- Support reduced motion.
- Make wallet signatures explain the exact capital action.

## 14. Product truth

The UI must not imply that a BUY/SELL request is a completed DEX trade while the current contract only records requests.

Until atomic DEX settlement exists:

- Label actions as `Requested` or `Decision recorded`.
- Do not show filled-price or received-amount data unless verified onchain.
- Explain that Vault balances do not change from the request alone.

## 15. Design review checklist

- [ ] No Agent selection or Follow UX
- [ ] No Crypto picker
- [ ] No user-paid x402 flow
- [ ] USDC deposit is the primary funding action
- [ ] AgoraAgent status is visible
- [ ] Owner withdrawal is always discoverable
- [ ] Risk is visible beside performance
- [ ] Gas payer is explained accurately
- [ ] Request and completed trade states are not confused
- [ ] No guaranteed-return language
