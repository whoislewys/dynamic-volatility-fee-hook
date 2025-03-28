# Implied Volatility Targeting AMM (IVTAMM)
A constant volatility AMM whose target IV updates every 24h

> If this all sounds like gobbledygook, the accompanying [presentation slides](https://docs.google.com/presentation/d/1jCp-SuyTim06hW_l5-1I3oMCFRgwk7tOSNA9bu1pGqI/edit?usp=sharing) will help quite a bit.

This project is best understood in two parts
1. A Constant Volatility AMM
2. Calculating a sensible target implied volatility using for current market conditions, and using that to set the target volatility of a Constant Volatility AMM.

## 1. Constant Volatility AMM
Implementation of [constant (implied) volatility AMM](https://lambert-guillaume.medium.com/designing-a-constant-volatility-amm-e167278b5d61#:~:text=TL%3BDR%3A%20Constant%20volatility%20AMMs,dynamics%20of%20the%20underlying%20assets.) as a Uniswap V4 hook using V4's dynamic fee capability in `beforeSwap`.

## 2. Adjusting Target Volatility
The target implied volatility is calculated with a zk coprocessor (Brevis) with *strictly* on-chain historical data.
