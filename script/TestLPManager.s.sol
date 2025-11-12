// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Router02 {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
}

contract TestLPManager is Script {
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    
    address token;
    address vault;
    address lpVault;
    address lpManager;
    address pair;
    
    address deployer;
    address user1;
    address user2;
    
    uint256 testsPassed = 0;
    uint256 testsTotal = 3;
    
    function run() external {
        // Use makeAddr() to generate unique addresses that DON'T exist on BSC
        // These are deterministic but guaranteed not to collide with existing contracts
        deployer = makeAddr("deployer_lpmanager_test");
        user1 = makeAddr("user1_lpmanager_test");
        user2 = makeAddr("user2_lpmanager_test");
        
        vm.deal(deployer, 1000 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        
        console.log("==============================================");
        console.log("     LPMANAGER INTEGRATION - TAX-FREE TEST    ");
        console.log("==============================================\n");
        
        // Deploy and setup
        deployAndSetup();
        
        console.log("\n=== STARTING LPMANAGER TESTS ===\n");
        
        // Critical tests
        test1_LPAdditionFlow();
        test2_TaxFreeVerification_LPManager();
        test3_TaxFreeVerification_Router();
        
        // Summary
        printSummary();
    }
    
    function deployAndSetup() internal {
        console.log("--- DEPLOYMENT & SETUP ---");
        
        vm.startBroadcast(deployer);
        
        // Deploy Token using bytecode
        bytes memory tokenBytecode = abi.encodePacked(
            vm.getCode("JackpotToken.sol:JackpotToken"),
            abi.encode(ROUTER)
        );
        address _token;
        assembly {
            _token := create(0, add(tokenBytecode, 0x20), mload(tokenBytecode))
        }
        require(_token != address(0), "Token deployment failed");
        token = _token;
        
        // Deploy Vault
        bytes memory vaultBytecode = abi.encodePacked(
            vm.getCode("JackpotVault.sol:JackpotVault"),
            abi.encode(token)
        );
        address _vault;
        assembly {
            _vault := create(0, add(vaultBytecode, 0x20), mload(vaultBytecode))
        }
        require(_vault != address(0), "Vault deployment failed");
        vault = _vault;
        
        // Deploy LP Vault
        bytes memory lpVaultBytecode = abi.encodePacked(
            vm.getCode("JackpotLPVault.sol:JackpotLPVault"),
            abi.encode(token)
        );
        address _lpVault;
        assembly {
            _lpVault := create(0, add(lpVaultBytecode, 0x20), mload(lpVaultBytecode))
        }
        require(_lpVault != address(0), "LP Vault deployment failed");
        lpVault = _lpVault;
        
        // Deploy LP Manager
        bytes memory lpManagerBytecode = abi.encodePacked(
            vm.getCode("LPManager.sol:LPManager"),
            abi.encode(token, lpVault, ROUTER)
        );
        address _lpManager;
        assembly {
            _lpManager := create(0, add(lpManagerBytecode, 0x20), mload(lpManagerBytecode))
        }
        require(_lpManager != address(0), "LP Manager deployment failed");
        lpManager = _lpManager;
        
        // Setup using low-level calls
        (bool success1,) = token.call(abi.encodeWithSignature("setVault(address)", vault));
        require(success1, "setVault failed");
        
        (bool success2,) = token.call(abi.encodeWithSignature("setLPVault(address)", lpVault));
        require(success2, "setLPVault failed");
        
        (bool success3,) = token.call(abi.encodeWithSignature("setLPManager(address)", lpManager));
        require(success3, "setLPManager failed");
		
		// Set LP Manager in LP Vault (allow LPManager to record contributions)
		(bool success3b,) = lpVault.call(abi.encodeWithSignature("setLPManager(address)", lpManager));
		require(success3b, "lpVault setLPManager failed");
        
        // Add initial liquidity
        (bool success4,) = token.call{value: 100 ether}(
            abi.encodeWithSignature("addInitialLiquidity()")
        );
        require(success4, "addInitialLiquidity failed");
        
        // Enable trading
        (bool success5,) = token.call(abi.encodeWithSignature("enableTrading()"));
        require(success5, "enableTrading failed");
        
        // Get pair address
        (bool success6, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("pair()")
        );
        require(success6, "Getting pair failed");
        pair = abi.decode(data, (address));
        
        vm.stopBroadcast();
        
        console.log("Token:", token);
        console.log("LP Manager:", lpManager);
        console.log("LP Vault:", lpVault);
        console.log("Pair:", pair);
        console.log("");
    }
    
    function test1_LPAdditionFlow() internal {
        console.log("--- TEST 1: LP ADDITION FLOW ---");
        console.log("Objective: Verify complete LPManager flow");
        console.log("");
        
        // Buy tokens for user
        console.log("Step 1: User buys tokens...");
        buyTokens(user1, 2 ether);
        
        uint256 tokenBalance = IERC20(token).balanceOf(user1);
        console.log("  Token balance:", tokenBalance / 1e18);
        
        // Prepare LP addition
        uint256 tokenAmount = tokenBalance / 2;
        uint256 bnbAmount = 1 ether;
        
        console.log("\nStep 2: User adds LP via LPManager...");
        console.log("  Tokens:", tokenAmount / 1e18);
        console.log("  BNB:", bnbAmount / 1e18);
        
        vm.startPrank(user1);
        
        // Approve tokens to LPManager
        console.log("\nStep 3: Approve tokens...");
        IERC20(token).approve(lpManager, tokenAmount);
        console.log("  Approved");
        
        // Track balances before
        uint256 bnbBefore = address(user1).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(user1);
        uint256 pairTokenBefore = IERC20(token).balanceOf(pair);
        
        console.log("\nStep 4: Call addLiquidityAndRegister...");
        
        (bool success, bytes memory result) = lpManager.call{value: bnbAmount}(
            abi.encodeWithSignature(
                "addLiquidityAndRegister(uint256,uint256,uint256,uint256)",
                tokenAmount,
                0,
                0,
                block.timestamp
            )
        );
        
        vm.stopPrank();
        
        if (!success) {
            console.log("  FAIL: LP addition failed");
            console.log("  Revert reason:", string(result));
            return;
        }
        
        console.log("  SUCCESS: LP added");
        
        // Check balances after
        uint256 bnbAfter = address(user1).balance;
        uint256 tokenAfter = IERC20(token).balanceOf(user1);
        uint256 pairTokenAfter = IERC20(token).balanceOf(pair);
        
        uint256 bnbSpent = bnbBefore - bnbAfter;
        uint256 tokensSpent = tokenBefore - tokenAfter;
        uint256 tokensToPair = pairTokenAfter - pairTokenBefore;
        
        console.log("\nStep 5: Verify balances...");
        console.log("  BNB spent:", bnbSpent / 1e18, "BNB");
        console.log("  Tokens spent:", tokensSpent / 1e18);
        console.log("  Tokens to pair:", tokensToPair / 1e18);
        
        // CRITICAL: Check if tokens spent = tokens to pair (NO TAX!)
        console.log("\nStep 6: Tax verification...");
        
        // Allow small difference for rounding
        uint256 difference = tokensSpent > tokensToPair ? 
            tokensSpent - tokensToPair : 
            tokensToPair - tokensSpent;
        
        uint256 percentDiff = (difference * 10000) / tokensSpent; // in basis points
        
        console.log("  Difference:", difference / 1e18);
        console.log("  Difference (bps):", percentDiff);
        
        if (percentDiff < 50) { // < 0.5% difference (rounding tolerance)
            console.log("  PASS: NO TAX applied (tax-free!)");
            testsPassed++;
        } else {
            console.log("  FAIL: TAX detected! LP addition was taxed!");
            console.log("  Expected: ~", tokensSpent / 1e18, "tokens to pair");
            console.log("  Got:", tokensToPair / 1e18, "tokens to pair");
            
            if (tokensSpent > tokensToPair * 11 / 10) {
                console.log("  Likely 10% tax applied - isSell logic BROKEN!");
            }
        }
        
        // Check contribution recorded
        console.log("\nStep 7: Check contribution recorded...");
        (bool success2, bytes memory data) = lpVault.call(
            abi.encodeWithSignature("lifetimeContributions(address)", user1)
        );
        
        if (success2) {
            uint256 contribution = abi.decode(data, (uint256));
            if (contribution > 0) {
                console.log("  Contribution:", contribution / 1e18, "BNB");
                console.log("  PASS: Recorded in LPVault");
            } else {
                console.log("  WARNING: Not recorded (may be below minimum)");
            }
        }
        
        console.log("");
    }
    
    function test2_TaxFreeVerification_LPManager() internal {
        console.log("--- TEST 2: TAX-FREE VERIFICATION (LPMANAGER) ---");
        console.log("Objective: Verify isSell = false for LPManager -> Pair");
        console.log("");
        
        // Buy tokens
        buyTokens(user2, 2 ether);
        
        uint256 tokenAmount = 1_000_000 * 10**18;
        uint256 bnbAmount = 0.5 ether;
        
        vm.startPrank(user2);
        IERC20(token).approve(lpManager, tokenAmount);
        
        // Get pair balance before
        uint256 pairBalanceBefore = IERC20(token).balanceOf(pair);
        
        console.log("Adding LP via LPManager...");
        console.log("  Token amount:", tokenAmount / 1e18);
        console.log("  Expected in pair (no tax):", tokenAmount / 1e18);
        
        (bool success,) = lpManager.call{value: bnbAmount}(
            abi.encodeWithSignature(
                "addLiquidityAndRegister(uint256,uint256,uint256,uint256)",
                tokenAmount,
                tokenAmount * 9 / 10, // Allow 10% slippage
                0,
                block.timestamp
            )
        );
        
        vm.stopPrank();
        
        if (!success) {
            console.log("  FAIL: LP addition failed");
            return;
        }
        
        // Get pair balance after
        uint256 pairBalanceAfter = IERC20(token).balanceOf(pair);
        uint256 tokensAdded = pairBalanceAfter - pairBalanceBefore;
        
        console.log("  Tokens added to pair:", tokensAdded / 1e18);
        
        // Calculate if tax was applied
        // If tax: expect only 90% to reach pair (10% tax)
        // If no tax: expect ~100% to reach pair
        
        uint256 percentReceived = (tokensAdded * 100) / tokenAmount;
        console.log("  Percent received:", percentReceived, "%");
        
        if (percentReceived >= 98) { // Allow 2% tolerance for rounding/slippage
            console.log("  PASS: NO TAX - LPManager excluded from isSell");
            testsPassed++;
        } else if (percentReceived >= 88 && percentReceived <= 92) {
            console.log("  FAIL: 10% TAX APPLIED - isSell logic BROKEN!");
            console.log("  CRITICAL: lpManager NOT excluded from sell tax!");
        } else {
            console.log("  UNCLEAR: Unexpected result -", percentReceived, "%");
        }
        
        console.log("");
    }
    
    function test3_TaxFreeVerification_Router() internal {
        console.log("--- TEST 3: TAX-FREE VERIFICATION (ROUTER) ---");
        console.log("Objective: Verify isSell = false for Router -> Pair");
        console.log("");
        
        // Buy tokens
        address user3 = makeAddr("user3_lpmanager_test");
        vm.deal(user3, 100 ether);
        buyTokens(user3, 2 ether);
        
        uint256 tokenBalance = IERC20(token).balanceOf(user3);
        uint256 tokenAmount = tokenBalance / 2;
        uint256 bnbAmount = 0.5 ether;
        
        vm.startPrank(user3);
        
        // Approve router
        IERC20(token).approve(ROUTER, tokenAmount);
        
        // ✅ Get balances BEFORE LP addition
        uint256 pairBalanceBefore = IERC20(token).balanceOf(pair);
        uint256 userBalanceBefore = IERC20(token).balanceOf(user3);
        
        console.log("Adding LP directly via Router...");
        console.log("  User balance before:", userBalanceBefore / 1e18);
        console.log("  Pair balance before:", pairBalanceBefore / 1e18);
        console.log("  Token amount approved:", tokenAmount / 1e18);
        
        try IUniswapV2Router02(ROUTER).addLiquidityETH{value: bnbAmount}(
            token,
            tokenAmount,
            0,
            0,
            user3,
            block.timestamp
        ) {
            // Success - no revert
        } catch {
            console.log("  FAIL: LP addition failed");
            vm.stopPrank();
            return;
        }
        
        vm.stopPrank();
        
        // ✅ Get balances AFTER LP addition
        uint256 pairBalanceAfter = IERC20(token).balanceOf(pair);
        uint256 userBalanceAfter = IERC20(token).balanceOf(user3);
        
        // ✅ Calculate what ACTUALLY happened
        uint256 userSpent = userBalanceBefore - userBalanceAfter;
        uint256 pairReceived = pairBalanceAfter - pairBalanceBefore;
        
        console.log("  User balance after:", userBalanceAfter / 1e18);
        console.log("  Pair balance after:", pairBalanceAfter / 1e18);
        console.log("  User actually spent:", userSpent / 1e18);
        console.log("  Pair actually received:", pairReceived / 1e18);
        
        // ✅ CORRECT COMPARISON: userSpent vs pairReceived
        uint256 percentReceived = (pairReceived * 100) / userSpent;
        console.log("  Percent received:", percentReceived, "%");
        
        if (percentReceived >= 98) {
            console.log("  PASS: NO TAX - Router excluded from isSell");
            testsPassed++;
        } else if (percentReceived >= 88 && percentReceived <= 92) {
            console.log("  FAIL: 10% TAX APPLIED - isSell logic BROKEN!");
            console.log("  CRITICAL: router NOT excluded from sell tax!");
        } else {
            console.log("  UNCLEAR: Unexpected result -", percentReceived, "%");
        }
        
        console.log("");
    }
    
    function printSummary() internal view {
        console.log("\n==============================================");
        console.log("        LPMANAGER INTEGRATION SUMMARY         ");
        console.log("==============================================\n");
        
        console.log("Tests passed:", testsPassed, "/", testsTotal);
        console.log("");
        
        if (testsPassed == testsTotal) {
            console.log("ALL TESTS PASSED!");
            console.log("");
            console.log("LP additions are TAX-FREE:");
            console.log("  - LPManager -> Pair: NO TAX");
            console.log("  - Router -> Pair: NO TAX");
            console.log("  - Users get full tokens in LP");
            console.log("");
            console.log("isSell exclusion logic WORKING CORRECTLY!");
        } else {
            console.log("SOME TESTS FAILED!");
            console.log("");
            console.log("CRITICAL ISSUE:");
            console.log("  LP additions are being TAXED!");
            console.log("  This will prevent users from adding LP!");
            console.log("");
            console.log("CHECK isSell LOGIC:");
            console.log("  bool isSell = to == pair &&");
            console.log("                from != address(this) &&");
            console.log("                from != address(router) &&");
            console.log("                from != lpManager;");
            console.log("");
            console.log("VERIFY:");
            console.log("  1. lpManager is SET via setLPManager()");
            console.log("  2. router address is correct");
            console.log("  3. isSell logic in _transfer() is correct");
        }
        
        console.log("==============================================\n");
    }
    
    // Helper functions
    function buyTokens(address user, uint256 bnbAmount) internal {
        vm.startPrank(user);
        
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = token;
        
        IUniswapV2Router02(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnbAmount}(
            0,
            path,
            user,
            block.timestamp
        );
        
        vm.stopPrank();
        
        vm.warp(block.timestamp + 31); // Cooldown
    }
}
