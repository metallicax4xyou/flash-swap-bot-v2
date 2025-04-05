const hre = require("hardhat");
const { ethers } = require("ethers"); // Import ethers directly

// Addresses - Use manually verified checksummed strings
const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const POOL_A_WETH_USDC_005 = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"; // Pool for Flash loan and Swap 1 (WETH->USDC)
const POOL_B_USDC_WETH_030 = "0x8ad599c3A0b1A56AAd039ddAc6837Db27B2f64C5"; // Pool for Swap 2 (USDC->WETH)
const ROUTER_ADDRESS = "0xE592427A0AEce92De3Edee1F18E0157C05861564";

// Pool Fees
const FEE_A = 500;  // 0.05%
const FEE_B = 3000; // 0.3%

async function main() {
    const [deployer] = await hre.ethers.getSigners(); // Get signer via hre
    console.log("Deploying contracts with the account:", deployer.address);

    // Ensure the deployer has some ETH
    let balance = await hre.ethers.provider.getBalance(deployer.address);
    console.log("Account balance:", hre.ethers.formatUnits(balance, "ether"), "ETH");
    if (balance === 0n) {
        console.warn("Deployer has no ETH...");
        await hre.network.provider.send("hardhat_setBalance", [deployer.address, "0x56BC75E2D63100000"]); // 100 ETH
        console.log("Sent 100 ETH to deployer");
    }

    // Get Contract Factory using hre
    const FlashSwapFactory = await hre.ethers.getContractFactory("FlashSwap");

    console.log("Deploying FlashSwap...");
    // Deploy using Hardhat's factory (simpler than manual)
    const flashSwap = await FlashSwapFactory.deploy(ROUTER_ADDRESS);
    await flashSwap.waitForDeployment(); // Use Hardhat's wait method
    const flashSwapAddress = await flashSwap.getAddress();
    console.log("FlashSwap deployed to:", flashSwapAddress);

    // --- No Pre-funding ---
    const WETH_ABI = ["function balanceOf(address) view returns (uint)"];
    // Use provider from hre for read-only contract instance
    const wethContract = new ethers.Contract(WETH_ADDRESS, WETH_ABI, hre.ethers.provider);
    console.log(`FlashSwap contract initial WETH balance: ${hre.ethers.formatUnits(await wethContract.balanceOf(flashSwapAddress), 18)} WETH`);


    // --- Define Flash Loan Parameters ---
    const poolForLoan = POOL_A_WETH_USDC_005;
    const amount0ToBorrow = 0n;
    const amount1ToBorrow = hre.ethers.parseUnits("1", 18); // 1 WETH

    // --- Encode Arbitrage Parameters ---
    console.log("Encoding parameters using ethers.AbiCoder...");
    const abiCoder = ethers.AbiCoder.defaultAbiCoder(); // Use direct ethers coder
    const arbitrageParams = abiCoder.encode(
        ['address', 'address', 'address', 'uint24', 'uint24', 'uint256', 'uint256'],
        [ USDC_ADDRESS, POOL_A_WETH_USDC_005, POOL_B_USDC_WETH_030, FEE_A, FEE_B, 0, 0 ] // amountOutMinimums set to 0
    );
    console.log("Encoded Arbitrage Params:", arbitrageParams);

    console.log(`Attempting to borrow: ${hre.ethers.formatUnits(amount1ToBorrow, 18)} WETH (Token1) from ${poolForLoan}`);

    // --- Call initiateFlashSwap ---
    // Use the contract instance obtained from Hardhat's factory
    console.log(`Initiating flash swap...`);
    try {
        console.warn(`Executing: flashSwap.initiateFlashSwap(${poolForLoan}, ${amount0ToBorrow}, ${amount1ToBorrow}, [params])`);

        const tx = await flashSwap.initiateFlashSwap( // Call using flashSwap instance from factory
            poolForLoan,
            amount0ToBorrow,
            amount1ToBorrow,
            arbitrageParams
        );
        console.log("Transaction sent:", tx.hash);
        const receipt = await tx.wait(); // Wait for transaction receipt
        console.log("Transaction confirmed in block:", receipt.blockNumber);
        console.log("⚠️ Flash swap SUCCEEDED? (UNEXPECTED)");

    } catch (error) {
        console.error("\n--- Flash swap transaction failed (EXPECTED) ---");
        console.error("Error executing initiateFlashSwap:");
        // Improved error reason extraction
        if (error.transactionHash) { console.error("  Transaction Hash:", error.transactionHash); }
        let reason = error.reason;
        if (error.data && !reason && error.data !== '0x') {
             try {
                const ERROR_SELECTOR = "0x08c379a0"; // Error(string)
                const PANIC_SELECTOR = "0x4e487b71"; // Panic(uint256)
                if (error.data.startsWith(ERROR_SELECTOR)) {
                    reason = abiCoder.decode(['string'], "0x" + error.data.substring(10))[0];
                } else if (error.data.startsWith(PANIC_SELECTOR)) {
                    const panicCode = abiCoder.decode(['uint256'], "0x" + error.data.substring(10))[0];
                    reason = `Panic(0x${panicCode.toString(16)})`;
                }
             } catch (e) { console.error(" Decoding error reason failed:", e); }
        }
         if (reason) { console.error("  Revert Reason:", reason); } else if (error.message) { // Fallback to error message
             console.error("  Error message:", error.message);
         } else {
            console.error("  Unknown error:", error);
         }

        console.error("\n  This failure is EXPECTED. Look for 'FlashSwap: Insufficient funds...' or 'Swap X failed...'");
        console.error("------------------------------------------------------\n");
    }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
