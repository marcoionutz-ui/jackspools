// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

interface IJackpotToken {
    function balanceOf(address) external view returns (uint256);
    function setVault(address) external;
    function setLPVault(address) external;
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
    
    function WETH() external pure returns (address);
}

contract TestWithRealAddresses is Script {
    
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    
    address constant DEPLOYER = 0x8894E0a0c962CB723c1976a4421c95949bE2D4E3;
    address constant BUYER1 = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    address constant BUYER2 = 0x28C6c06298d514Db089934071355E5743bf21d60;
    address constant BUYER3 = 0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8;
    
    IJackpotToken token;
    IJackpotVault vault;
    address lpVault;
    
    function run() external {
        console.log("\n=== 10 BUYS TEST ===\n");
        
        vm.deal(DEPLOYER, 1000 ether);
        vm.deal(BUYER1, 10 ether);
        vm.deal(BUYER2, 10 ether);
        vm.deal(BUYER3, 10 ether);
        
        deployContracts();
        testMultipleBuys();
    }
    
    function deployContracts() internal {
        console.log("=== DEPLOYING ===\n");
        
        vm.startBroadcast(DEPLOYER);
        
        bytes memory tokenCode = vm.getCode("JackpotToken.sol:JackpotToken");
        bytes memory tokenBytecode = abi.encodePacked(tokenCode, abi.encode(ROUTER));
        address tokenAddr;
        assembly {
            tokenAddr := create(0, add(tokenBytecode, 0x20), mload(tokenBytecode))
        }
        token = IJackpotToken(tokenAddr);
        
        address factoryAddr = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
        address token0 = address(token) < WBNB ? address(token) : WBNB;
        address token1 = address(token) < WBNB ? WBNB : address(token);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        bytes32 initCodeHash = hex'00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5';
        address pair = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), factoryAddr, salt, initCodeHash
        )))));
        
        bytes memory vaultCode = vm.getCode("JackpotVault.sol:JackpotVault");
        bytes memory vaultBytecode = abi.encodePacked(vaultCode, abi.encode(address(token)));
        address vaultAddr;
        assembly {
            vaultAddr := create(0, add(vaultBytecode, 0x20), mload(vaultBytecode))
        }
        vault = IJackpotVault(vaultAddr);
        
        bytes memory lpVaultCode = vm.getCode("JackpotLPVault.sol:JackpotLPVault");
        bytes memory lpVaultBytecode = abi.encodePacked(lpVaultCode, abi.encode(address(token)));
        address lpVaultAddr;
        assembly {
            lpVaultAddr := create(0, add(lpVaultBytecode, 0x20), mload(lpVaultBytecode))
        }
        lpVault = lpVaultAddr;
        
        token.setVault(address(vault));
        token.setLPVault(lpVault);
        token.addInitialLiquidity{value: 20 ether}();
        token.enableTrading();
        
        console.log("LP Value:", token.getLPValue() / 1e18, "BNB\n");
        
        vm.stopBroadcast();
    }
    
    function testMultipleBuys() internal {
        console.log("=== EXECUTING 10 BUYS ===\n");
        
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(token);
        
        address[10] memory buyers = [
            BUYER1, BUYER2, BUYER3, BUYER1, BUYER2,
            BUYER3, BUYER1, BUYER2, BUYER3, BUYER1
        ];
        
        for (uint i = 0; i < 10; i++) {
            console.log("Buy", i + 1);
            vm.startPrank(buyers[i]);
            IRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.2 ether}(
                0, path, buyers[i], block.timestamp + 300
            );
            vm.stopPrank();
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 31);
        }
        
        uint256 contractBal = token.balanceOf(address(token));
        console.log("\nAccumulated:", contractBal / 1e18, "tokens");
        console.log("In wei:     ", contractBal);
        
        console.log("\n=== PROCESSING TAXES ===\n");
        
        uint256 vBefore = address(vault).balance;
        uint256 lpBefore = lpVault.balance;
        
        console.log("BEFORE:");
        console.log("  Vault wei:   ", vBefore);
        console.log("  Vault miliBNB:", vBefore / 1e15);
        console.log("  LP Vault wei:", lpBefore);
        console.log("  LP miliBNB:  ", lpBefore / 1e15);
        
        console.log("\nCalling processTaxes()...\n");
        
        vm.startPrank(BUYER1);
        token.processTaxes();
        vm.stopPrank();
        
        uint256 vAfter = address(vault).balance;
        uint256 lpAfter = lpVault.balance;
        
        console.log("AFTER:");
        console.log("  Vault wei:   ", vAfter);
        console.log("  Vault miliBNB:", vAfter / 1e15);
        console.log("  Vault BNB:   ", vAfter / 1e18);
        console.log("  LP Vault wei:", lpAfter);
        console.log("  LP miliBNB:  ", lpAfter / 1e15);
        console.log("  LP BNB:      ", lpAfter / 1e18);
        
        console.log("\nGAINED:");
        console.log("  Vault:   ", vAfter - vBefore, "wei");
        console.log("  LP Vault:", lpAfter - lpBefore, "wei\n");
        
        if (vAfter > vBefore || lpAfter > lpBefore) {
            console.log("=== [SUCCESS] TAX PROCESSING WORKS! ===");
        } else {
            console.log("=== [FAIL] No BNB in vaults ===");
        }
    }
}
