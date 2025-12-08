// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

contract DeployBaseFork is Script {
    
    address constant ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    
    address public token;
    address public vault;
    address public lpVault;
    address public lpManager;
    address public pair;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("=================================");
        console.log("BASE FORK DEPLOYMENT");
        console.log("=================================");
        console.log("Deployer:", deployer);
        console.log("Router:", ROUTER);
        console.log("");
        
        // Get compiled bytecode
        bytes memory tokenCode = vm.getCode("JACKsPools.sol:JACKsPools");
        bytes memory vaultCode = vm.getCode("JACKsVault.sol:JACKsVault");
        bytes memory lpVaultCode = vm.getCode("JACKsLPVault.sol:JACKsLPVault");
        bytes memory lpManagerCode = vm.getCode("JACKsLPManager.sol:JACKsLPManager");
        
        // 1. Deploy Token
        console.log("1. Deploying Token...");
        bytes memory tokenConstructor = abi.encode(ROUTER);
        bytes memory tokenBytecode = abi.encodePacked(tokenCode, tokenConstructor);
        
        address _token;
        assembly {
            _token := create(0, add(tokenBytecode, 0x20), mload(tokenBytecode))
        }
        token = _token;
        require(token != address(0), "Token deployment failed");
        console.log("   Token:", token);
        
        // Get pair address
        (bool success, bytes memory pairData) = token.call(abi.encodeWithSignature("PAIR()"));
        require(success, "Failed to get PAIR");
        pair = abi.decode(pairData, (address));
        console.log("   Pair:", pair);
        
        // 2. Deploy Vault
        console.log("2. Deploying Vault...");
        bytes memory vaultConstructor = abi.encode(token);
        bytes memory vaultBytecode = abi.encodePacked(vaultCode, vaultConstructor);
        
        address _vault;
        assembly {
            _vault := create(0, add(vaultBytecode, 0x20), mload(vaultBytecode))
        }
        vault = _vault;
        require(vault != address(0), "Vault deployment failed");
        console.log("   Vault:", vault);
        
        // 3. Deploy LP Vault
        console.log("3. Deploying LP Vault...");
        bytes memory lpVaultBytecode = abi.encodePacked(lpVaultCode, vaultConstructor);
        
        address _lpVault;
        assembly {
            _lpVault := create(0, add(lpVaultBytecode, 0x20), mload(lpVaultBytecode))
        }
        lpVault = _lpVault;
        require(lpVault != address(0), "LPVault deployment failed");
        console.log("   LP Vault:", lpVault);
        
        // 4. Deploy LP Manager
        console.log("4. Deploying LP Manager...");
        bytes memory lpManagerConstructor = abi.encode(token, lpVault, ROUTER);
        bytes memory lpManagerBytecode = abi.encodePacked(lpManagerCode, lpManagerConstructor);
        
        address _lpManager;
        assembly {
            _lpManager := create(0, add(lpManagerBytecode, 0x20), mload(lpManagerBytecode))
        }
        lpManager = _lpManager;
        require(lpManager != address(0), "LPManager deployment failed");
        console.log("   LP Manager:", lpManager);
        
        // 5. Configure contracts
        console.log("");
        console.log("5. Configuring contracts...");
        
        (success,) = token.call(abi.encodeWithSignature("setLpVault(address)", lpVault));
        require(success, "setLpVault failed");
        console.log("   setLpVault: OK");
        
        (success,) = token.call(abi.encodeWithSignature("setLpManager(address)", lpManager));
        require(success, "setLpManager failed");
        console.log("   setLpManager: OK");
        
        (success,) = token.call(abi.encodeWithSignature("setVault(address)", vault));
        require(success, "setVault failed");
        console.log("   setVault: OK");
        
        (success,) = lpVault.call(abi.encodeWithSignature("setLpManager(address)", lpManager));
        require(success, "LPVault setLpManager failed");
        console.log("   LPVault setLpManager: OK");
        
        // 6. Add Initial Liquidity
        console.log("");
        console.log("6. Adding initial liquidity (0.5 ETH)...");
        (success,) = token.call{value: 0.5 ether}(abi.encodeWithSignature("addInitialLiquidity()"));
        require(success, "addInitialLiquidity failed");
        console.log("   Liquidity added: 0.5 ETH + 1B tokens");
        
        // 7. Enable Trading
        console.log("");
        console.log("7. Enabling trading...");
        (success,) = token.call(abi.encodeWithSignature("enableTrading()"));
        require(success, "enableTrading failed");
        console.log("   Trading: ENABLED");
        
        vm.stopBroadcast();
        
        // Print summary
        console.log("");
        console.log("=================================");
        console.log("DEPLOYMENT COMPLETE!");
        console.log("=================================");
        console.log("");
        console.log("System Status: READY FOR TESTING");
        console.log("- Liquidity: 0.5 ETH added");
        console.log("- Trading: ENABLED");
        console.log("");
        console.log("Export these addresses:");
        console.log("");
        console.log("export TOKEN=%s", token);
        console.log("export VAULT=%s", vault);
        console.log("export LPVAULT=%s", lpVault);
        console.log("export LPMANAGER=%s", lpManager);
        console.log("export PAIR=%s", pair);
        console.log("");
        console.log("Verify system:");
        console.log('cast call $TOKEN "getLpValue()(uint256)" --rpc-url $RPC');
        console.log('cast call $TOKEN "tradingEnabled()(bool)" --rpc-url $RPC');
        console.log("");
        console.log("Start testing:");
        console.log("1. Buy tokens to test buyer jackpot");
        console.log("2. Add LP via LPManager to test LP jackpot");
        console.log("3. Test cleanup functions");
    }
}
