// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/**
 * @title TestDirectSwap
 * @notice Test swap WITHOUT try/catch to see real error
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IJackpotToken {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function setVault(address) external;
    function addInitialLiquidity() external payable;
    function enableTrading() external;
    function getLPValue() external view returns (uint256);
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
    
    function getAmountsOut(uint amountIn, address[] calldata path) 
        external view returns (uint[] memory amounts);
    
    function WETH() external pure returns (address);
}

contract TestDirectSwap is Script {
    
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    
    IJackpotToken token;
    address vault;
    address pair;
    address deployer;
    address buyer1;
    
    function run() external {
        console.log("\n=== DIRECT SWAP TEST (NO TRY/CATCH) ===\n");
        
        setupWallets();
        deployContracts();
        
        console.log("=== DOING 1 BUY ===\n");
        
        // Do 1 buy
        address[] memory buyPath = new address[](2);
        buyPath[0] = WBNB;
        buyPath[1] = address(token);
        
        vm.startPrank(buyer1);
        IRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.2 ether}(
            0,
            buyPath,
            buyer1,
            block.timestamp + 300
        );
        vm.stopPrank();
        
        uint256 contractBal = token.balanceOf(address(token));
        console.log("Contract has:", contractBal / 1e18, "tokens\n");
        
        console.log("=== ATTEMPTING DIRECT SWAP ===\n");
        
        // Calculate what to swap (simplified - just half of contract balance)
        uint256 tokensToSwap = contractBal / 2;
        console.log("Tokens to swap:", tokensToSwap / 1e18);
        
        // Estimate BNB output
        address[] memory sellPath = new address[](2);
        sellPath[0] = address(token);
        sellPath[1] = WBNB;
        
        uint256[] memory amounts = IRouter(ROUTER).getAmountsOut(tokensToSwap, sellPath);
        console.log("Expected BNB:  ", amounts[1] / 1e18);
        console.log("Min BNB (90%): ", (amounts[1] * 9000) / 10000 / 1e18, "\n");
        
        // Impersonate token contract to do the swap
        vm.startPrank(address(token));
        
        console.log("Approving router...");
        token.approve(ROUTER, tokensToSwap);
        
        uint256 allowance = IERC20(address(token)).allowance(address(token), ROUTER);
        console.log("Allowance set:", allowance / 1e18, "\n");
        
        console.log("Calling swapExactTokensForETH...");
        console.log("(This will REVERT if there's an error - that's what we want!)\n");
        
        // NO TRY/CATCH - let it revert to see the error!
        IRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokensToSwap,
            0, // No min for now
            sellPath,
            address(this), // Send BNB to script
            block.timestamp + 300
        );
        
        vm.stopPrank();
        
        console.log("\n[SUCCESS] Swap completed without errors!");
        console.log("Script received:", address(this).balance / 1e18, "BNB");
    }
    
    function setupWallets() internal {
        deployer = makeAddr("deployer");
        vm.deal(deployer, 1000 ether);
        
        buyer1 = makeAddr("buyer1");
        vm.deal(buyer1, 10 ether);
    }
    
    function deployContracts() internal {
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
        vault = makeAddr("vault");
        
        // Configure
        token.setVault(vault);
        token.addInitialLiquidity{value: 20 ether}();
        token.enableTrading();
        
        console.log("Token:  ", address(token));
        console.log("Pair:   ", pair);
        console.log("LP:     ", token.getLPValue() / 1e18, "BNB\n");
        
        vm.stopBroadcast();
    }
    
    receive() external payable {}
}
