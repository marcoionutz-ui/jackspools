// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/**
 * @title TestCompleteFlow - WITHOUT address(this)
 * @notice Simplified test without self-calls
 */

interface IJackpotToken {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    function setVault(address) external;
    function addInitialLiquidity() external payable;
    function enableTrading() external;
    function getLPValue() external view returns (uint256);
    function processTaxes() external;
}

interface IJackpotVault {
    function onTaxReceived() external payable;
}

interface IRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    
    function WETH() external pure returns (address);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function sync() external;
}

contract TestCompleteFlow is Script {
    
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    
    IJackpotToken token;
    IJackpotVault vault;
    address pair;
    address deployer;
    address[] buyers;
    
    function run() external {
        console.log("\n=============================================================================");
        console.log("    JACKPOT TOKEN - SIMPLIFIED TAX PROCESSING TEST");
        console.log("=============================================================================\n");
        
        setupWallets();
        deployContracts();
        do10Buys();
        
        console.log("\n=============================================================================");
        console.log("                    TAX PROCESSING DIAGNOSTICS");
        console.log("=============================================================================\n");
        
        uint256 vaultBefore = address(vault).balance;
        uint256 tokensBefore = token.balanceOf(address(token));
        
        console.log("BEFORE TAX PROCESSING:");
        console.log("  Vault:   ", vaultBefore / 1e18, "BNB");
        console.log("  Tokens:  ", tokensBefore / 1e18, "tokens\n");
        
        // Just try to process taxes normally
        testDirectProcessing();
        
        // Final report
        console.log("\n=============================================================================");
        console.log("                         FINAL RESULTS");
        console.log("=============================================================================\n");
        
        uint256 vaultAfter = address(vault).balance;
        uint256 tokensAfter = token.balanceOf(address(token));
        
        console.log("AFTER TAX PROCESSING:");
        console.log("  Vault:   ", vaultAfter / 1e18, "BNB");
        console.log("  Tokens:  ", tokensAfter / 1e18, "tokens");
        console.log("  Growth:  ", (vaultAfter - vaultBefore) / 1e18, "BNB\n");
        
        if (vaultAfter > vaultBefore) {
            console.log("[SUCCESS] Taxes reached vault! System works!");
        } else {
            console.log("[FAIL] No BNB in vault. Check lastProcessBlock logic.");
        }
        
        console.log("\n=============================================================================\n");
    }
    
    function setupWallets() internal {
        console.log("Setting up wallets...\n");
        
        deployer = makeAddr("deployer");
        vm.deal(deployer, 1000 ether);
        
        for (uint i = 0; i < 10; i++) {
            address buyer = makeAddr(string(abi.encodePacked("buyer", vm.toString(i))));
            buyers.push(buyer);
            vm.deal(buyer, 10 ether);
        }
        
        console.log("  Deployer + 10 buyers funded\n");
    }
    
    function deployContracts() internal {
        console.log("Deploying contracts...\n");
        
        vm.startBroadcast(deployer);
        
        // Deploy token
        bytes memory tokenCode = vm.getCode("JackpotToken.sol:JackpotToken");
        bytes memory tokenBytecode = abi.encodePacked(tokenCode, abi.encode(ROUTER));
        address tokenAddr;
        assembly {
            tokenAddr := create(0, add(tokenBytecode, 0x20), mload(tokenBytecode))
        }
        token = IJackpotToken(tokenAddr);
        
        // Calculate pair
        address factoryAddr = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
        address token0 = address(token) < WBNB ? address(token) : WBNB;
        address token1 = address(token) < WBNB ? WBNB : address(token);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        bytes32 initCodeHash = hex'00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5';
        pair = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            factoryAddr,
            salt,
            initCodeHash
        )))));
        
        // Deploy vault
        bytes memory vaultCode = vm.getCode("JackpotVault.sol:JackpotVault");
        bytes memory vaultBytecode = abi.encodePacked(vaultCode, abi.encode(address(token)));
        address vaultAddr;
        assembly {
            vaultAddr := create(0, add(vaultBytecode, 0x20), mload(vaultBytecode))
        }
        vault = IJackpotVault(vaultAddr);
        
        // Configure
        token.setVault(address(vault));
        token.addInitialLiquidity{value: 20 ether}();
        token.enableTrading();
        
        console.log("  Token:  ", address(token));
        console.log("  Vault:  ", address(vault));
        console.log("  Pair:   ", pair);
        console.log("  LP:     ", token.getLPValue() / 1e18, "BNB\n");
        
        vm.stopBroadcast();
    }
    
    function do10Buys() internal {
        console.log("Executing 10 buys (0.2 BNB each)...\n");
        
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(token);
        
        for (uint i = 0; i < 10; i++) {
            vm.startPrank(buyers[i]);
            IRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.2 ether}(
                0,
                path,
                buyers[i],
                block.timestamp + 300
            );
            vm.stopPrank();
            
            // IMPORTANT: Advance block AND time for each buy
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 31);
        }
        
        uint256 accumulated = token.balanceOf(address(token));
        console.log("  Accumulated taxes: ", accumulated / 1e18, "tokens");
        console.log("  Current block:     ", block.number, "\n");
    }
    
    function testDirectProcessing() internal {
        console.log("=== ATTEMPTING DIRECT TAX PROCESSING ===\n");
        
        uint256 vaultBefore = address(vault).balance;
        uint256 contractBal = token.balanceOf(address(token));
        
        console.log("  Contract tokens: ", contractBal / 1e18);
        console.log("  Vault before:    ", vaultBefore / 1e18, "BNB");
        console.log("  Current block:   ", block.number, "\n");
        
        // Try calling processTaxes() from a buyer
        console.log("  Calling processTaxes() from buyer0...");
        
        vm.startPrank(buyers[0]);
        
        try token.processTaxes() {
            console.log("  [OK] processTaxes() executed\n");
            
            uint256 vaultAfter = address(vault).balance;
            console.log("  Vault after: ", vaultAfter / 1e18, "BNB");
            
            if (vaultAfter > vaultBefore) {
                console.log("  [SUCCESS] Tax processing worked!");
            } else {
                console.log("  [WARNING] No BNB reached vault");
            }
        } catch Error(string memory reason) {
            console.log("  [FAIL] Error:", reason);
        } catch (bytes memory /*lowLevelData*/) {
            console.log("  [FAIL] Low-level revert");
        }
        
        vm.stopPrank();
    }
}
