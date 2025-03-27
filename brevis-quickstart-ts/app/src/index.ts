import { Brevis, ErrCode, ProofRequest, Prover, ReceiptData, Field, StorageData } from 'brevis-sdk-typescript';
import fs from 'fs';
import { ethers } from 'ethers';
import invariant from 'tiny-invariant';
import { mainnet, sepolia } from 'viem/chains';
import type { Address, Client, Hex, WalletClient } from 'viem';
import {
    toHex,
    createClient,
    createWalletClient,
    getAddress,
    http,
    isAddress,
    isHex,
    maxUint256,
    parseAbi,
    parseAbiItem,
    webSocket,
} from 'viem';
import {
    multicall,
    readContract,
    getStorageAt,
    getContractEvents,
    sendTransaction,
    getBlock,
    waitForTransactionReceipt,
    watchBlocks,
    writeContract,
    getLogs,
} from 'viem/actions';
import dotenv from 'dotenv';
dotenv.config(); // put .env vars into process.env

import { abi as V3PoolAbi } from './v3pool';
import { privateKeyToAccount } from 'viem/accounts';

/*
    ___ _   _ ___ _____      _    ____ ____ ___  _   _ _   _ _____ 
   |_ _| \ | |_ _|_   _|    / \  / ___/ ___/ _ \| | | | \ | |_   _|
    | ||  \| || |  | |     / _ \| |  | |  | | | | | | |  \| | | |  
    | || |\  || |  | |    / ___ \ |__| |__| |_| | |_| | |\  | | |  
   |___|_| \_|___| |_|   /_/   \_\____\____\___/ \___/|_| \_| |_|  
                                                                   
*/

export const blockTimesInSeconds: Record<number, number> = {
    [mainnet.id]: 12,
    // [unichain.id]: 1, // TODO: update to 0.25 when they upgrade
    [sepolia.id]: 12,
    // [arbitrum.id]: 0.25,
    // [optimism.id]: 2,
    // [base.id]: 2,
};

export const intervalToSeconds = {
    '1d': 86400,
    '1h': 3600,
    '6h': 21600,
    '12h': 43200,
};

/**
 * Generates an array of approximate block numbers, oldest to newest, based on the specified parameters.
 *
 * @param {Object} params - The parameters for generating block numbers.
 * @param {number} params.initialTimestampSec - The timestamp to look back from in seconds.
 * @param {Object} params.latestBlock - The latest block information.
 * @param {bigint} params.latestBlock.number - The number of the latest block.
 * @param {bigint} params.latestBlock.timestamp - The timestamp of the latest block.
 * @param {'1d' | '1h'} params.interval - The time interval for each period ('1d' for 1 day, '1h' for 1 hour).
 * @param {number} params.numberOfPeriods - The desired amount of block numbers to generate.
 * @param {number} params.chainId - The chain ID to use for block time approximation.
 * @returns {number[]} An array of approximate block numbers representing each period, ordered from oldest to newest.
 * @throws {Error} Throws an error if numberOfPeriods is less than 1, if the chainId is not recognized, or if the generated block numbers don't match the requested number of periods.
 */
export function approximateBlocksForTimestamp({
    initialTimestampSec,
    latestBlock,
    interval,
    numberOfPeriods,
    chainId,
}: {
    initialTimestampSec: number;
    latestBlock: { number: bigint; timestamp: bigint };
    interval: '1d' | '1h';
    numberOfPeriods: number;
    chainId: number;
}): { number: number; timestamp: number }[] {
    invariant(numberOfPeriods >= 1, '[approximateBlocksForTimestamp] numberOfPeriods must be >= 1');
    invariant(chainId in blockTimesInSeconds, `[approximateBlocksForTimestamp] Unrecognized chainId: ${chainId}`);

    const blockTime = blockTimesInSeconds[chainId];
    const intervalSeconds = intervalToSeconds[interval];

    // Calculate the estimated block number at the initial timestamp
    const timeDifference = Number(latestBlock.timestamp) - initialTimestampSec;
    const blockDifference = Math.floor(timeDifference / blockTime);
    const estimatedBlockNumberAtInitialTimestamp = Number(latestBlock.number) - blockDifference;

    const estimatedBlockAtInitialTimestamp = {
        number: estimatedBlockNumberAtInitialTimestamp,
        timestamp: initialTimestampSec,
    };

    const approximateBlocks: { number: number; timestamp: number }[] = [];
    for (let i = 0; i < numberOfPeriods; i++) {
        const previousBlockTimeDelta = i * intervalSeconds;
        const previousBlockNumberDelta = Math.floor(previousBlockTimeDelta / blockTime);

        const previousBlock = {
            number: estimatedBlockAtInitialTimestamp.number - previousBlockNumberDelta,
            timestamp: estimatedBlockAtInitialTimestamp.timestamp - previousBlockTimeDelta,
        };

        approximateBlocks.unshift(previousBlock);
    }

    // Ensure the number of generated blocks matches the requested number of periods
    invariant(
        approximateBlocks.length === numberOfPeriods,
        `[approximateBlocksForTimestamp] Generated blocks (${approximateBlocks.length}) do not match requested number of periods (${numberOfPeriods})`,
    );
    return approximateBlocks;
}

// Get IV input data from on-chain to build a ProofRequest and get this data in the circuit.
// IV will be calculated in the circuit, then pushed to the smart contract to update the target IV.
// So, what do we need? IV can be calculated from Uniswap data as such:
// iv = 2 * (feeTier / 10 ** 6) * (dailyVolume / tickTvl) ** 0.5 * Math.sqrt(365)
// The other input besides tickTvl is volume, which can be easily summed up from swap events

const getIvInputData = async ({
    v3PoolAddress,
    client,
    toBlock,
}: {
    v3PoolAddress: Address;
    client: Client;
    toBlock: Awaited<ReturnType<typeof getBlock>>;
}) => {
    invariant(toBlock.number != null, 'invalid block');

    // Get inputs for current tickTvl
    const currentTick = await readContract(client, {
        address: v3PoolAddress,
        abi: V3PoolAbi,
        functionName: 'slot0',
        args: [],
    });

    // const curTickStruct = await readContract(client, {
    //   address: v3PoolAddress,
    //   abi: v3PoolAbi,
    //   functionName: 'ticks',
    //   args: [currentTick],
    // })

    const liquidity = await readContract(client, {
        address: v3PoolAddress,
        abi: V3PoolAbi,
        functionName: 'liquidity',
        args: [],
    });

    // Get swap logs for past day to calculate volume.
    const dayAgo = new Date();
    dayAgo.setDate(dayAgo.getDate() - 1);
    const dayAgoTimestampSecs = Math.floor(dayAgo.getTime() / 1000);

    const dayAgoBlock = approximateBlocksForTimestamp({
        initialTimestampSec: dayAgoTimestampSecs,
        latestBlock: {
            number: toBlock.number,
            timestamp: toBlock.timestamp,
        },
        interval: '1d',
        numberOfPeriods: 1,
        chainId: mainnet.id,
    })[0];

    const volumeLogs = await getContractEvents(client, {
        address: v3PoolAddress,
        abi: V3PoolAbi,
        eventName: 'Swap',
        fromBlock: BigInt(dayAgoBlock.number),
        toBlock: toBlock.number,
    });

    return { volumeLogs, currentTick, liquidity };
};

async function main() {
    while (true) {
        console.log('proving');
        const prover = new Prover('localhost:33247');
        const brevis = new Brevis('appsdkv3.brevis.network:443');

        const account = privateKeyToAccount(process.env.SCRIPT_PRIVATE_KEY as Hex);
        const client = createWalletClient({
            account: account,
            // mainnet
            chain: mainnet,
            transport: http(`https://eth-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`),
            // sepolia
            // chain: sepolia,
            // transport: http(`https://eth-sepolia.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`),
        });

        // mainnet
        const usdcWeth5BpsPool = '0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640';
        // sepolia
        // const usdcWeth5BpsPool = '0x1105514b9eb942f2596a2486093399b59e2f23fc';

        const safeBlock = await getBlock(client, {
            blockTag: 'safe',
        });

        const ivInputs = await getIvInputData({ v3PoolAddress: usdcWeth5BpsPool, client, toBlock: safeBlock });
        // const replacer = (key: any, value: any) => (typeof value === 'bigint' ? value.toString() : value); // serialize bigints in json.stringify
        // await fs.writeFileSync('./ivInputs.json', JSON.stringify(ivInputs, replacer, 2));

        // takes receipts, storages, and txns
        const proofReq = new ProofRequest();

        // Create volumeLogsTrimmed which takes ivInputs.volumeLogs and returns n by largest volume, where volume is determined by abs(amount1)
        // This is a necessary evil to limit computational complexity since you have to allocate a fixed number of receipts for the zk circuit ahead of time.

        // test
        const numReceipts = 2;
        // prod
        // const numReceipts = 3840
        // Get indices sorted by absolute amount1, preserving original order for equal values
        const sortedIndices = ivInputs.volumeLogs
            .map((_, index) => index)
            .sort((a, b) => {
                const aAbs = BigInt(Math.abs(Number(ivInputs.volumeLogs[a].args.amount1)));
                const bAbs = BigInt(Math.abs(Number(ivInputs.volumeLogs[b].args.amount1)));
                if (bAbs === aAbs) return a - b; // Preserve original order when equal
                return Number(bAbs - aAbs); // Sort descending
            })
            .slice(0, numReceipts);

        // Map back to original logs in order of largest amount1
        const volumeLogsTrimmed = sortedIndices.map(i => ivInputs.volumeLogs[i]);

        // Log the two largest volume logs (for unit testing circuit)
        // console.log('Largest volume log:', volumeLogsTrimmed[0]);
        // console.log('Second largest volume log:', volumeLogsTrimmed[1]);

        // Add ReceiptData for objects for each Uniswap V3 Swap event to the proof request
        volumeLogsTrimmed.forEach(swapLog => {
            proofReq.addReceipt(
                new ReceiptData({
                    block_num: Number(swapLog.blockNumber),
                    tx_hash: swapLog.transactionHash,
                    fields: [
                        // amount 0 (usdc for mainnet)
                        // new Field({
                        //     // contract?: string;
                        //     // log_pos?: number;
                        //     // event_id?: string;
                        //     // value?: string;
                        //     // is_topic?: boolean;
                        //     // field_index?: number;
                        //     contract: swapLog.address,
                        //     log_pos: swapLog.logIndex,
                        //     event_id: swapLog.topics[0],
                        //     value: swapLog.args.amount0!.toString(),
                        //     is_topic: false,
                        //     field_index: 0,
                        // }),
                        // amount 1 (weth for mainnet)
                        new Field({
                            contract: swapLog.address,
                            log_pos: swapLog.logIndex,
                            event_id: swapLog.topics[0],
                            value: swapLog.args.amount1!.toString(),
                            is_topic: false,
                            field_index: 1, // amount1 is 2nd field in rlp encoded log data (non-topic data)
                        }),
                    ],
                }),
            );
        });

        // Add storage data for currentTick() and liquidity() to proof request using same block as last block for volume data
        // slot 0 for tick
        const slot0Storage = await getStorageAt(client, {
            address: usdcWeth5BpsPool,
            slot: '0x0',
            blockNumber: safeBlock.number,
        });

        // Log these two storage slots (for unit testing circuit)
        // console.log('slot0Storage: ', slot0Storage)
        // slot 4 for liquidity
        const slot0StorageData = new StorageData({
            block_num: Number(safeBlock.number),
            address: usdcWeth5BpsPool,
            slot: '0x0',
            value: slot0Storage,
        });

        // console.log('slot0StorageData: ', slot0StorageData.toObject())
        proofReq.addStorage(slot0StorageData);

        // How did I know liquidity lives at slot 4? The storage slot for liquidity (or any other value in any contract) can be easily revealed with cast storage
        // For this case, I ran:
        // cast storage 0x8f8ef111b67c04eb1641f5ff19ee54cda062f163 --rpc-url='https://eth.llamarpc.com' --etherscan-api-key="<your_etherscan_api_key>"
        // to get the storage layout of a verified uniswap v3 pool contract
        // (you can also calc the slot by hand if you're into that kind of pain)
        const slot4Storage = await getStorageAt(client, {
            address: usdcWeth5BpsPool,
            slot: '0x4',
            blockNumber: safeBlock.number,
        });

        // console.log('slot4Storage: ', slot4Storage)
        const liquidityStorageData = new StorageData({
            block_num: Number(safeBlock.number),
            address: usdcWeth5BpsPool,
            slot: '0x4',
            value: slot4Storage,
        });
        // console.log('liquidityStorageData: ', liquidityStorageData.toObject())

        proofReq.addStorage(liquidityStorageData);

        // Brevis Partner KEY IS NOT required to submit request to Brevis Gateway.
        // It is used only for Brevis Partner Flow
        const brevis_partner_key = process.argv[3] ?? '';
        const callbackAddress = process.argv[4] ?? '0x5fbdb2315678afecb367f032d93f642f64180aa3';

        console.log(`Sending proofReq for iv...`);

        const proofRes = await prover.prove(proofReq);
        // error handling
        if (proofRes.has_err) {
            const err = proofRes.err;
            switch (err.code) {
                case ErrCode.ERROR_INVALID_INPUT:
                    console.error('invalid receipt/storage/transaction input:', err.msg);
                    break;

                case ErrCode.ERROR_INVALID_CUSTOM_INPUT:
                    console.error('invalid custom input:', err.msg);
                    break;

                case ErrCode.ERROR_FAILED_TO_PROVE:
                    console.error('failed to prove:', err.msg);
                    break;
            }
            return;
        }
        console.log('proof', proofRes.proof);

        try {
            const sourceChainId = 1;
            const destChainId = 11155111;
            const brevisRes = await brevis.submit(
                proofReq,
                proofRes,
                sourceChainId,
                destChainId,
                0,
                brevis_partner_key,
                callbackAddress,
            );
            console.log('brevis res', brevisRes);

            await brevis.wait(brevisRes.queryKey, 11155111);

            // 24 * 60 * 60 * 1000
            // => 86,400,000
            const msInDay = 86_400_000;
            setTimeout(() => null, msInDay); // sleep for 1 day, do it all over again
        } catch (err) {
            console.error(err);
        }
    }
}

console.log('Starting... make sure to `make start` prover before running this script');
main(); // run main() to submit proof requests every day
