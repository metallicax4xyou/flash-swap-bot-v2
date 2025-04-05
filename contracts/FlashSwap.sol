// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hardhat/console.sol";

contract FlashSwap is IUniswapV3FlashCallback {

    ISwapRouter public immutable swapRouter;
    address public owner;

    // Struct for data passed internally from initiateFlashSwap to callback
    struct FlashCallbackData {
        uint amount0Borrowed;
        uint amount1Borrowed;
        address caller;
        address poolAddress; // Pool where flash loan originated
        bytes params;        // Encoded arbitrage parameters from the user
    }

    // Struct to represent the decoded arbitrage parameters
    struct ArbitrageParams {
        address tokenIntermediate; // The token to swap to in the middle (e.g., USDC)
        address poolA;             // Address of pool for Swap 1 (e.g., WETH->USDC)
        address poolB;             // Address of pool for Swap 2 (e.g., USDC->WETH)
        uint24 feeA;               // Fee tier for Pool A
        uint24 feeB;               // Fee tier for Pool B
        uint amountOutMinimum1;    // Min intermediate token expected from Swap 1
        uint amountOutMinimum2;    // Min final token expected from Swap 2
    }


    modifier onlyOwner() {
        require(msg.sender == owner, "FlashSwap: Not owner");
        _;
    }

    constructor(address _swapRouter) {
        swapRouter = ISwapRouter(_swapRouter);
        owner = msg.sender;
    }

    // --- Uniswap V3 Flash Callback ---
    // DECODES PARAMS FOR DYNAMIC ARBITRAGE ROUTE
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external override {
        console.log("!!! DYNAMIC ARB Callback Entered !!! Fee0:", fee0, "Fee1:", fee1);

        FlashCallbackData memory decodedInternalData = abi.decode(data, (FlashCallbackData));
        require(msg.sender == decodedInternalData.poolAddress, "FlashSwap: Callback from unexpected pool");

        // Decode the arbitrage parameters passed by the initiator
        ArbitrageParams memory arbParams = abi.decode(decodedInternalData.params, (ArbitrageParams));
        console.log("Decoded Arb Params: Intermediate=", arbParams.tokenIntermediate); // Simplified log
        console.log("  PoolA=", arbParams.poolA);
        console.log("  PoolB=", arbParams.poolB);


        address loanPoolAddress = msg.sender;
        IUniswapV3Pool loanPool = IUniswapV3Pool(loanPoolAddress);
        address tokenBorrowed;
        address tokenToRepay; // Not strictly needed if arbParams.tokenIntermediate is correct
        uint amountBorrowed;
        uint totalAmountToRepay;

        // Determine details based on which token was borrowed
        if(decodedInternalData.amount1Borrowed > 0) {
            tokenBorrowed = loanPool.token1(); // WETH
            tokenToRepay = loanPool.token0();  // USDC
            amountBorrowed = decodedInternalData.amount1Borrowed;
            totalAmountToRepay = amountBorrowed + fee1;
            require(arbParams.tokenIntermediate == tokenToRepay, "Param intermediate token (0) mismatch");
        } else { // Borrowing Token0 (e.g., USDC)
            tokenBorrowed = loanPool.token0(); // USDC
            tokenToRepay = loanPool.token1();  // WETH
            amountBorrowed = decodedInternalData.amount0Borrowed;
            totalAmountToRepay = amountBorrowed + fee0;
             // If borrowing USDC, expect intermediate to be WETH for USDC->WETH->USDC arb
             require(arbParams.tokenIntermediate == tokenToRepay, "Param intermediate token (1) mismatch");
             // For now, we only fully support the WETH borrow case in the swap logic below
             // revert("Arbitrage logic currently only supports borrowing Token1 (WETH)");
             // Allow execution but swap logic might need adjustment if borrowing token0
        }

        console.log("Loan Pool:", loanPoolAddress);
        console.log("Borrowed Token:", tokenBorrowed);
        console.log("Amount Borrowed:", amountBorrowed);
        console.log("Total to Repay:", totalAmountToRepay);


        // --- ARBITRAGE LOGIC (Using decoded parameters) ---
        // This example assumes WETH (token1) was borrowed
        if (tokenBorrowed == loanPool.token1()) {
            console.log("Starting dynamic arbitrage (WETH->Intermediate->WETH)...");

            // --- Swap 1: Borrowed Token (WETH) -> Intermediate Token (USDC) on Pool A ---
            IERC20(tokenBorrowed).approve(address(swapRouter), amountBorrowed);
            console.log("Approved SwapRouter for Borrowed Token amount:", amountBorrowed);

            ISwapRouter.ExactInputSingleParams memory params1 =
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: tokenBorrowed,
                    tokenOut: arbParams.tokenIntermediate,
                    fee: arbParams.feeA,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountBorrowed,
                    amountOutMinimum: arbParams.amountOutMinimum1,
                    sqrtPriceLimitX96: 0
                });

            console.log("Executing Swap 1 on Pool A:", arbParams.poolA);
            uint amountOutIntermediate;
            try swapRouter.exactInputSingle(params1) returns (uint intermediateReceived) {
                 amountOutIntermediate = intermediateReceived;
                 console.log("Swap 1 executed. Received Intermediate Token amount:", amountOutIntermediate);
            } catch Error(string memory reason) {
                 console.log("Swap 1 Failed! Reason:", reason);
                 revert("Swap 1 failed, cannot continue arbitrage");
            } catch {
                 revert("Swap 1 failed (low level), cannot continue arbitrage");
            }

            // --- Swap 2: Intermediate Token (USDC) -> Borrowed Token (WETH) on Pool B ---
            IERC20(arbParams.tokenIntermediate).approve(address(swapRouter), amountOutIntermediate);
            console.log("Approved SwapRouter for Intermediate Token amount:", amountOutIntermediate);

            ISwapRouter.ExactInputSingleParams memory params2 =
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: arbParams.tokenIntermediate,
                    tokenOut: tokenBorrowed, // Swap back to original borrowed token
                    fee: arbParams.feeB,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountOutIntermediate,
                    amountOutMinimum: arbParams.amountOutMinimum2,
                    sqrtPriceLimitX96: 0
                });

            console.log("Executing Swap 2 on Pool B:", arbParams.poolB);
             try swapRouter.exactInputSingle(params2) returns (uint finalReceived) {
                 // We don't strictly need to store finalReceived if just checking balance below
                 console.log("Swap 2 executed. Final Borrowed Token Received (check balance):", finalReceived);
            } catch Error(string memory reason) {
                 console.log("Swap 2 Failed! Reason:", reason);
                 revert("Swap 2 failed, cannot complete arbitrage");
            } catch {
                revert("Swap 2 failed (low level), cannot complete arbitrage");
            }
        } else {
             // Placeholder if Token0 (USDC) was borrowed - needs reverse swap logic
             console.log("WARN: Swap logic for borrowing Token0 not fully implemented.");
        }


        // --- Repayment via Explicit Transfer ---
        console.log("Checking FINAL balance of token:", tokenBorrowed, " for transfer...");
        uint finalBalanceBorrowedToken = IERC20(tokenBorrowed).balanceOf(address(this));
        console.log("Final Current Borrowed Token Balance:", finalBalanceBorrowedToken);

        // THE CRITICAL CHECK: Did the arbitrage yield enough profit?
        require(finalBalanceBorrowedToken >= totalAmountToRepay, "FlashSwap: Insufficient funds post-arbitrage for repayment"); // Keep enabled

        console.log("Funds sufficient for repayment. Transferring to pool...");
        bool sent = IERC20(tokenBorrowed).transfer(loanPoolAddress, totalAmountToRepay);
        require(sent, "FlashSwap: Repayment transfer failed");
        console.log("Borrowed Token Repayment Transferred.");


        console.log("--- Exiting DYNAMIC ARB uniswapV3FlashCallback ---");
    }


    // --- Initiate Flash Swap ---
    function initiateFlashSwap(address _poolAddress, uint _amount0, uint _amount1, bytes memory _params) external {
        require((_amount0 > 0 && _amount1 == 0) || (_amount1 > 0 && _amount0 == 0), "FlashSwap: Borrow only one token");

        FlashCallbackData memory callbackData = FlashCallbackData({
            amount0Borrowed: _amount0,
            amount1Borrowed: _amount1,
            caller: msg.sender,
            poolAddress: _poolAddress,
            params: _params // Pass through encoded ArbitrageParams
        });

        IUniswapV3Pool(_poolAddress).flash(
            address(this),
            _amount0,
            _amount1,
            abi.encode(callbackData) // Encode the internal data struct
        );
    }

    // --- Utility Functions ---
    function withdrawEther() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    function withdrawToken(address tokenAddress) external onlyOwner {
        IERC20 token = IERC20(tokenAddress);
        uint balance = token.balanceOf(address(this));
        require(balance > 0, "FlashSwap: No tokens to withdraw");
        token.transfer(owner, balance);
    }

    receive() external payable {}
}
